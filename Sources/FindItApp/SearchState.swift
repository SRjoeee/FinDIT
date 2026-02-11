import Foundation
import GRDB
import FindItCore

/// 搜索状态管理
///
/// 管理搜索查询、结果列表和搜索模式。
/// 两层搜索：FTS5 即时执行（<5ms）+ 向量搜索 300ms debounce。
/// 过滤和排序在内存中应用于搜索结果。
@Observable
@MainActor
final class SearchState {
    /// 当前搜索文本
    var query: String = "" {
        didSet {
            if query != oldValue {
                performFTSSearch()
                scheduleVectorSearch()
            }
        }
    }

    /// 搜索结果（来自 SearchEngine，未经过滤排序）
    var results: [SearchEngine.SearchResult] = []

    /// 过滤 + 排序后的展示结果
    var displayResults: [SearchEngine.SearchResult] {
        if activeFilter.isEmpty {
            return results
        }
        return FilterEngine.applyFilter(results, filter: activeFilter)
    }

    /// 展示结果总数
    var displayResultCount: Int { displayResults.count }

    /// 是否显示离线文件（由 View 层绑定设置）
    var showOfflineFiles: Bool = false

    /// 对 UI 可见的最终结果（已应用所有过滤，包括离线状态）
    ///
    /// 替代原 ContentView 中的计算属性，利用 @Observation 自动追踪依赖。
    var visibleResults: [SearchEngine.SearchResult] {
        // 如果允许显示离线文件，直接返回 displayResults
        if showOfflineFiles { return displayResults }

        // 否则过滤掉离线文件夹的内容
        guard let appState = appState else { return displayResults }
        
        // 访问 Observable 的 appState.folders 会自动建立依赖
        let offlinePaths = Set(appState.folders.filter { !$0.isAvailable }.map(\.folderPath))
        
        if offlinePaths.isEmpty { return displayResults }
        
        return displayResults.filter { !offlinePaths.contains($0.sourceFolder) }
    }

    /// 是否正在进行向量搜索
    var isVectorSearching = false

    /// 搜索模式
    var searchMode: SearchEngine.SearchMode = .auto

    /// 活跃过滤条件
    var activeFilter = FilterEngine.SearchFilter()

    /// 是否有活跃过滤器
    var hasActiveFilter: Bool { !activeFilter.isEmpty }

    /// 分面统计（用于 FilterBar 菜单选项）
    var facets: FilterEngine.FacetCounts?

    /// 文件夹过滤（nil = 全局搜索，非空 = 仅搜索指定文件夹）
    var folderFilter: Set<String>? = nil {
        didSet {
            if folderFilter != oldValue {
                invalidateVectorFilterCache()
                performFTSSearch()
                scheduleVectorSearch()
                loadFacets()
            }
        }
    }

    /// 路径前缀过滤（用于子文件夹书签的搜索过滤）
    var pathPrefixFilter: String? = nil {
        didSet {
            if pathPrefixFilter != oldValue {
                invalidateVectorFilterCache()
                performFTSSearch()
                scheduleVectorSearch()
            }
        }
    }

    /// 全局数据库引用（由外部注入）
    weak var appState: AppState?

    /// 向量搜索 debounce Task
    private var vectorSearchTask: Task<Void, Never>?

    /// Embedding provider（懒初始化，Gemini 优先，EmbeddingGemma 回退）
    private var embeddingProvider: (any EmbeddingProvider)?

    /// 是否已尝试初始化 provider（避免反复尝试）
    private var hasTriedInitProvider = false

    /// 内存向量存储（批量矩阵搜索，100K clips ~25ms）
    private var vectorStore: VectorStore?

    /// 是否正在加载 VectorStore（避免重复加载）
    private var isLoadingVectorStore = false

    /// CLIP 嵌入服务（文本 → CLIP 向量，用于跨模态搜索）
    private var clipProvider: CLIPEmbeddingProvider?

    /// 是否已尝试初始化 CLIP provider
    private var hasTriedInitClipProvider = false

    /// USearch 双索引管理器（外部注入）
    var vectorIndexManager: VectorIndexManager?

    /// 向量过滤缓存 key（folder/path 过滤变化时失效）
    private struct VectorFilterCacheKey: Equatable {
        let folderFilter: Set<String>?
        let pathPrefixFilter: String?

        var requiresFiltering: Bool { folderFilter != nil || pathPrefixFilter != nil }
    }

    /// 过滤缓存（避免每次输入都重复查询 clip_id 集合）
    private var vectorFilterCache: (key: VectorFilterCacheKey, clipIDs: Set<Int64>)?

    /// 使 VectorStore 和 USearch 缓存失效
    ///
    /// 当视频被删除或新索引完成时调用，
    /// 确保下次向量搜索重新从数据库加载最新数据。
    func invalidateVectorStore() {
        vectorStore = nil
        invalidateVectorFilterCache()
        Task {
            await vectorIndexManager?.invalidateAll()
        }
    }

    // MARK: - FTS5 即时搜索

    /// 执行 FTS5 即时搜索
    private func performFTSSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            results = []
            return
        }

        guard let db = appState?.globalDB else { return }

        do {
            let filter = self.folderFilter
            let prefix = self.pathPrefixFilter
            let searchResults = try db.read { dbConn in
                try SearchEngine.search(dbConn, query: trimmed, folderPaths: filter, pathPrefixFilter: prefix, limit: 50)
            }
            self.results = searchResults
        } catch {
            // FTS5 语法错误等，静默忽略（不打断输入流）
            self.results = []
        }
    }

    // MARK: - 向量搜索 debounce

    /// 调度 300ms 延迟的向量搜索
    private func scheduleVectorSearch() {
        vectorSearchTask?.cancel()

        let currentQuery = query
        guard !currentQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        vectorSearchTask = Task { [weak self] in
            // 300ms debounce
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            await self?.performVectorSearch(query: currentQuery)
        }
    }

    /// 执行向量搜索（在 debounce 后调用）
    ///
    /// 三路搜索: CLIP (USearch) + 文本嵌入 (VectorStore) + FTS5
    private func performVectorSearch(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 确保当前查询没变
        guard trimmed == self.query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        guard let db = appState?.globalDB else { return }

        // 懒初始化 embedding provider
        let textProvider = getEmbeddingProvider()

        isVectorSearching = true
        defer { isVectorSearching = false }

        do {
            // 并行准备 CLIP 和文本嵌入搜索
            let clipProvider = await ensureClipProvider()

            // === 1. CLIP 搜索路径 (USearch HNSW) ===
            var clipResults: [VectorSearchResult]?
            if let clipProvider = clipProvider, let manager = vectorIndexManager {
                do {
                    let clipQuery = try await clipProvider.encodeText(trimmed)
                    if let clipIndex = try await manager.getClipIndex() {
                        let allowedClipIDs = try await resolveAllowedClipIDs(db: db)
                        if let allowed = allowedClipIDs {
                            clipResults = try clipIndex.searchSimilarity(
                                query: clipQuery, count: 100, allowedClipIDs: allowed
                            )
                        } else {
                            clipResults = try clipIndex.searchSimilarity(
                                query: clipQuery, count: 100
                            )
                        }
                    }
                } catch {
                    // CLIP 搜索失败非致命，回退到文本嵌入 + FTS5
                }
            }

            // === 2. 文本嵌入搜索路径 (VectorStore brute-force) ===
            var textEmbResults: [VectorSearchResult]?
            if let textProvider = textProvider {
                await loadVectorStoreIfNeeded(provider: textProvider, db: db)

                let queryEmbedding = try await textProvider.embed(text: trimmed)

                // 再次检查查询没变
                guard trimmed == self.query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

                let allowedClipIDs = try await resolveAllowedClipIDs(db: db)

                if let store = vectorStore {
                    let storeResults = await store.search(
                        query: queryEmbedding,
                        limit: 100,
                        allowedClipIDs: allowedClipIDs
                    )
                    if !storeResults.isEmpty {
                        textEmbResults = storeResults.map {
                            VectorSearchResult(clipId: $0.clipId, similarity: $0.similarity)
                        }
                    }
                }
            }

            // 再次检查查询没变
            guard trimmed == self.query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

            // === 3. 三路融合搜索 ===
            let mode = self.searchMode
            let filter = self.folderFilter
            let prefix = self.pathPrefixFilter
            let parsed = QueryParser.parse(trimmed)
            let weights = SearchEngine.resolveWeights(
                query: trimmed, mode: mode,
                hasEmbedding: textEmbResults != nil || clipResults != nil
            )

            let capturedClipResults = clipResults
            let capturedTextEmbResults = textEmbResults
            let searchResults = try await db.read { dbConn in
                try SearchEngine.threeWaySearch(
                    dbConn,
                    query: parsed,
                    clipResults: capturedClipResults,
                    textEmbResults: capturedTextEmbResults,
                    weights: weights,
                    folderPaths: filter,
                    pathPrefixFilter: prefix,
                    limit: 50
                )
            }
            self.results = searchResults
        } catch {
            // 向量搜索失败不影响已有 FTS5 结果
        }
    }

    /// 懒加载 VectorStore（首次向量搜索时触发）
    ///
    /// 同时加载 Gemini 和 EmbeddingGemma 的 768d 文本嵌入向量。
    /// 两者都是 768d L2 归一化文本嵌入，可在同一 VectorStore 中混合搜索。
    private func loadVectorStoreIfNeeded(provider: any EmbeddingProvider, db: DatabasePool) async {
        guard vectorStore == nil, !isLoadingVectorStore else { return }
        isLoadingVectorStore = true
        defer { isLoadingVectorStore = false }

        do {
            // 加载所有 768d 文本嵌入（Gemini + EmbeddingGemma 均兼容）
            let compatibleModels = ["gemini", "embedding-gemma"]
            let placeholders = compatibleModels.map { _ in "?" }.joined(separator: ", ")
            let entries: [(clipId: Int64, embeddingData: Data)] = try await db.read { dbConn in
                let rows = try Row.fetchAll(dbConn, sql: """
                    SELECT clip_id, embedding
                    FROM clips
                    WHERE embedding IS NOT NULL
                      AND embedding_model IN (\(placeholders))
                    """, arguments: StatementArguments(compatibleModels))
                return rows.compactMap { row in
                    guard let clipId = row["clip_id"] as? Int64,
                          let data = row["embedding"] as? Data else { return nil }
                    return (clipId: clipId, embeddingData: data)
                }
            }

            let store = VectorStore(dimensions: provider.dimensions, embeddingModel: provider.name)
            await store.load(entries: entries)
            self.vectorStore = store
        } catch {
            // 加载失败不致命，回退到逐行扫描
        }
    }

    /// 获取或初始化 embedding provider
    ///
    /// 策略：Gemini（768 维，云端） → EmbeddingGemma（768 维，离线） → nil。
    /// 已初始化时直接返回缓存实例。
    /// 初始化失败后进入冷却，直到收到配置变更通知再重试。
    private func getEmbeddingProvider() -> (any EmbeddingProvider)? {
        if let provider = embeddingProvider {
            return provider
        }
        guard !hasTriedInitProvider else { return nil }
        hasTriedInitProvider = true

        // 优先 Gemini（使用 ProviderConfig 的模型设置）
        let config = ProviderConfig.load()
        if let apiKey = try? APIKeyManager.resolveAPIKey() {
            let provider = GeminiEmbeddingProvider(
                apiKey: apiKey,
                config: config.toEmbeddingConfig()
            )
            self.embeddingProvider = provider
            return provider
        }

        // 无 API Key → 回退到 EmbeddingGemma 本地模型（768d，离线）
        let gemmaProvider = EmbeddingGemmaProvider()
        if gemmaProvider.isAvailable() {
            self.embeddingProvider = gemmaProvider
            return gemmaProvider
        }

        // 无 API Key 且无 EmbeddingGemma → 仅使用 FTS5 + CLIP 搜索
        return nil
    }

    /// 解析向量过滤所需 clip_id 集合（有过滤时）
    ///
    /// 返回 nil 表示“无需过滤”（全局搜索）；
    /// 返回空集表示“过滤后无候选”，向量搜索应直接返回空结果。
    private func resolveAllowedClipIDs(db: DatabasePool) async throws -> Set<Int64>? {
        let key = VectorFilterCacheKey(
            folderFilter: folderFilter,
            pathPrefixFilter: pathPrefixFilter
        )
        guard key.requiresFiltering else { return nil }

        if let cache = vectorFilterCache, cache.key == key {
            return cache.clipIDs
        }

        let ids: Set<Int64>
        if let folders = key.folderFilter, folders.isEmpty {
            ids = []
        } else {
            ids = try await db.read { dbConn in
                var args = StatementArguments()
                var whereClauses: [String] = []

                if let folders = key.folderFilter {
                    let sortedFolders = folders.sorted()
                    let placeholders = sortedFolders.map { _ in "?" }.joined(separator: ", ")
                    whereClauses.append("c.source_folder IN (\(placeholders))")
                    for path in sortedFolders {
                        args += [path]
                    }
                }

                if let prefix = key.pathPrefixFilter {
                    whereClauses.append("v.file_path LIKE ? || '/%'")
                    args += [prefix]
                }

                let whereSQL = whereClauses.isEmpty ? "" : "WHERE " + whereClauses.joined(separator: " AND ")
                let rows = try Int64.fetchAll(dbConn, sql: """
                    SELECT c.clip_id
                    FROM clips c
                    LEFT JOIN videos v ON v.video_id = c.video_id
                    \(whereSQL)
                    """, arguments: args)
                return Set(rows)
            }
        }

        vectorFilterCache = (key: key, clipIDs: ids)
        return ids
    }

    private func invalidateVectorFilterCache() {
        vectorFilterCache = nil
    }

    // MARK: - 分面统计

    /// 加载当前文件夹范围的分面统计
    func loadFacets() {
        guard let db = appState?.globalDB else { return }
        let paths = folderFilter
        do {
            facets = try db.read { dbConn in
                try FilterEngine.availableFacets(dbConn, folderPaths: paths)
            }
        } catch {
            facets = nil
        }
    }

    // MARK: - 元数据内存同步

    /// 更新片段评分（内存同步，触发 displayResults 重算）
    func updateClipRating(clipId: Int64, rating: Int) {
        if let index = results.firstIndex(where: { $0.clipId == clipId }) {
            results[index].rating = rating
        }
    }

    /// 更新片段颜色标签（内存同步，触发 displayResults 重算）
    func updateClipColorLabel(clipId: Int64, colorLabel: String?) {
        if let index = results.firstIndex(where: { $0.clipId == clipId }) {
            results[index].colorLabel = colorLabel
        }
    }

    // MARK: - 公开方法

    /// 记录搜索到历史
    func recordCurrentSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let db = appState?.globalDB else { return }

        try? db.write { dbConn in
            try SearchEngine.recordSearch(dbConn, query: trimmed, resultCount: displayResultCount)
        }
    }

    /// 清空搜索
    func clearSearch() {
        vectorSearchTask?.cancel()
        query = ""
        results = []
    }

    // MARK: - CLIP Provider

    /// 懒初始化 CLIP 嵌入服务
    ///
    /// 检查 SigLIP2 文本编码器模型文件是否存在。
    /// 初始化失败后不再重试（直到下次启动）。
    private func ensureClipProvider() async -> CLIPEmbeddingProvider? {
        if let existing = clipProvider {
            return existing
        }
        guard !hasTriedInitClipProvider else { return nil }
        hasTriedInitClipProvider = true

        let provider = CLIPEmbeddingProvider()
        let available = await provider.isTextEncoderAvailable
        guard available else { return nil }

        clipProvider = provider
        return provider
    }
}
