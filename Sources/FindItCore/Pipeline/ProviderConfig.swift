import Foundation

// MARK: - APIProvider

/// API 提供者类型
///
/// 封装不同 API 提供者的 base URL、认证方式等差异。
/// 切换提供者只需改配置，无需改业务代码。
public enum APIProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case gemini
    case openRouter
    /// FindIt 代理 API（预留，需后端服务上线后启用）
    case findItCloud

    public var id: String { rawValue }

    /// 默认 base URL
    public var defaultBaseURL: String {
        switch self {
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .findItCloud: return "https://proxy.findit.app/v1"
        }
    }

    /// Auth header 名称
    public var authHeaderName: String {
        switch self {
        case .gemini: return "x-goog-api-key"
        case .openRouter, .findItCloud: return "Authorization"
        }
    }

    /// 根据 API key 生成 auth header 值
    public func authHeaderValue(apiKey: String) -> String {
        switch self {
        case .gemini: return apiKey
        case .openRouter, .findItCloud: return "Bearer \(apiKey)"
        }
    }

    /// 显示名称（Settings UI 用）
    public var displayName: String {
        switch self {
        case .gemini: return "Google Gemini"
        case .openRouter: return "OpenRouter"
        case .findItCloud: return "FindIt Cloud"
        }
    }

    /// API Key 配置文件路径
    public var keyFilePath: String {
        switch self {
        case .gemini: return "~/.config/findit/gemini-api-key.txt"
        case .openRouter: return "~/.config/findit/openrouter-api-key.txt"
        case .findItCloud: return "~/.config/findit/findit-cloud-token.txt"
        }
    }

    /// API Key 环境变量名
    public var envVarName: String {
        switch self {
        case .gemini: return "GEMINI_API_KEY"
        case .openRouter: return "OPENROUTER_API_KEY"
        case .findItCloud: return "FINDIT_CLOUD_TOKEN"
        }
    }
}

// MARK: - ProviderConfig

/// 外部 API 提供者配置
///
/// 集中管理 API 提供者、模型名称、端点参数和默认配置。
/// Settings 页面读写此配置，运行时各模块从此处获取参数。
///
/// 持久化使用 UserDefaults（macOS Settings 原生支持）。
/// 无保存值时回退到编译期默认值。
///
/// API Key 不在此处管理（存储在 `~/.config/findit/`，保持 CLI 兼容）。
public struct ProviderConfig: Codable, Sendable, Equatable {

    // MARK: - Provider

    /// API 提供者
    public var provider: APIProvider

    /// 自定义 base URL（nil = 使用 provider 默认值）
    public var baseURL: String?

    /// 实际使用的 base URL（自定义 > provider 默认）
    public var effectiveBaseURL: String {
        baseURL ?? provider.defaultBaseURL
    }

    // MARK: - Vision

    /// 视觉分析模型名称
    public var visionModel: String

    /// 每请求最大图片数
    public var visionMaxImages: Int

    /// 请求超时（秒）
    public var visionTimeout: Double

    /// 最大重试次数（429/503/500）
    public var visionMaxRetries: Int

    // MARK: - Embedding

    /// 嵌入模型名称
    public var embeddingModel: String

    /// 输出向量维度
    public var embeddingDimensions: Int

    // MARK: - Rate Limiting

    /// 每分钟请求数上限
    public var rateLimitRPM: Int

    // MARK: - 默认值

    public static let `default` = ProviderConfig(
        provider: .gemini,
        visionModel: "gemini-2.5-flash",
        visionMaxImages: 10,
        visionTimeout: 60.0,
        visionMaxRetries: 3,
        embeddingModel: "gemini-embedding-001",
        embeddingDimensions: 768,
        rateLimitRPM: 9
    )

    public init(
        provider: APIProvider = .gemini,
        baseURL: String? = nil,
        visionModel: String = "gemini-2.5-flash",
        visionMaxImages: Int = 10,
        visionTimeout: Double = 60.0,
        visionMaxRetries: Int = 3,
        embeddingModel: String = "gemini-embedding-001",
        embeddingDimensions: Int = 768,
        rateLimitRPM: Int = 9
    ) {
        self.provider = provider
        self.baseURL = baseURL
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
            maxRetries: visionMaxRetries,
            provider: provider,
            baseURL: effectiveBaseURL
        )
    }

    /// 转换为 GeminiEmbedding.Config
    public func toEmbeddingConfig() -> GeminiEmbedding.Config {
        GeminiEmbedding.Config(
            model: embeddingModel,
            outputDimensionality: embeddingDimensions,
            provider: provider,
            baseURL: effectiveBaseURL
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
