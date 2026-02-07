import Foundation

/// 索引行为配置
///
/// 控制后台索引的功能开关和性能模式。Settings 页面读写此配置，
/// `IndexingManager` 运行时从此处读取参数。
///
/// 持久化使用 UserDefaults（同 `ProviderConfig`）。
/// 无保存值时回退到编译期默认值。
public struct IndexingOptions: Codable, Sendable, Equatable {

    // MARK: - 功能开关

    /// 跳过语音转录（包括 SpeechAnalyzer 和 WhisperKit）
    public var skipStt: Bool

    /// 跳过云端视觉分析（Gemini）。本地视觉分析（Apple Vision）始终运行。
    public var skipVision: Bool

    /// 跳过向量嵌入计算
    public var skipEmbedding: Bool

    // MARK: - 性能

    /// 索引性能模式
    public var performanceMode: PerformanceMode

    // MARK: - 默认值

    public static let `default` = IndexingOptions(
        skipStt: false,
        skipVision: false,
        skipEmbedding: false,
        performanceMode: .balanced
    )

    public init(
        skipStt: Bool = false,
        skipVision: Bool = false,
        skipEmbedding: Bool = false,
        performanceMode: PerformanceMode = .balanced
    ) {
        self.skipStt = skipStt
        self.skipVision = skipVision
        self.skipEmbedding = skipEmbedding
        self.performanceMode = performanceMode
    }

    // MARK: - 持久化

    private static let userDefaultsKey = "FindIt.IndexingOptions"

    /// 从 UserDefaults 加载（无保存值时返回默认）
    public static func load() -> IndexingOptions {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let options = try? JSONDecoder().decode(IndexingOptions.self, from: data) else {
            return .default
        }
        return options
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
