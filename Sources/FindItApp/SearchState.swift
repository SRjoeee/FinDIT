import Foundation
import GRDB
import FindItCore
import os

/// 搜索状态管理
///
/// 管理搜索查询、结果列表和搜索模式。
/// 两层搜索：FTS5 即时执行（<5ms）+ 向量搜索 300ms debounce。
/// 过滤和排序在内存中应用于搜索结果。
@Observable
@MainActor
final class SearchState {
    nonisolated private static let logger = Logger(subsystem: "com.findit.app", category: "Search")
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

    /// Gemini embedding provider（在线，768d）
    private var geminiProvider: GeminiEmbeddingProvider?

    /// EmbeddingGemma provider（离线回退，768d）
    private var gemmaProvider: EmbeddingGemmaProvider?

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

    /// 翻译服务（懒初始化，Apple Translation 优先 → 词典回退）
    private var translator: (any TranslationService)?
    /// 是否已尝试初始化翻译服务
    private var hasTriedInitTranslator = false

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

    /// 搜索结果 LRU 缓存（32 条，重复查询 <1ms）
    private var searchCache = SearchLRUCache<SearchCacheKey, [SearchEngine.SearchResult]>(capacity: 32)

    /// 使 VectorStore 和 USearch 缓存失效
    ///
    /// 当视频被删除或新索引完成时调用，
    /// 确保下次向量搜索重新从数据库加载最新数据。
    func invalidateVectorStore() {
        vectorStore = nil
        searchCache.clear()
        invalidateVectorFilterCache()
        Task {
            await vectorIndexManager?.invalidateAll()
        }
    }

    // MARK: - FTS5 即时搜索

    /// 执行 FTS5 即时搜索（含跨语言词典扩展）
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

            // 同步词典扩展（<1ms）
            let parsed = QueryParser.parse(trimmed)
            let expanded = QueryPipeline.expandSync(
                trimmed, parsed: parsed, dictionary: TranslationDictionary.shared
            )

            let searchResults = try db.read { dbConn -> [SearchEngine.SearchResult] in
                // 原始语言搜索
                var results = try SearchEngine.search(
                    dbConn, query: trimmed,
                    folderPaths: filter, pathPrefixFilter: prefix, limit: 50
                )

                // 跨语言扩展搜索
                if let translatedFTS = expanded.translatedFTSQuery {
                    let existingIds = Set(results.map(\.clipId))
                    let translatedResults = try SearchEngine.search(
                        dbConn, query: translatedFTS,
                        folderPaths: filter, pathPrefixFilter: prefix, limit: 50
                    )
                    // 去重合并（翻译结果追加到尾部）
                    for result in translatedResults {
                        if !existingIds.contains(result.clipId) {
                            results.append(result)
                        }
                    }
                }

                return Array(results.prefix(50))
            }
            self.results = searchResults
        } catch {
            Self.logger.error("FTS search failed: \(error.localizedDescription)")
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
    /// 三路并行搜索: CLIP (USearch) ∥ 文本嵌入 (VectorStore) ∥ 翻译扩展
    /// 渐进式展示: CLIP+FTS5 先到先显示 → TextEmb 到达后刷新融合结果
    private func performVectorSearch(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed == self.query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        guard let db = appState?.globalDB else { return }

        let mode = self.searchMode
        let filter = self.folderFilter
        let prefix = self.pathPrefixFilter
        let parsed = QueryParser.parse(trimmed)

        // Fix 5: 缓存命中 → 立即返回
        let cacheKey = SearchCacheKey(
            query: trimmed, folderFilter: filter,
            pathPrefixFilter: prefix, mode: mode
        )
        if let cached = searchCache.get(cacheKey) {
            Self.logger.debug("cache hit: \(trimmed)")
            self.results = cached
            return
        }
        let searchStart = ContinuousClock.now

        isVectorSearching = true
        defer { isVectorSearching = false }

        // === 在 MainActor 上提前捕获所有依赖 ===
        let clipProv = await ensureClipProvider()
        let _ = getEmbeddingProvider()  // 触发懒初始化
        let gemini = geminiProvider
        let gemma = gemmaProvider
        let manager = vectorIndexManager
        let translator = ensureTranslator()

        // 预加载 VectorStore（确保 TextEmb 路径可用）
        if vectorStore == nil {
            let anyProvider: (any EmbeddingProvider)? = gemini ?? gemma
            if let provider = anyProvider, let pool = appState?.globalDB {
                await loadVectorStoreIfNeeded(provider: provider, db: pool)
            }
        }
        let capturedStore = vectorStore

        // 解析过滤 clip_id 集合（两路共享）
        let allowedClipIDs = try? await resolveAllowedClipIDs(db: db)

        // === Fix 1: 三路并行 (CLIP ∥ TextEmb ∥ Translation) ===
        // nonisolated static 函数脱离 @MainActor，真正并发执行
        async let clipFuture = Self.runClipSearch(
            query: trimmed, clipProvider: clipProv,
            manager: manager, allowedClipIDs: allowedClipIDs
        )
        async let textEmbFuture = Self.runTextEmbSearch(
            query: trimmed, geminiProvider: gemini,
            gemmaProvider: gemma, vectorStore: capturedStore,
            allowedClipIDs: allowedClipIDs
        )
        async let expandedFuture = QueryPipeline.expand(
            trimmed, parsed: parsed, translator: translator
        )

        // === Fix 2: 渐进式展示 ===

        // Phase 2: CLIP + Translation 先到 → 立即展示中间结果
        let clipResults = await clipFuture
        let expanded = await expandedFuture

        if clipResults != nil {
            guard trimmed == self.query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            let intermediateWeights = SearchEngine.resolveThreeWayWeights(
                query: trimmed, mode: mode, hasCLIP: true, hasTextEmb: false,
                isQuoted: parsed.hasQuotedPhrase
            )
            let capturedClip = clipResults
            if let intermediateResults = try? await db.read({ dbConn in
                try SearchEngine.threeWaySearch(
                    dbConn, query: parsed, expandedQuery: expanded,
                    clipResults: capturedClip, textEmbResults: nil,
                    weights: intermediateWeights,
                    folderPaths: filter, pathPrefixFilter: prefix, limit: 50
                )
            }) {
                guard trimmed == self.query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                self.results = intermediateResults
                Self.logger.info("Phase 2 (CLIP+FTS): \(searchStart.duration(to: .now)), \(intermediateResults.count) results")
            }
        }

        // Phase 3: TextEmb 到达 → 刷新为完整三路融合
        let textEmbResults = await textEmbFuture
        guard trimmed == self.query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

        let finalWeights = SearchEngine.resolveThreeWayWeights(
            query: trimmed, mode: mode,
            hasCLIP: clipResults != nil,
            hasTextEmb: textEmbResults != nil,
            isQuoted: parsed.hasQuotedPhrase
        )
        let capturedClip = clipResults
        let capturedTextEmb = textEmbResults
        if let searchResults = try? await db.read({ dbConn in
            try SearchEngine.threeWaySearch(
                dbConn, query: parsed, expandedQuery: expanded,
                clipResults: capturedClip, textEmbResults: capturedTextEmb,
                weights: finalWeights,
                folderPaths: filter, pathPrefixFilter: prefix, limit: 50
            )
        }) {
            self.results = searchResults
            searchCache.put(cacheKey, value: searchResults)
            Self.logger.info("Phase 3 (full fusion): \(searchStart.duration(to: .now)), \(searchResults.count) results")
        }
    }

    // MARK: - 并行搜索路径（nonisolated，脱离 MainActor）

    /// CLIP 搜索路径: text → SigLIP2 encode → USearch HNSW
    nonisolated private static func runClipSearch(
        query: String,
        clipProvider: CLIPEmbeddingProvider?,
        manager: VectorIndexManager?,
        allowedClipIDs: Set<Int64>?
    ) async -> [VectorSearchResult]? {
        guard let clipProvider, let manager else { return nil }
        do {
            let clipQuery = try await clipProvider.encodeText(query)
            guard let clipIndex = try await manager.getClipIndex() else { return nil }
            if let allowed = allowedClipIDs {
                return try clipIndex.searchSimilarity(
                    query: clipQuery, count: 100, allowedClipIDs: allowed
                )
            } else {
                return try clipIndex.searchSimilarity(query: clipQuery, count: 100)
            }
        } catch {
            Self.logger.error("CLIP search failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// TextEmb 搜索路径: Gemini (2s 超时) 竞速 EmbeddingGemma → VectorStore brute-force
    nonisolated private static func runTextEmbSearch(
        query: String,
        geminiProvider: GeminiEmbeddingProvider?,
        gemmaProvider: EmbeddingGemmaProvider?,
        vectorStore: VectorStore?,
        allowedClipIDs: Set<Int64>?
    ) async -> [VectorSearchResult]? {
        guard geminiProvider != nil || gemmaProvider != nil else { return nil }
        guard let store = vectorStore else { return nil }

        // Gemini (2s 硬超时) 竞速 EmbeddingGemma，取先到者
        let embedding: [Float]? = await withTaskGroup(of: [Float]?.self) { group in
            if let gemini = geminiProvider {
                group.addTask { await embedWithTimeout(provider: gemini, query: query) }
            }
            if let gemma = gemmaProvider {
                group.addTask { try? await gemma.embed(text: query) }
            }
            for await result in group {
                if result != nil {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }

        guard let emb = embedding else {
            Self.logger.debug("TextEmb embedding failed for: \(query)")
            return nil
        }
        let storeResults = await store.search(
            query: emb, limit: 100, allowedClipIDs: allowedClipIDs
        )
        guard !storeResults.isEmpty else { return nil }
        return storeResults.map {
            VectorSearchResult(clipId: $0.clipId, similarity: $0.similarity)
        }
    }

    /// Gemini 嵌入 + 硬超时
    ///
    /// 在 Gemini embed 和超时之间竞速，先到者获胜。
    /// 超时或失败返回 nil，调用方回退到 EmbeddingGemma。
    nonisolated private static func embedWithTimeout(
        provider: GeminiEmbeddingProvider,
        query: String,
        timeout: Duration = .seconds(2)
    ) async -> [Float]? {
        do {
            return try await withThrowingTaskGroup(of: [Float].self) { group in
                group.addTask { try await provider.embed(text: query) }
                group.addTask { try await Task.sleep(for: timeout); throw CancellationError() }
                guard let result = try await group.next() else { return nil }
                group.cancelAll()
                return result
            }
        } catch {
            return nil
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

    /// 获取最佳可用 embedding provider
    ///
    /// 策略: Gemini (768d, 云端) 优先 → EmbeddingGemma (768d, 离线) 回退 → nil。
    /// 两个 provider 同时初始化，运行时按可用性选择。
    /// 断网时 Gemini embed() 会失败，由调用方 catch 后用 gemmaProvider 重试。
    private func getEmbeddingProvider() -> (any EmbeddingProvider)? {
        // 懒初始化两个 provider
        if !hasTriedInitProvider {
            hasTriedInitProvider = true
            let config = ProviderConfig.load()
            if let apiKey = try? APIKeyManager.resolveAPIKey() {
                geminiProvider = GeminiEmbeddingProvider(
                    apiKey: apiKey,
                    config: config.toEmbeddingConfig()
                )
            }
            let gemma = EmbeddingGemmaProvider()
            if gemma.isAvailable() {
                gemmaProvider = gemma
            }
        }
        // 运行时选择: Gemini 优先，离线回退 EmbeddingGemma
        if let gemini = geminiProvider {
            return gemini
        }
        return gemmaProvider
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

    // MARK: - Translation

    /// 懒初始化翻译服务
    private func ensureTranslator() -> any TranslationService {
        if let t = translator { return t }
        if !hasTriedInitTranslator {
            hasTriedInitTranslator = true
            translator = QueryPipeline.bestAvailableTranslator()
        }
        return translator ?? TranslationDictionary.shared
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

    // MARK: - 启动预热

    /// 后台预加载 ONNX 模型、USearch 索引和 VectorStore
    ///
    /// 在 App 启动后调用，消除首次搜索的冷启动延迟（1-3s → ~100ms）。
    /// 所有重计算在后台线程执行，不阻塞 UI。
    func prewarm() {
        Task.detached(priority: .utility) { [weak self] in
            // 1. CLIP provider — 触发 ONNX session + tokenizer 加载
            let clip = CLIPEmbeddingProvider()
            let available = await clip.isTextEncoderAvailable
            if available {
                _ = try? await clip.encodeText("warmup")
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if available {
                    self.clipProvider = clip
                }
                self.hasTriedInitClipProvider = true
            }

            // 2. USearch 索引 — 触发 mmap 或重建
            let manager = await MainActor.run { [weak self] in self?.vectorIndexManager }
            if let manager {
                _ = try? await manager.getClipIndex()
            }

            // 3+4. TextEmb providers + VectorStore
            await MainActor.run { [weak self] in
                guard let self else { return }
                let _ = self.getEmbeddingProvider()
                let provider: (any EmbeddingProvider)? = self.geminiProvider ?? self.gemmaProvider
                if let provider, let db = self.appState?.globalDB {
                    Task { @MainActor [weak self] in
                        await self?.loadVectorStoreIfNeeded(provider: provider, db: db)
                    }
                }
            }

            Self.logger.info("prewarm completed")
        }
    }
}

// MARK: - 搜索缓存类型

/// 搜索缓存 key（查询 + 过滤条件 + 模式）
private struct SearchCacheKey: Hashable {
    let query: String
    let folderFilter: Set<String>?
    let pathPrefixFilter: String?
    let mode: SearchEngine.SearchMode
}

/// 轻量 LRU 缓存（SearchState 专用，避免跨模块依赖）
private struct SearchLRUCache<Key: Hashable, Value> {
    private let capacity: Int
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func get(_ key: Key) -> Value? {
        if let value = storage[key] {
            if let idx = order.firstIndex(of: key) {
                order.remove(at: idx)
                order.append(key)
            }
            return value
        }
        return nil
    }

    mutating func put(_ key: Key, value: Value) {
        if storage[key] != nil {
            storage[key] = value
            if let idx = order.firstIndex(of: key) {
                order.remove(at: idx)
                order.append(key)
            }
        } else {
            if order.count >= capacity {
                let evicted = order.removeFirst()
                storage.removeValue(forKey: evicted)
            }
            storage[key] = value
            order.append(key)
        }
    }

    mutating func clear() {
        storage.removeAll()
        order.removeAll()
    }
}
