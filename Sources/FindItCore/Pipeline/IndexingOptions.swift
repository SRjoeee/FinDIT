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

    // MARK: - Orphaned

    /// Orphaned 视频保留天数（0 = 禁用软删除，立即硬删除）
    public var orphanedRetentionDays: Int

    // MARK: - 默认值

    public static let `default` = IndexingOptions(
        skipStt: false,
        skipVision: false,
        skipEmbedding: false,
        performanceMode: .balanced,
        orphanedRetentionDays: 30
    )

    public init(
        skipStt: Bool = false,
        skipVision: Bool = false,
        skipEmbedding: Bool = false,
        performanceMode: PerformanceMode = .balanced,
        orphanedRetentionDays: Int = 30
    ) {
        self.skipStt = skipStt
        self.skipVision = skipVision
        self.skipEmbedding = skipEmbedding
        self.performanceMode = performanceMode
        self.orphanedRetentionDays = orphanedRetentionDays
    }

    // MARK: - Decodable（向后兼容旧版 UserDefaults 数据）

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skipStt = try c.decodeIfPresent(Bool.self, forKey: .skipStt) ?? false
        skipVision = try c.decodeIfPresent(Bool.self, forKey: .skipVision) ?? false
        skipEmbedding = try c.decodeIfPresent(Bool.self, forKey: .skipEmbedding) ?? false
        performanceMode = try c.decodeIfPresent(PerformanceMode.self, forKey: .performanceMode) ?? .balanced
        orphanedRetentionDays = try c.decodeIfPresent(Int.self, forKey: .orphanedRetentionDays) ?? 30
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
