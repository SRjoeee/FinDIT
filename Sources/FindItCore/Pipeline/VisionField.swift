import Foundation

/// 视觉分析字段注册表 — 单一事实来源
///
/// 集中定义所有视觉分析字段的属性、数据库列名、嵌入分组和合并策略。
/// 消费方通过遍历 `allCases` / `allActive` 实现数据驱动，
/// 新增字段只需在此枚举添加 case 并填入计算属性。
///
/// 关联 ADR: PRODUCT_SPEC 3.2.5, ADR-010
public enum VisionField: String, CaseIterable, Sendable {
    case scene
    case subjects
    case actions
    case objects
    case mood
    case shotType
    case lighting
    case colors
    case description

    // MARK: - 嵌入分组

    /// 字段在嵌入文本中的分组
    ///
    /// 分组决定了 `composeClipText` 中字段的拼接方式：
    /// - primary: 主要语义信息（句号分隔）
    /// - detail: 结构化详情（逗号分隔）
    /// - meta: 补充元数据（逗号分隔）
    public enum EmbeddingGroup: Int, CaseIterable, Sendable, Comparable {
        case primary = 0
        case detail = 1
        case meta = 2

        public static func < (lhs: EmbeddingGroup, rhs: EmbeddingGroup) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        /// 组内分隔符
        public var separator: String {
            switch self {
            case .primary: return ". "
            case .detail:  return ", "
            case .meta:    return ", "
            }
        }
    }

    /// 合并策略（本地 + 远程分析结果合并时使用）
    public enum MergeStrategy: Sendable {
        /// 远程非 nil 优先，否则保留本地
        case preferNonNil
        /// 远程非空数组优先，否则保留本地
        case preferNonEmptyArray
    }

    // MARK: - 计算属性

    /// 数据库/JSON 列名（snake_case）
    public var columnName: String {
        switch self {
        case .scene:       return "scene"
        case .subjects:    return "subjects"
        case .actions:     return "actions"
        case .objects:     return "objects"
        case .mood:        return "mood"
        case .shotType:    return "shot_type"
        case .lighting:    return "lighting"
        case .colors:      return "colors"
        case .description: return "description"
        }
    }

    /// 是否为数组类型字段
    public var isArray: Bool {
        switch self {
        case .subjects, .actions, .objects: return true
        default: return false
        }
    }

    /// 是否参与 composeTags 合成
    ///
    /// description 不参与 tags 合成（它是完整句子，不适合做标签）
    public var includeInTags: Bool {
        self != .description
    }

    /// 嵌入文本分组
    public var embeddingGroup: EmbeddingGroup {
        switch self {
        case .scene, .description:             return .primary
        case .subjects, .actions, .objects:     return .detail
        case .mood, .shotType, .lighting, .colors: return .meta
        }
    }

    /// 合并策略
    public var mergeStrategy: MergeStrategy {
        isArray ? .preferNonEmptyArray : .preferNonNil
    }

    /// Gemini response_schema 描述
    public var schemaDescription: String {
        switch self {
        case .scene:       return "场景描述（如：室内办公室、户外海滩）"
        case .subjects:    return "主体列表"
        case .actions:     return "动作列表"
        case .objects:     return "道具/物体列表"
        case .mood:        return "整体氛围/情绪"
        case .shotType:    return "镜头类型（如：特写、中景、全景、航拍）"
        case .lighting:    return "光线条件"
        case .colors:      return "主要色调"
        case .description: return "用 1-2 句自然语言总结这个片段"
        }
    }

    /// Gemini response_schema 属性定义
    public var schemaProperty: [String: Any] {
        if isArray {
            return ["type": "array", "items": ["type": "string"], "description": schemaDescription]
        } else {
            return ["type": "string", "description": schemaDescription]
        }
    }

    /// VLM 提示词行
    public var vlmPromptLine: String {
        switch self {
        case .scene:
            return "- scene: scene type (e.g. \"indoor\", \"outdoor\", \"beach\", \"city\", \"forest\")"
        case .subjects:
            return "- subjects: array of people/characters (e.g. [\"man\", \"woman\", \"child\"])"
        case .actions:
            return "- actions: array of actions happening (e.g. [\"walking\", \"talking\", \"running\"])"
        case .objects:
            return "- objects: array of notable objects (e.g. [\"car\", \"table\", \"phone\"])"
        case .mood:
            return "- mood: overall mood (e.g. \"cheerful\", \"tense\", \"calm\", \"dramatic\")"
        case .shotType:
            return "- shot_type: camera shot type (e.g. \"wide shot\", \"close-up\", \"medium shot\")"
        case .lighting:
            return "- lighting: lighting condition (e.g. \"natural\", \"dark\", \"bright\", \"golden hour\")"
        case .colors:
            return "- colors: dominant color description (e.g. \"warm tones\", \"blue and white\")"
        case .description:
            return "- description: one-sentence description in the same language as any visible text, or Chinese"
        }
    }

    /// CLI/UI 显示标签
    public var displayLabel: String {
        switch self {
        case .scene:       return "场景"
        case .subjects:    return "主体"
        case .actions:     return "动作"
        case .objects:     return "物体"
        case .mood:        return "氛围"
        case .shotType:    return "镜头"
        case .lighting:    return "光线"
        case .colors:      return "色调"
        case .description: return "描述"
        }
    }

    // MARK: - 当前启用字段

    /// 当前启用的字段列表
    ///
    /// 暂时等于 allCases，未来可读取用户配置或 App Settings。
    public static var allActive: [VisionField] {
        Array(allCases)
    }

    // MARK: - 静态工具方法

    /// 构建 Gemini response_schema（结构化输出）
    ///
    /// - Parameter fields: 要包含的字段（默认 allActive）
    /// - Returns: 可用于 Gemini API generationConfig 的 schema 字典
    public static func buildResponseSchema(
        fields: [VisionField] = allActive
    ) -> [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []

        for field in fields {
            properties[field.columnName] = field.schemaProperty
            required.append(field.columnName)
        }

        return [
            "type": "object",
            "properties": properties,
            "required": required,
        ]
    }

    /// 构建 Gemini 视觉分析系统提示词
    ///
    /// 返回发送给 Gemini API 的中文系统指令。
    /// 与 `buildResponseSchema()` 配合使用。
    public static func buildGeminiSystemPrompt() -> String {
        """
        你是一个视频素材分析助手。分析以下视频片段的关键帧（按时间顺序排列）。
        返回 JSON 格式的描述。
        """
    }

    /// 构建 VLM 分析提示词
    ///
    /// - Parameter fields: 要包含的字段（默认 allActive）
    /// - Returns: 完整的分析提示词字符串
    public static func buildVLMPrompt(
        fields: [VisionField] = allActive
    ) -> String {
        let fieldLines = fields.map(\.vlmPromptLine).joined(separator: "\n")
        return """
        Analyze this video frame and return a JSON object with these fields:
        \(fieldLines)

        Return ONLY valid JSON, no markdown or explanation.
        """
    }

    /// 生成 SQL SET 子句（不含 tags）
    ///
    /// 输出示例: `"scene = ?, subjects = ?, ... , description = ?"`
    ///
    /// - Parameter fields: 字段列表（默认 allActive）
    /// - Returns: SQL SET 子句字符串
    public static func sqlSetClause(
        fields: [VisionField] = allActive
    ) -> String {
        fields.map { "\($0.columnName) = ?" }.joined(separator: ", ")
    }

    /// 生成 SQL 列名数组
    ///
    /// - Parameter fields: 字段列表（默认 allActive）
    /// - Returns: 列名数组（如 `["scene", "subjects", ..., "description"]`）
    public static func sqlColumnNames(
        fields: [VisionField] = allActive
    ) -> [String] {
        fields.map(\.columnName)
    }
}
