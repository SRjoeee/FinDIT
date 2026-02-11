import Foundation

/// EmbeddingGemma 嵌入提供者
///
/// 将 `EmbeddingGemmaEncoder` 封装为 `EmbeddingProvider` 协议实例，
/// 便于与 `GeminiEmbeddingProvider` 统一调用。
///
/// 作为 Gemini 云端嵌入的离线回退：
/// - 无 API Key 时自动降级使用
/// - 768 维输出与 Gemini embedding-001 兼容
/// - 可在同一 VectorStore 中混合搜索
///
/// 典型回退链: Gemini → EmbeddingGemma → nil（仅 FTS5 + CLIP）
public final class EmbeddingGemmaProvider: EmbeddingProvider, @unchecked Sendable {

    public let name = "embedding-gemma"
    public let dimensions: Int

    private let encoder: EmbeddingGemmaEncoder

    /// 创建 EmbeddingGemma 提供者
    ///
    /// - Parameters:
    ///   - encoder: 编码器实例（默认使用标准路径的 EmbeddingGemmaEncoder）
    ///   - config: 模型配置
    public init(
        encoder: EmbeddingGemmaEncoder? = nil,
        config: EmbeddingGemmaConfig = .default300M
    ) {
        self.encoder = encoder ?? EmbeddingGemmaEncoder(config: config)
        self.dimensions = config.embeddingDimension
    }

    public func isAvailable() -> Bool {
        EmbeddingGemmaModelManager.allModelsAvailable()
    }

    public func embed(text: String) async throws -> [Float] {
        guard isAvailable() else {
            throw EmbeddingError.providerNotAvailable(name: name)
        }
        return try await encoder.encode(text: text)
    }

    // embedBatch 使用协议默认实现（逐个调用 embed）
}
