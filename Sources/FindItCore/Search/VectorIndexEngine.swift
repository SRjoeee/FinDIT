import Foundation

/// 向量索引引擎协议
///
/// 抽象 HNSW 等近似最近邻索引的核心操作。
/// 实现者需保证线程安全（内部加锁或 actor 隔离）。
///
/// 与 `VectorStore` 的区别:
/// - `VectorStore`: 暴力扫描 (O(n))，精确结果，适合 < 100K 向量
/// - `VectorIndexEngine`: 近似搜索 (O(log n))，亚毫秒级，适合 > 100K 向量
public protocol VectorIndexEngine: Sendable {

    /// 索引中的向量维度
    var dimensions: Int { get }

    /// 当前索引的向量数量
    var count: Int { get throws }

    /// 添加单个向量
    ///
    /// - Parameters:
    ///   - key: 唯一标识符（通常为 clip_id）
    ///   - vector: Float32 向量，长度须等于 `dimensions`
    func add(key: UInt64, vector: [Float]) throws

    /// 批量添加向量
    func addBatch(keys: [UInt64], vectors: [[Float]]) throws

    /// 删除指定 key 的向量
    func remove(key: UInt64) throws

    /// 检查指定 key 是否存在
    func contains(key: UInt64) throws -> Bool

    /// 搜索最近邻
    ///
    /// - Parameters:
    ///   - query: 查询向量
    ///   - count: 返回的最大结果数
    /// - Returns: (key, distance) 对，按距离升序排列。
    ///            对于余弦度量: distance = 1 - cosine_similarity
    func search(query: [Float], count: Int) throws -> [(key: UInt64, distance: Float)]

    /// 持久化索引到磁盘
    func save(to path: String) throws

    /// 从磁盘加载索引（覆盖当前内容）
    func load(from path: String) throws

    /// 以 mmap 只读方式查看索引（零拷贝，适合搜索场景）
    func view(from path: String) throws

    /// 清空索引中所有向量
    func clear() throws
}

// MARK: - Default Implementations

extension VectorIndexEngine {

    /// 默认批量添加：逐个调用 add
    public func addBatch(keys: [UInt64], vectors: [[Float]]) throws {
        precondition(keys.count == vectors.count)
        for (key, vector) in zip(keys, vectors) {
            try add(key: key, vector: vector)
        }
    }
}

/// 向量索引搜索结果，转换为 cosine similarity
public struct VectorSearchResult: Sendable {
    /// clip ID
    public let clipId: Int64
    /// 余弦相似度 (0..1)，越高越相似
    public let similarity: Float

    public init(clipId: Int64, similarity: Float) {
        self.clipId = clipId
        self.similarity = similarity
    }
}
