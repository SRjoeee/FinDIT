import Foundation
import USearch

/// USearch HNSW 向量索引
///
/// 基于 USearch 库的近似最近邻索引，支持:
/// - 亚毫秒级搜索 (1M 向量 < 1ms)
/// - mmap 磁盘映射（零拷贝加载）
/// - 增量 add/remove
/// - FP16 量化存储（内存减半，recall 损失 ~1%）
///
/// 线程安全由 USearch 内部读写锁保证。
/// 使用 `@unchecked Sendable` 因为 USearchIndex 内部线程安全。
public final class USearchVectorIndex: VectorIndexEngine, @unchecked Sendable {

    /// HNSW 参数
    public struct Config: Sendable {
        /// 向量维度
        public let dimensions: UInt32
        /// 每节点连接数 (M parameter)
        public let connectivity: UInt32
        /// 内部量化精度
        public let quantization: USearchScalar

        /// 默认配置: 768 维, M=16, FP16 量化
        public static let clip768 = Config(
            dimensions: 768,
            connectivity: 16,
            quantization: .f16
        )

        /// 用于文本嵌入的配置 (同维度但独立索引)
        public static let textEmb768 = Config(
            dimensions: 768,
            connectivity: 16,
            quantization: .f16
        )

        public init(dimensions: UInt32, connectivity: UInt32, quantization: USearchScalar) {
            self.dimensions = dimensions
            self.connectivity = connectivity
            self.quantization = quantization
        }
    }

    /// 索引路径常量
    public enum IndexPath {
        /// CLIP 向量索引
        public static var clipIndex: String {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!.path
            return (appSupport as NSString).appendingPathComponent("FindIt/clip.usearch")
        }

        /// 文本嵌入向量索引
        public static var textIndex: String {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!.path
            return (appSupport as NSString).appendingPathComponent("FindIt/text.usearch")
        }
    }

    // MARK: - Properties

    private let index: USearchIndex
    private let config: Config

    /// 已预分配的容量（USearch 要求 add 前 reserve）
    private var reservedCapacity: Int = 0
    /// view() 后为 true，禁止写操作
    private var isReadOnly = false
    private let lock = NSLock()

    /// 初始预分配和每次扩容的增量
    private static let initialCapacity = 1024
    private static let growFactor = 2

    public var dimensions: Int { Int(config.dimensions) }

    public var count: Int {
        get throws {
            try index.count
        }
    }

    // MARK: - Init

    /// 创建新的空索引
    ///
    /// - Parameter config: HNSW 参数配置
    public init(config: Config = .clip768) throws {
        self.config = config
        self.index = try USearchIndex.make(
            metric: .cos,
            dimensions: config.dimensions,
            connectivity: config.connectivity,
            quantization: config.quantization
        )
    }

    // MARK: - VectorIndexEngine

    public func add(key: UInt64, vector: [Float]) throws {
        lock.lock()
        defer { lock.unlock() }
        try guardNotReadOnly()
        try ensureCapacityLocked(for: 1)
        try index.add(key: key, vector: vector)
    }

    public func addBatch(keys: [UInt64], vectors: [[Float]]) throws {
        precondition(keys.count == vectors.count,
                     "keys.count (\(keys.count)) != vectors.count (\(vectors.count))")
        lock.lock()
        defer { lock.unlock() }
        try guardNotReadOnly()
        try ensureCapacityLocked(for: keys.count)
        for (key, vector) in zip(keys, vectors) {
            try index.add(key: key, vector: vector)
        }
    }

    public func remove(key: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        try guardNotReadOnly()
        _ = try index.remove(key: key)
    }

    public func contains(key: UInt64) throws -> Bool {
        try index.contains(key: key)
    }

    public func search(query: [Float], count: Int) throws -> [(key: UInt64, distance: Float)] {
        let (keys, distances) = try index.search(vector: query, count: count)
        return zip(keys, distances).map { (key: $0, distance: $1) }
    }

    /// 搜索并转换为 cosine similarity 结果
    ///
    /// 将 USearch 的距离值 (1 - cosine_similarity) 转换为相似度，
    /// 并将 UInt64 key 转回 Int64 clip_id。
    ///
    /// - Parameters:
    ///   - query: 查询向量
    ///   - count: 最大结果数
    /// - Returns: 按相似度降序排列的搜索结果
    public func searchSimilarity(query: [Float], count: Int) throws -> [VectorSearchResult] {
        let (keys, distances) = try index.search(vector: query, count: count)
        return zip(keys, distances).map { key, distance in
            VectorSearchResult(
                clipId: Int64(bitPattern: key),
                similarity: min(1.0, max(0.0, 1.0 - distance))
            )
        }
    }

    /// 搜索，支持 clip_id 过滤
    ///
    /// 使用 USearch 的 filteredSearch 在索引层面过滤，
    /// 比先搜索再过滤更高效。
    ///
    /// - Parameters:
    ///   - query: 查询向量
    ///   - count: 最大结果数
    ///   - allowedClipIDs: 允许的 clip_id 集合
    /// - Returns: 按相似度降序排列的搜索结果
    public func searchSimilarity(
        query: [Float],
        count: Int,
        allowedClipIDs: Set<Int64>
    ) throws -> [VectorSearchResult] {
        let allowedKeys = Set(allowedClipIDs.map { UInt64(bitPattern: $0) })
        let (keys, distances) = try index.filteredSearch(
            vector: query,
            count: count,
            filter: { allowedKeys.contains($0) }
        )
        return zip(keys, distances).map { key, distance in
            VectorSearchResult(
                clipId: Int64(bitPattern: key),
                similarity: min(1.0, max(0.0, 1.0 - distance))
            )
        }
    }

    // MARK: - Persistence

    public func save(to path: String) throws {
        // 确保父目录存在
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        try index.save(path: path)
    }

    public func load(from path: String) throws {
        try index.load(path: path)
        lock.lock()
        reservedCapacity = (try? index.count) ?? 0
        lock.unlock()
    }

    public func view(from path: String) throws {
        try index.view(path: path)
        lock.lock()
        reservedCapacity = (try? index.count) ?? 0
        isReadOnly = true
        lock.unlock()
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        try guardNotReadOnly()
        try index.clear()
        reservedCapacity = 0
    }

    /// 预分配容量（大批量添加前调用以减少重新分配）
    public func reserve(_ capacity: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        try reserveLocked(capacity)
    }

    /// 检查只读状态（调用方必须已持有 lock）
    private func guardNotReadOnly() throws {
        if isReadOnly {
            throw VectorIndexError.readOnly
        }
    }

    /// 不加锁的预分配（调用方必须已持有 lock）
    private func reserveLocked(_ capacity: Int) throws {
        try index.reserve(UInt32(capacity))
        reservedCapacity = capacity
    }

    /// 确保有足够容量容纳新增向量（调用方必须已持有 lock）
    private func ensureCapacityLocked(for additionalCount: Int) throws {
        let currentCount = (try? index.count) ?? 0
        let needed = currentCount + additionalCount
        if needed > reservedCapacity {
            let newCapacity = max(
                needed,
                max(Self.initialCapacity, reservedCapacity * Self.growFactor)
            )
            try reserveLocked(newCapacity)
        }
    }

    // MARK: - Convenience

    /// 检查索引文件是否存在
    public static func indexFileExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// 加载或创建索引
    ///
    /// 如果索引文件存在则加载（mmap 模式），否则创建新空索引。
    ///
    /// - Parameters:
    ///   - path: 索引文件路径
    ///   - config: HNSW 配置
    ///   - useMmap: 是否使用 mmap 只读模式（适合搜索场景）
    /// - Returns: 加载好的索引
    public static func loadOrCreate(
        at path: String,
        config: Config = .clip768,
        useMmap: Bool = false
    ) throws -> USearchVectorIndex {
        let vectorIndex = try USearchVectorIndex(config: config)
        if indexFileExists(at: path) {
            if useMmap {
                try vectorIndex.view(from: path)
            } else {
                try vectorIndex.load(from: path)
            }
        }
        return vectorIndex
    }
}

// MARK: - Key Conversion Helpers

extension USearchVectorIndex {

    /// Int64 clip_id → UInt64 key (正数直接转换，负数用 bit pattern)
    public static func clipIdToKey(_ clipId: Int64) -> UInt64 {
        UInt64(bitPattern: clipId)
    }

    /// UInt64 key → Int64 clip_id
    public static func keyToClipId(_ key: UInt64) -> Int64 {
        Int64(bitPattern: key)
    }
}

// MARK: - VectorIndexError

/// USearch 向量索引错误
public enum VectorIndexError: LocalizedError, Sendable {
    /// 尝试对 mmap 只读索引执行写操作
    case readOnly

    public var errorDescription: String? {
        switch self {
        case .readOnly:
            return "Cannot modify a read-only (mmap) vector index. Load with load() instead of view() for write access."
        }
    }
}
