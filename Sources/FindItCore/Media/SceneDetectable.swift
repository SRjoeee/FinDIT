import Foundation

/// 场景检测能力协议
///
/// 独立于 `MediaDecoder`，因为场景检测是 FFmpeg 专属能力，
/// AVFoundation 等其他后端不支持。
///
/// `CompositeMediaService` 在需要场景检测时，检查选中的 decoder
/// 是否实现了此协议，如果没有则 fallback 或报错。
public protocol SceneDetectable {

    /// 优化的场景检测（单次调用完成场景检测 + 时长获取 + 可选音频提取）
    ///
    /// - Parameters:
    ///   - filePath: 视频文件路径
    ///   - audioOutputPath: 音频输出路径（nil 则不提取音频）
    ///   - config: 场景检测配置
    /// - Returns: 包含场景列表、时长和音频提取状态的组合结果
    func detectScenesOptimized(
        filePath: String,
        audioOutputPath: String?,
        config: SceneDetector.Config
    ) async throws -> SceneDetector.CombinedDetectionResult
}
