import Foundation

/// 外部 API 提供者配置
///
/// 集中管理所有 Gemini API 模型名称、端点参数和默认配置。
/// Settings 页面读写此配置，运行时各模块从此处获取参数。
///
/// 持久化使用 UserDefaults（macOS Settings 原生支持）。
/// 无保存值时回退到编译期默认值。
///
/// API Key 不在此处管理（存储在 `~/.config/findit/`，保持 CLI 兼容）。
public struct ProviderConfig: Codable, Sendable, Equatable {

    // MARK: - Gemini Vision

    /// Gemini 视觉分析模型名称
    public var visionModel: String

    /// 每请求最大图片数
    public var visionMaxImages: Int

    /// 请求超时（秒）
    public var visionTimeout: Double

    /// 最大重试次数（429/503/500）
    public var visionMaxRetries: Int

    // MARK: - Gemini Embedding

    /// Gemini 嵌入模型名称
    public var embeddingModel: String

    /// 输出向量维度
    public var embeddingDimensions: Int

    // MARK: - Rate Limiting

    /// 每分钟请求数上限
    public var rateLimitRPM: Int

    // MARK: - 默认值

    public static let `default` = ProviderConfig(
        visionModel: "gemini-2.5-flash",
        visionMaxImages: 10,
        visionTimeout: 60.0,
        visionMaxRetries: 3,
        embeddingModel: "gemini-embedding-001",
        embeddingDimensions: 768,
        rateLimitRPM: 9
    )

    public init(
        visionModel: String = "gemini-2.5-flash",
        visionMaxImages: Int = 10,
        visionTimeout: Double = 60.0,
        visionMaxRetries: Int = 3,
        embeddingModel: String = "gemini-embedding-001",
        embeddingDimensions: Int = 768,
        rateLimitRPM: Int = 9
    ) {
        self.visionModel = visionModel
        self.visionMaxImages = visionMaxImages
        self.visionTimeout = visionTimeout
        self.visionMaxRetries = visionMaxRetries
        self.embeddingModel = embeddingModel
        self.embeddingDimensions = embeddingDimensions
        self.rateLimitRPM = rateLimitRPM
    }

    // MARK: - 便捷转换

    /// 转换为 VisionAnalyzer.Config
    public func toVisionConfig() -> VisionAnalyzer.Config {
        VisionAnalyzer.Config(
            model: visionModel,
            maxImagesPerRequest: visionMaxImages,
            requestTimeoutSeconds: visionTimeout,
            maxRetries: visionMaxRetries
        )
    }

    /// 转换为 GeminiEmbedding.Config
    public func toEmbeddingConfig() -> GeminiEmbedding.Config {
        GeminiEmbedding.Config(
            model: embeddingModel,
            outputDimensionality: embeddingDimensions
        )
    }

    /// 转换为 GeminiRateLimiter.Config
    public func toRateLimiterConfig() -> GeminiRateLimiter.Config {
        GeminiRateLimiter.Config(maxRequestsPerWindow: rateLimitRPM)
    }

    // MARK: - 持久化

    private static let userDefaultsKey = "FindIt.ProviderConfig"

    /// 从 UserDefaults 加载（无保存值时返回默认）
    public static func load() -> ProviderConfig {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let config = try? JSONDecoder().decode(ProviderConfig.self, from: data) else {
            return .default
        }
        return config
    }

    /// 保存到 UserDefaults
    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }

    /// 重置为默认值
    public static func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
}
