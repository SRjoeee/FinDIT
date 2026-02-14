import Foundation

/// 云端能力模式
///
/// 控制 Layer 3 (VLM + 文本嵌入) 使用的引擎：
/// - `local`: 纯本地处理，无网络调用
/// - `cloud`: 使用 Gemini API 进行高质量分析
///
/// 这是最高级别的云端开关，替代了旧的 `skipVision` + `skipEmbedding` 组合。
public enum CloudMode: String, Codable, Sendable, CaseIterable {
    /// 纯本地：L3 使用 LocalVLM (opt-in) + EmbeddingGemma，无网络调用
    case local
    /// 云端增强：L3 使用 Gemini API (需要 API Key)
    case cloud

    /// 用户可见的显示标签
    public var displayLabel: String {
        switch self {
        case .local: "纯本地 (离线可用)"
        case .cloud: "云端增强 (需要 API Key)"
        }
    }

    /// 简短描述
    public var descriptionText: String {
        switch self {
        case .local:
            "所有处理在设备上完成。视觉分析使用本地模型，文本嵌入使用 EmbeddingGemma。无需网络，隐私性最高。"
        case .cloud:
            "使用 Gemini API 进行视觉分析和文本嵌入，质量更高。需要 API Key 和网络连接。"
        }
    }
}
