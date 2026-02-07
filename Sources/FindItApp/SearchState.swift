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

    /// 全局数据库引用（由外部注入）
    weak var appState: AppState?

    /// 向量搜索 debounce Task
    private var vectorSearchTask: Task<Void, Never>?

    /// Gemini embedding provider（懒初始化，key 不存在时允许后续重试）
    private var embeddingProvider: GeminiEmbeddingProvider?

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
            let searchResults = try db.read { dbConn in
                try SearchEngine.search(dbConn, query: trimmed, limit: 50)
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
            let queryEmbedding = try await provider.embed(text: trimmed)

            // 再次检查查询没变
            guard trimmed == self.query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

            let mode = self.searchMode
            let hybridResults = try await db.read { dbConn in
                try SearchEngine.hybridSearch(
                    dbConn,
                    query: trimmed,
                    queryEmbedding: queryEmbedding,
                    embeddingModel: provider.name,
                    mode: mode,
                    limit: 50
                )
            }
            self.results = hybridResults
        } catch {
            // 向量搜索失败不影响已有 FTS5 结果
        }
    }

    /// 获取或初始化 Gemini embedding provider
    ///
    /// 已初始化时直接返回缓存实例。
    /// 未初始化时尝试读取 API key，失败则返回 nil（下次调用会重试）。
    private func getEmbeddingProvider() -> GeminiEmbeddingProvider? {
        if let provider = embeddingProvider {
            return provider
        }

        guard let apiKey = try? VisionAnalyzer.resolveAPIKey() else {
            return nil
        }
        let provider = GeminiEmbeddingProvider(apiKey: apiKey)
        self.embeddingProvider = provider
        return provider
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
