import Foundation
import GRDB
import FindItCore

/// 搜索状态管理
///
/// 管理搜索查询、结果列表和搜索模式。
/// 两层搜索：FTS5 即时执行（<5ms）+ 向量搜索 300ms debounce。
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

    /// 搜索结果
    var results: [SearchEngine.SearchResult] = []

    /// 结果总数
    var resultCount: Int { results.count }

    /// 是否正在进行向量搜索
    var isVectorSearching = false

    /// 搜索模式
    var searchMode: SearchEngine.SearchMode = .auto

    /// 文件夹过滤（nil = 全局搜索，非空 = 仅搜索指定文件夹）
    var folderFilter: Set<String>? = nil {
        didSet {
            if folderFilter != oldValue {
                performFTSSearch()
                scheduleVectorSearch()
            }
        }
    }

    /// 路径前缀过滤（用于子文件夹书签的搜索过滤）
    var pathPrefixFilter: String? = nil {
        didSet {
            if pathPrefixFilter != oldValue {
                performFTSSearch()
                scheduleVectorSearch()
            }
        }
    }

    /// 全局数据库引用（由外部注入）
    weak var appState: AppState?

    /// 向量搜索 debounce Task
    private var vectorSearchTask: Task<Void, Never>?

    /// Embedding provider（懒初始化，Gemini 优先，NLEmbedding 回退）
    private var embeddingProvider: (any EmbeddingProvider)?

    /// 是否已尝试初始化 provider（避免反复尝试）
    private var hasTriedInitProvider = false

    /// 内存向量存储（批量矩阵搜索，100K clips ~25ms）
    private var vectorStore: VectorStore?

    /// 是否正在加载 VectorStore（避免重复加载）
    private var isLoadingVectorStore = false

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
    private func performVectorSearch(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 确保当前查询没变
        guard trimmed == self.query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        guard let db = appState?.globalDB else { return }

        // 懒初始化 embedding provider
        let provider = getEmbeddingProvider()
        guard let provider = provider else { return }

        isVectorSearching = true
        defer { isVectorSearching = false }

        do {
            // 确保 VectorStore 已加载
            await loadVectorStoreIfNeeded(provider: provider, db: db)

            let queryEmbedding = try await provider.embed(text: trimmed)

            // 再次检查查询没变
            guard trimmed == self.query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

            // VectorStore 批量搜索（~25ms for 100K clips）
            let storeResults: [(clipId: Int64, similarity: Float)]?
            if let store = vectorStore {
                storeResults = await store.search(query: queryEmbedding, limit: 100)
            } else {
                storeResults = nil
            }

            let mode = self.searchMode
            let filter = self.folderFilter
            let prefix = self.pathPrefixFilter
            let capturedStoreResults = storeResults
            let hybridResults = try await db.read { dbConn in
                try SearchEngine.hybridSearch(
                    dbConn,
                    query: trimmed,
                    queryEmbedding: queryEmbedding,
                    embeddingModel: provider.name,
                    vectorStoreResults: capturedStoreResults,
                    mode: mode,
                    folderPaths: filter,
                    pathPrefixFilter: prefix,
                    limit: 50
                )
            }
            self.results = hybridResults
        } catch {
            // 向量搜索失败不影响已有 FTS5 结果
        }
    }

    /// 懒加载 VectorStore（首次向量搜索时触发）
    private func loadVectorStoreIfNeeded(provider: any EmbeddingProvider, db: DatabasePool) async {
        guard vectorStore == nil, !isLoadingVectorStore else { return }
        isLoadingVectorStore = true
        defer { isLoadingVectorStore = false }

        do {
            let entries: [(clipId: Int64, embeddingData: Data)] = try await db.read { dbConn in
                let rows = try Row.fetchAll(dbConn, sql: """
                    SELECT clip_id, embedding
                    FROM clips
                    WHERE embedding IS NOT NULL AND embedding_model = ?
                    """, arguments: [provider.name])
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
    /// 策略：Gemini（768 维，云端） → NLEmbedding（512 维，离线）。
    /// 已初始化时直接返回缓存实例。
    /// 首次初始化失败后不再反复尝试（API key 配置后需重启 App）。
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

        // 回退 NLEmbedding（离线）
        let nlProvider = NLEmbeddingProvider()
        if nlProvider.isAvailable() {
            self.embeddingProvider = nlProvider
            return nlProvider
        }

        return nil
    }

    // MARK: - 公开方法

    /// 记录搜索到历史
    func recordCurrentSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let db = appState?.globalDB else { return }

        try? db.write { dbConn in
            try SearchEngine.recordSearch(dbConn, query: trimmed, resultCount: resultCount)
        }
    }

    /// 清空搜索
    func clearSearch() {
        vectorSearchTask?.cancel()
        query = ""
        results = []
    }
}
