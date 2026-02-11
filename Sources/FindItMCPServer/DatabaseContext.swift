import Foundation
import GRDB
import FindItCore

/// MCP Server 的数据库连接管理
///
/// 管理全局搜索索引和按需打开的文件夹级数据库。
/// 使用 `any DatabaseWriter` 以支持测试注入（DatabaseQueue / DatabasePool 均可）。
final class DatabaseContext: @unchecked Sendable {

    /// 全局搜索索引（FTS5 + 向量）
    let globalDB: any DatabaseWriter

    /// 文件夹库缓存（folderPath → DatabaseWriter）
    private let folderDBCache = Mutex<[String: any DatabaseWriter]>([:])

    /// Embedding 相关缓存
    private let searchState = Mutex<SearchState>(SearchState())

    /// 测试注入的 embedding provider（优先于自动检测）
    private let injectedProvider: (any EmbeddingProvider)?

    /// 生产环境初始化 — 打开真实的全局数据库
    init() throws {
        self.globalDB = try DatabaseManager.openGlobalDatabase()
        self.injectedProvider = nil
    }

    /// 测试注入初始化 — 接受预构建的数据库实例
    init(
        globalDB: any DatabaseWriter,
        folderDBs: [String: any DatabaseWriter] = [:],
        embeddingProvider: (any EmbeddingProvider)? = nil
    ) {
        self.globalDB = globalDB
        self.injectedProvider = embeddingProvider
        folderDBCache.withLock { cache in
            for (k, v) in folderDBs {
                cache[k] = v
            }
        }
    }

    /// 获取文件夹级数据库（按需打开 + 缓存）
    func folderDB(for folderPath: String) throws -> any DatabaseWriter {
        return try folderDBCache.withLock { cache in
            if let existing = cache[folderPath] {
                return existing
            }
            let db = try DatabaseManager.openFolderDatabase(at: folderPath)
            cache[folderPath] = db
            return db
        }
    }

    // MARK: - Embedding 支持

    /// 获取可用的 EmbeddingProvider（Gemini → EmbeddingGemma 回退链）
    ///
    /// 首次调用自动检测并缓存，后续调用直接返回缓存。
    /// 如果没有任何可用 provider，返回 nil。
    func getEmbeddingProvider() -> (any EmbeddingProvider)? {
        // 测试注入优先
        if let injected = injectedProvider {
            return injected
        }

        return searchState.withLock { state in
            if state.providerResolved {
                return state.cachedProvider
            }
            state.providerResolved = true

            // 尝试 Gemini (768d, 在线)
            if let apiKey = try? APIKeyManager.resolveAPIKey() {
                let gemini = GeminiEmbeddingProvider(apiKey: apiKey)
                if gemini.isAvailable() {
                    state.cachedProvider = gemini
                    return gemini
                }
            }

            // 回退 EmbeddingGemma (768d, 离线)
            let gemma = EmbeddingGemmaProvider()
            if gemma.isAvailable() {
                state.cachedProvider = gemma
                return gemma
            }

            return nil
        }
    }

    /// 768d 文本嵌入兼容模型列表
    ///
    /// Gemini 和 EmbeddingGemma 均产生 768 维文本嵌入。
    /// 加载 VectorStore 时同时包含两者，避免切换 provider 后旧向量不可搜索。
    private static let compatible768dModels = ["gemini", "embedding-gemma"]

    /// 获取向量存储（按需从全局库加载 + 缓存）
    ///
    /// VectorStore 在首次使用时从全局库加载全部兼容维度的 embedding 到内存，
    /// 后续搜索直接使用内存中的数据。
    func getVectorStore(provider: any EmbeddingProvider) async throws -> VectorStore {
        let cached: VectorStore? = searchState.withLock { state in
            state.vectorStores[provider.name]
        }
        if let existing = cached {
            return existing
        }

        // 加载当前 provider 及所有相同维度的兼容模型
        let models = Self.compatible768dModels.contains(provider.name)
            ? Self.compatible768dModels
            : [provider.name]
        let placeholders = models.map { _ in "?" }.joined(separator: ", ")

        let store = VectorStore(dimensions: provider.dimensions, embeddingModel: provider.name)
        let entries: [(clipId: Int64, embeddingData: Data)] = try await globalDB.read { db in
            var args = StatementArguments()
            for model in models { args += [model] }
            let rows = try Row.fetchAll(db, sql: """
                SELECT clip_id, embedding FROM clips
                WHERE embedding IS NOT NULL AND embedding_model IN (\(placeholders))
                """, arguments: args)
            return rows.map { (clipId: $0["clip_id"], embeddingData: $0["embedding"]) }
        }

        if !entries.isEmpty {
            await store.load(entries: entries)
        }

        searchState.withLock { state in
            state.vectorStores[provider.name] = store
        }
        return store
    }
}

// MARK: - SearchState

/// Embedding/VectorStore 缓存状态
private struct SearchState {
    var providerResolved = false
    var cachedProvider: (any EmbeddingProvider)?
    var vectorStores: [String: VectorStore] = [:]
}

// MARK: - Mutex

/// 简单互斥锁封装
///
/// 用于保护内部缓存的线程安全访问。
private final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
