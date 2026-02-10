import Foundation
import GRDB
import FindItCore

/// MCP Server 的数据库连接与搜索上下文
///
/// 管理全局搜索索引、文件夹级数据库，以及向量搜索所需的
/// EmbeddingProvider 和 VectorStore。所有可变状态通过 Mutex 保护线程安全。
final class DatabaseContext: Sendable {

    /// 全局搜索索引（FTS5 + 向量）
    let globalDB: DatabasePool

    /// 文件夹库缓存（folderPath → DatabasePool）
    private let folderDBCache = Mutex<[String: DatabasePool]>([:])

    /// 搜索上下文（embedding provider + VectorStore 缓存）
    private let searchState = Mutex<SearchState>(SearchState())

    init() throws {
        self.globalDB = try DatabaseManager.openGlobalDatabase()
    }

    /// 获取文件夹级数据库（按需打开 + 缓存）
    func folderDB(for folderPath: String) throws -> DatabasePool {
        return try folderDBCache.withLock { cache in
            if let existing = cache[folderPath] {
                return existing
            }
            let db = try DatabaseManager.openFolderDatabase(at: folderPath)
            cache[folderPath] = db
            return db
        }
    }

    // MARK: - Embedding Provider

    /// 获取 embedding provider（懒初始化）
    ///
    /// 回退链: Gemini (768D) → NLEmbedding (512D) → nil
    /// 初始化只尝试一次，结果缓存到 searchState。
    func getEmbeddingProvider() -> (any EmbeddingProvider)? {
        return searchState.withLock { state in
            if state.hasTriedInitProvider {
                return state.embeddingProvider
            }
            state.hasTriedInitProvider = true

            // 1. 尝试 Gemini（需要 API Key）
            if let apiKey = try? APIKeyManager.resolveAPIKey() {
                let gemini = GeminiEmbeddingProvider(apiKey: apiKey)
                if gemini.isAvailable() {
                    state.embeddingProvider = gemini
                    return gemini
                }
            }

            // 2. 回退到 NLEmbedding（离线）
            let nl = NLEmbeddingProvider()
            if nl.isAvailable() {
                state.embeddingProvider = nl
                return nl
            }

            // 3. 无可用 provider
            return nil
        }
    }

    // MARK: - VectorStore

    /// 获取或加载 VectorStore（与 provider 匹配的向量数据）
    ///
    /// VectorStore 是 actor，加载是 async 操作。
    /// 首次调用会从 globalDB 加载全部向量数据到内存，后续直接返回缓存。
    /// 模型名变更时自动重新加载。
    func getVectorStore(provider: any EmbeddingProvider) async throws -> VectorStore {
        // 检查缓存（快速路径）
        let cached: VectorStore? = searchState.withLock { state in
            if let store = state.vectorStore,
               state.vectorStoreLoadedModel == provider.name {
                return store
            }
            return nil
        }
        if let store = cached {
            return store
        }

        // 从 globalDB 加载向量数据
        let entries: [(clipId: Int64, embeddingData: Data)] = try await globalDB.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT clip_id, embedding FROM clips
                WHERE embedding IS NOT NULL AND embedding_model = ?
                """, arguments: [provider.name])
            return rows.compactMap { row in
                guard let clipId = row["clip_id"] as Int64?,
                      let data = row["embedding"] as Data? else {
                    return nil
                }
                return (clipId: clipId, embeddingData: data)
            }
        }

        let store = VectorStore(dimensions: provider.dimensions, embeddingModel: provider.name)
        await store.load(entries: entries)

        // 缓存结果
        searchState.withLock { state in
            state.vectorStore = store
            state.vectorStoreLoadedModel = provider.name
        }

        return store
    }
}

// MARK: - SearchState

/// 搜索相关的可变状态
///
/// 由 Mutex 保护，在 DatabaseContext 内使用。
private struct SearchState: Sendable {
    /// 缓存的 embedding provider（nil 表示不可用或未初始化）
    var embeddingProvider: (any EmbeddingProvider)?
    /// 是否已尝试初始化 provider（避免重复尝试）
    var hasTriedInitProvider: Bool = false
    /// 缓存的 VectorStore
    var vectorStore: VectorStore?
    /// VectorStore 对应的 embedding model 名称
    var vectorStoreLoadedModel: String?
}

// MARK: - Mutex

/// 简单互斥锁封装
///
/// 用于保护可变状态的线程安全访问。
private final class Mutex<Value: Sendable>: @unchecked Sendable {
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
