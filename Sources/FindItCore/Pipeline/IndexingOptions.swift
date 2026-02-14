import Foundation

/// STT 引擎偏好
///
/// 控制语音转录使用的引擎。WhisperKit 精度最高（尤其 CJK），
/// SpeechAnalyzer 速度极快（70x 实时）但 CJK 分段为逐字级。
public enum STTEngine: String, Codable, Sendable, CaseIterable {
    /// 自动: WhisperKit 优先，SpeechAnalyzer 回退
    case auto = "auto"
    /// 强制 WhisperKit（高精度，~1.5GB 模型）
    case whisperKitOnly = "whisperkit"
    /// 强制 SpeechAnalyzer（轻量，系统管理模型）
    case speechAnalyzerOnly = "speechanalyzer"

    /// 用户可见的显示标签
    public var displayLabel: String {
        switch self {
        case .auto: "自动 (WhisperKit 优先)"
        case .whisperKitOnly: "WhisperKit (高精度)"
        case .speechAnalyzerOnly: "SpeechAnalyzer (轻量)"
        }
    }
}

/// 索引行为配置
///
/// 控制后台索引的功能开关和性能模式。Settings 页面读写此配置，
/// `IndexingManager` 运行时从此处读取参数。
///
/// 持久化使用 UserDefaults（同 `ProviderConfig`）。
/// 无保存值时回退到编译期默认值。
public struct IndexingOptions: Codable, Sendable, Equatable {

    // MARK: - 核心开关

    /// 云端模式（替代旧的 skipVision + skipEmbedding）
    ///
    /// - `.local`: L3 使用 LocalVLM (opt-in) + EmbeddingGemma，无网络调用
    /// - `.cloud`: L3 使用 Gemini API 进行高质量分析
    public var cloudMode: CloudMode

    /// 跳过语音转录（包括 SpeechAnalyzer 和 WhisperKit）
    public var skipStt: Bool

    /// 启用 LocalVLM 深度分析（纯本地模式下）
    ///
    /// 开启后使用 Qwen3-VL-4B 提供 9/9 字段分析（含 description/mood/actions），
    /// 但首次需下载 ~3GB 模型，且推理速度 ~5-10s/clip。
    /// 仅在 `cloudMode == .local` 时生效。
    public var useLocalVLM: Bool

    // MARK: - STT

    /// STT 引擎偏好
    public var sttEngine: STTEngine

    /// STT 语言提示（ISO 639-1，如 "ja", "zh", "en"），nil = 自动检测
    public var sttLanguageHint: String?

    // MARK: - SRT 文件

    /// 在 Finder 中隐藏生成的 SRT 文件
    public var hideSrtFiles: Bool

    // MARK: - 性能

    /// 索引性能模式
    public var performanceMode: PerformanceMode

    // MARK: - Orphaned

    /// Orphaned 视频保留天数（0 = 禁用软删除，立即硬删除）
    public var orphanedRetentionDays: Int

    // MARK: - 向后兼容计算属性

    /// 是否跳过云端视觉分析（向后兼容旧引用点）
    public var skipVision: Bool {
        get { cloudMode == .local }
        set { cloudMode = newValue ? .local : .cloud }
    }

    /// 是否跳过向量嵌入（向后兼容旧引用点）
    public var skipEmbedding: Bool {
        get { cloudMode == .local && !useLocalVLM }
        set { /* 由 cloudMode 统一管理 */ }
    }

    // MARK: - 默认值

    public static let `default` = IndexingOptions(
        cloudMode: .local,
        skipStt: false,
        useLocalVLM: false,
        performanceMode: .balanced,
        sttEngine: .auto,
        sttLanguageHint: nil,
        hideSrtFiles: true,
        orphanedRetentionDays: 30
    )

    public init(
        cloudMode: CloudMode = .local,
        skipStt: Bool = false,
        useLocalVLM: Bool = false,
        performanceMode: PerformanceMode = .balanced,
        sttEngine: STTEngine = .auto,
        sttLanguageHint: String? = nil,
        hideSrtFiles: Bool = true,
        orphanedRetentionDays: Int = 30
    ) {
        self.cloudMode = cloudMode
        self.skipStt = skipStt
        self.useLocalVLM = useLocalVLM
        self.performanceMode = performanceMode
        self.sttEngine = sttEngine
        self.sttLanguageHint = sttLanguageHint
        self.hideSrtFiles = hideSrtFiles
        self.orphanedRetentionDays = orphanedRetentionDays
    }

    // MARK: - CodingKeys

    enum CodingKeys: String, CodingKey {
        case cloudMode
        case skipStt
        case useLocalVLM
        case sttEngine
        case sttLanguageHint
        case hideSrtFiles
        case performanceMode
        case orphanedRetentionDays
        // 旧版字段（仅用于 decode 迁移）
        case _skipVision = "skipVision"
        case _skipEmbedding = "skipEmbedding"
    }

    // MARK: - Decodable（向后兼容旧版 UserDefaults 数据）

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // 优先读取新字段 cloudMode；若不存在，从旧的 skipVision 推断
        if let mode = try c.decodeIfPresent(CloudMode.self, forKey: .cloudMode) {
            cloudMode = mode
        } else {
            let oldSkipVision = try c.decodeIfPresent(Bool.self, forKey: ._skipVision) ?? false
            cloudMode = oldSkipVision ? .local : .cloud
        }

        skipStt = try c.decodeIfPresent(Bool.self, forKey: .skipStt) ?? false
        useLocalVLM = try c.decodeIfPresent(Bool.self, forKey: .useLocalVLM) ?? false
        sttEngine = try c.decodeIfPresent(STTEngine.self, forKey: .sttEngine) ?? .auto
        sttLanguageHint = try c.decodeIfPresent(String.self, forKey: .sttLanguageHint)
        hideSrtFiles = try c.decodeIfPresent(Bool.self, forKey: .hideSrtFiles) ?? true
        performanceMode = try c.decodeIfPresent(PerformanceMode.self, forKey: .performanceMode) ?? .balanced
        orphanedRetentionDays = try c.decodeIfPresent(Int.self, forKey: .orphanedRetentionDays) ?? 30
    }

    // MARK: - Encodable（只写新字段）

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cloudMode, forKey: .cloudMode)
        try c.encode(skipStt, forKey: .skipStt)
        try c.encode(useLocalVLM, forKey: .useLocalVLM)
        try c.encode(sttEngine, forKey: .sttEngine)
        try c.encodeIfPresent(sttLanguageHint, forKey: .sttLanguageHint)
        try c.encode(hideSrtFiles, forKey: .hideSrtFiles)
        try c.encode(performanceMode, forKey: .performanceMode)
        try c.encode(orphanedRetentionDays, forKey: .orphanedRetentionDays)
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
