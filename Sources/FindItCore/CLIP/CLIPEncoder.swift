import Foundation

// MARK: - CLIP Image Encoder Protocol

/// 图片 → CLIP 向量编码器
///
/// 将图片编码为 CLIP 嵌入空间中的向量。
/// 与 `CLIPTextEncoder` 输出在同一嵌入空间，支持跨模态搜索。
public protocol CLIPImageEncoder: Sendable {
    /// 编码器标识名（如 "siglip2-base"）
    var name: String { get }

    /// 输出向量维度（SigLIP2-base = 768）
    var dimensions: Int { get }

    /// 检查编码器是否可用（模型文件存在等）
    func isAvailable() -> Bool

    /// 编码单张图片
    ///
    /// - Parameter imageData: 图片数据（JPEG/PNG/HEIC 等，解码由实现负责）
    /// - Returns: L2 归一化的嵌入向量
    func encode(imageData: Data) async throws -> [Float]

    /// 编码图片文件
    ///
    /// - Parameter imagePath: 图片文件路径
    /// - Returns: L2 归一化的嵌入向量
    func encode(imagePath: String) async throws -> [Float]

    /// 批量编码图片文件
    ///
    /// 默认实现逐个调用 `encode(imagePath:)`，子类可覆盖优化。
    func encodeBatch(imagePaths: [String]) async throws -> [[Float]]
}

// MARK: - Default Batch Implementation

extension CLIPImageEncoder {
    public func encodeBatch(imagePaths: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        for path in imagePaths {
            let embedding = try await encode(imagePath: path)
            results.append(embedding)
        }
        return results
    }
}

// MARK: - CLIP Text Encoder Protocol

/// 文本 → CLIP 向量编码器
///
/// 将文本编码为 CLIP 嵌入空间中的向量。
/// 与 `CLIPImageEncoder` 输出在同一嵌入空间，支持跨模态搜索。
public protocol CLIPTextEncoder: Sendable {
    /// 编码器标识名（如 "siglip2-base"）
    var name: String { get }

    /// 输出向量维度（SigLIP2-base = 768）
    var dimensions: Int { get }

    /// 检查编码器是否可用（模型文件 + tokenizer 存在等）
    func isAvailable() -> Bool

    /// 编码单条文本
    ///
    /// - Parameter text: 查询文本（中英文均可，实现负责小写化等预处理）
    /// - Returns: L2 归一化的嵌入向量
    func encode(text: String) async throws -> [Float]

    /// 批量编码文本
    ///
    /// 默认实现逐个调用 `encode(text:)`，子类可覆盖优化。
    func encodeBatch(texts: [String]) async throws -> [[Float]]
}

// MARK: - Default Batch Implementation

extension CLIPTextEncoder {
    public func encodeBatch(texts: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        for text in texts {
            let embedding = try await encode(text: text)
            results.append(embedding)
        }
        return results
    }
}

// MARK: - CLIP Errors

/// CLIP 编码器错误
public enum CLIPError: LocalizedError, Sendable {
    /// 模型文件未找到
    case modelNotFound(path: String)
    /// Tokenizer 加载失败
    case tokenizerFailed(detail: String)
    /// 图片加载或预处理失败
    case imageProcessingFailed(detail: String)
    /// ONNX Runtime 推理失败
    case inferenceFailed(detail: String)
    /// 输出维度不匹配
    case dimensionMismatch(expected: Int, got: Int)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            return "CLIP model not found: \(path)"
        case .tokenizerFailed(let detail):
            return "Tokenizer failed: \(detail)"
        case .imageProcessingFailed(let detail):
            return "Image processing failed: \(detail)"
        case .inferenceFailed(let detail):
            return "CLIP inference failed: \(detail)"
        case .dimensionMismatch(let expected, let got):
            return "Dimension mismatch: expected \(expected), got \(got)"
        }
    }
}

// MARK: - CLIP Configuration

/// SigLIP2 模型配置
public struct SigLIP2Config: Sendable {
    /// 输入图片尺寸（正方形，像素）
    public let imageSize: Int
    /// 像素归一化均值
    public let imageMean: Float
    /// 像素归一化标准差
    public let imageStd: Float
    /// 最大文本 token 长度
    public let maxTextLength: Int
    /// 输出嵌入维度
    public let embeddingDimension: Int
    /// PAD token ID
    public let padTokenId: Int32
    /// EOS token ID
    public let eosTokenId: Int32

    /// SigLIP2-base-patch16-224 默认配置
    public static let base224 = SigLIP2Config(
        imageSize: 224,
        imageMean: 0.5,
        imageStd: 0.5,
        maxTextLength: 64,
        embeddingDimension: 768,
        padTokenId: 0,
        eosTokenId: 1
    )

    public init(
        imageSize: Int = 224,
        imageMean: Float = 0.5,
        imageStd: Float = 0.5,
        maxTextLength: Int = 64,
        embeddingDimension: Int = 768,
        padTokenId: Int32 = 0,
        eosTokenId: Int32 = 1
    ) {
        self.imageSize = imageSize
        self.imageMean = imageMean
        self.imageStd = imageStd
        self.maxTextLength = maxTextLength
        self.embeddingDimension = embeddingDimension
        self.padTokenId = padTokenId
        self.eosTokenId = eosTokenId
    }
}
