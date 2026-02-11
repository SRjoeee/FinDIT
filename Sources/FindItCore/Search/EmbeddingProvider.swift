import Foundation
import Accelerate

// MARK: - EmbeddingError

/// 向量嵌入相关错误
public enum EmbeddingError: LocalizedError, Sendable {
    /// Provider 不可用（未安装模型、无 API Key 等）
    case providerNotAvailable(name: String)
    /// 嵌入计算失败
    case embeddingFailed(detail: String)
    /// 向量维度不匹配
    case dimensionMismatch(expected: Int, got: Int)
    /// API 返回错误
    case apiError(statusCode: Int, message: String)
    /// 网络请求失败
    case networkError(detail: String)

    public var errorDescription: String? {
        switch self {
        case .providerNotAvailable(let name):
            return "Embedding provider '\(name)' 不可用"
        case .embeddingFailed(let detail):
            return "嵌入计算失败: \(detail)"
        case .dimensionMismatch(let expected, let got):
            return "向量维度不匹配: 期望 \(expected), 实际 \(got)"
        case .apiError(let statusCode, let message):
            return "API 错误 (\(statusCode)): \(message)"
        case .networkError(let detail):
            return "网络请求失败: \(detail)"
        }
    }
}

// MARK: - EmbeddingProvider

/// 向量嵌入提供者协议
///
/// 抽象不同的嵌入实现（Gemini API、Apple NLEmbedding、未来的 BGE-M3）。
/// 所有实现必须提供 `name`（用于存储到 `embedding_model` 列）和
/// `dimensions`（向量维度），搜索时只匹配同一 provider 的向量。
public protocol EmbeddingProvider: Sendable {
    /// Provider 标识名（如 "gemini", "nl-embedding"）
    var name: String { get }

    /// 输出向量维度
    var dimensions: Int { get }

    /// 检查当前是否可用（API Key 存在、模型已下载等）
    func isAvailable() -> Bool

    /// 计算单文本的嵌入向量
    func embed(text: String) async throws -> [Float]

    /// 批量计算嵌入向量（默认实现逐个调用 embed）
    func embedBatch(texts: [String]) async throws -> [[Float]]
}

/// 默认 embedBatch 实现：逐个调用 embed
extension EmbeddingProvider {
    public func embedBatch(texts: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        for text in texts {
            let vector = try await embed(text: text)
            results.append(vector)
        }
        return results
    }
}

// MARK: - EmbeddingUtils

/// 向量嵌入工具函数
///
/// 提供文本合成、余弦相似度（vDSP 加速）、向量序列化等纯函数。
public enum EmbeddingUtils {

    /// 从 Clip 的各字段合成待嵌入文本
    ///
    /// 按 EmbeddingGroup 分组拼接视觉字段，然后追加 transcript。
    /// tags 不包含在内（其内容已由视觉字段覆盖，避免重复稀释语义）。
    /// 空字段自动跳过，确保输出文本非空且有意义。
    ///
    /// - Parameters:
    ///   - clip: 视频片段记录
    ///   - fields: 要包含的视觉字段（默认 allActive）
    /// - Returns: 合成后的文本
    public static func composeClipText(
        clip: Clip,
        fields: [VisionField] = VisionField.allActive
    ) -> String {
        var parts: [String] = []

        // 按 EmbeddingGroup 分组遍历视觉字段
        for group in VisionField.EmbeddingGroup.allCases {
            let fieldsInGroup = fields.filter { $0.embeddingGroup == group }
            var groupParts: [String] = []
            for field in fieldsInGroup {
                if let v = clip.visionValue(for: field), !v.isEmpty {
                    if field.isArray,
                       let data = v.data(using: .utf8),
                       let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                        let text = arr.filter { !$0.isEmpty }.joined(separator: ", ")
                        if !text.isEmpty { groupParts.append(text) }
                    } else {
                        groupParts.append(v)
                    }
                }
            }
            if !groupParts.isEmpty {
                parts.append(groupParts.joined(separator: group.separator))
            }
        }

        // 转录文本（台词）— 非视觉字段，单独处理
        if let transcript = clip.transcript, !transcript.isEmpty {
            parts.append(transcript)
        }

        // 注: tags 不再追加到嵌入文本中。
        // tags 由 composeTags 从上述视觉字段合成，内容已包含在各字段中，
        // 重复拼接会稀释 embedding 的语义焦点。

        return parts.joined(separator: ". ")
    }

    // MARK: - 余弦相似度

    /// 计算两个向量的余弦相似度
    ///
    /// 使用 Accelerate/vDSP SIMD 加速计算。
    /// 返回值范围 [-1, 1]，1 表示完全相同方向，0 表示正交，-1 表示完全相反。
    ///
    /// - Parameters:
    ///   - a: 向量 A
    ///   - b: 向量 B（长度必须与 A 相同）
    /// - Returns: 余弦相似度。如果任一向量为空或长度不同，返回 0。
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 0.0 }

        var dotProduct: Float = 0.0
        var normA: Float = 0.0
        var normB: Float = 0.0

        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        vDSP_dotpr(a, 1, a, 1, &normA, vDSP_Length(a.count))
        vDSP_dotpr(b, 1, b, 1, &normB, vDSP_Length(b.count))

        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 0 else { return 0.0 }

        return dotProduct / denominator
    }

    // MARK: - 序列化

    /// 将 Float 数组序列化为 Data
    ///
    /// 直接复制连续内存，无编码开销。
    /// 输出大小 = count × 4 bytes (Float32)。
    ///
    /// - Parameter vector: 嵌入向量
    /// - Returns: 序列化后的 Data
    public static func serializeEmbedding(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    /// 将 Data 反序列化为 Float 数组
    ///
    /// - Parameter data: 序列化的向量数据
    /// - Returns: 嵌入向量
    public static func deserializeEmbedding(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { bytes in
            let buffer = bytes.bindMemory(to: Float.self)
            return Array(buffer)
        }
    }

    // MARK: - 归一化

    /// Min-Max 归一化一组分数到 [0, 1]
    ///
    /// 用于融合 FTS5 rank 和余弦相似度。
    /// 空数组或所有值相同时返回全 0。
    ///
    /// - Parameter values: 原始分数数组
    /// - Returns: 归一化后的数组
    public static func minMaxNormalize(_ values: [Double]) -> [Double] {
        guard let minVal = values.min(), let maxVal = values.max() else { return [] }
        let range = maxVal - minVal
        guard range > 0 else {
            return Array(repeating: 0.0, count: values.count)
        }
        return values.map { ($0 - minVal) / range }
    }

    /// L2 归一化（单位向量化）
    ///
    /// - Parameter vector: 输入向量
    /// - Returns: L2 归一化后的向量（零向量返回原值）
    public static func l2Normalize(_ vector: [Float]) -> [Float] {
        var sum: Float = 0
        for x in vector { sum += x * x }
        let norm = sqrt(sum)
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }
}
