import Foundation

/// CLIP 嵌入服务
///
/// 统一管理 SigLIP2 image encoder 和 text encoder，提供:
/// - 图片 → CLIP 向量（索引时使用）
/// - 文本 → CLIP 向量（搜索时使用）
/// - LRU 缓存加速重复查询
///
/// 两个 encoder 共享同一 ONNX 模型文件但独立管理 session 生命周期，
/// 支持分别按需加载以控制内存峰值。
public actor CLIPEmbeddingProvider {

    /// Provider 标识名
    public let name = "siglip2-clip"

    /// 嵌入维度
    public let dimensions: Int

    private let imageEncoder: CLIPImageEncoder
    private let textEncoder: CLIPTextEncoder

    /// 文本查询 LRU 缓存（搜索场景高频重复）
    private var textCache: LRUCache<String, [Float]>

    /// 创建 CLIP 嵌入服务
    ///
    /// - Parameters:
    ///   - imageEncoder: 图片编码器（默认 SigLIP2ImageEncoder）
    ///   - textEncoder: 文本编码器（默认 SigLIP2TextEncoder）
    ///   - cacheCapacity: 文本缓存容量（默认 256）
    public init(
        imageEncoder: CLIPImageEncoder? = nil,
        textEncoder: CLIPTextEncoder? = nil,
        cacheCapacity: Int = 256
    ) {
        let imgEnc = imageEncoder ?? SigLIP2ImageEncoder()
        let txtEnc = textEncoder ?? SigLIP2TextEncoder()
        self.imageEncoder = imgEnc
        self.textEncoder = txtEnc
        self.dimensions = imgEnc.dimensions
        self.textCache = LRUCache(capacity: cacheCapacity)
    }

    /// 检查 CLIP 是否可用（模型文件存在）
    public var isAvailable: Bool {
        imageEncoder.isAvailable() && textEncoder.isAvailable()
    }

    /// 仅检查图片编码器是否可用（索引时只需 vision）
    public var isImageEncoderAvailable: Bool {
        imageEncoder.isAvailable()
    }

    /// 仅检查文本编码器是否可用（搜索时只需 text）
    public var isTextEncoderAvailable: Bool {
        textEncoder.isAvailable()
    }

    // MARK: - Image Encoding (索引时)

    /// 编码关键帧图片为 CLIP 向量
    ///
    /// - Parameter imagePath: 关键帧 JPEG 文件路径
    /// - Returns: 768 维 L2 归一化向量
    public func encodeImage(path: String) async throws -> [Float] {
        try await imageEncoder.encode(imagePath: path)
    }

    /// 编码图片数据为 CLIP 向量
    public func encodeImage(data: Data) async throws -> [Float] {
        try await imageEncoder.encode(imageData: data)
    }

    /// 批量编码关键帧
    public func encodeImages(paths: [String]) async throws -> [[Float]] {
        try await imageEncoder.encodeBatch(imagePaths: paths)
    }

    // MARK: - Text Encoding (搜索时)

    /// 编码搜索查询为 CLIP 向量
    ///
    /// 自动查询 LRU 缓存，命中则跳过推理。
    ///
    /// - Parameter text: 搜索查询（中英文均可）
    /// - Returns: 768 维 L2 归一化向量
    public func encodeText(_ text: String) async throws -> [Float] {
        let cacheKey = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if let cached = textCache.get(cacheKey) {
            return cached
        }

        let embedding = try await textEncoder.encode(text: text)
        textCache.put(cacheKey, value: embedding)
        return embedding
    }

    /// 批量编码文本（带缓存）
    public func encodeTexts(_ texts: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        for text in texts {
            let embedding = try await encodeText(text)
            results.append(embedding)
        }
        return results
    }

    /// 清空文本缓存
    public func clearCache() {
        textCache.clear()
    }

    /// 当前缓存命中率统计
    public var cacheStats: (hits: Int, misses: Int) {
        (textCache.hits, textCache.misses)
    }
}

// MARK: - LRU Cache

/// 简单的 LRU 缓存（非线程安全，由 actor 保护）
struct LRUCache<Key: Hashable, Value> {
    private let capacity: Int
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []
    private(set) var hits: Int = 0
    private(set) var misses: Int = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func get(_ key: Key) -> Value? {
        if let value = storage[key] {
            // Move to end (most recently used)
            if let idx = order.firstIndex(of: key) {
                order.remove(at: idx)
                order.append(key)
            }
            hits += 1
            return value
        }
        misses += 1
        return nil
    }

    mutating func put(_ key: Key, value: Value) {
        if storage[key] != nil {
            // Update existing
            storage[key] = value
            if let idx = order.firstIndex(of: key) {
                order.remove(at: idx)
                order.append(key)
            }
        } else {
            // Evict if at capacity
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
        hits = 0
        misses = 0
    }

    var count: Int { storage.count }
}
