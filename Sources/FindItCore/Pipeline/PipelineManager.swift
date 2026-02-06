import Foundation
import GRDB

/// 全流程处理管线管理器
///
/// 将所有管线模块（SceneDetector → KeyframeExtractor → AudioExtractor →
/// STTProcessor → VisionAnalyzer）串联为端到端的自动化处理流程。
///
/// 状态机（数据库驱动）:
/// ```
/// pending → stt_running → stt_done → vision_running → completed
///   └──────────── failed ←──── (任何环节出错)
/// ```
///
/// 支持断点续传：Vision 分析每完成一个 clip 更新 `last_processed_clip`，
/// 中断后恢复时只处理剩余 clips。
public enum PipelineManager {

    // MARK: - 数据类型

    /// 处理阶段
    public enum Stage: String, CaseIterable {
        case pending = "pending"
        case sttRunning = "stt_running"
        case sttDone = "stt_done"
        case visionRunning = "vision_running"
        case completed = "completed"
        case failed = "failed"

        /// 阶段顺序索引（用于比较进度）
        var order: Int {
            switch self {
            case .pending:        return 0
            case .sttRunning:     return 1
            case .sttDone:        return 2
            case .visionRunning:  return 3
            case .completed:      return 4
            case .failed:         return -1
            }
        }

        /// 当前阶段是否早于目标阶段
        public func isBefore(_ other: Stage) -> Bool {
            order < other.order
        }
    }

    /// 单视频处理结果
    public struct ProcessingResult {
        /// 视频 ID
        public let videoId: Int64
        /// 创建的 clip 数量
        public let clipsCreated: Int
        /// 已完成视觉分析的 clip 数量
        public let clipsAnalyzed: Int
        /// SRT 文件路径（如有）
        public let srtPath: String?
        /// 同步结果（如有）
        public let syncResult: SyncEngine.SyncResult?
    }

    // MARK: - 纯函数

    /// 生成缩略图存储目录路径
    ///
    /// 格式: `<folderPath>/.clip-index/thumbnails/video_<id>/`
    static func thumbnailDirectory(folderPath: String, videoId: Int64) -> String {
        (folderPath as NSString)
            .appendingPathComponent(".clip-index")
            .appending("/thumbnails/video_\(videoId)")
    }

    /// 生成临时文件目录路径
    ///
    /// 格式: `<folderPath>/.clip-index/tmp/`
    static func tmpDirectory(folderPath: String) -> String {
        (folderPath as NSString)
            .appendingPathComponent(".clip-index")
            .appending("/tmp")
    }

    /// 按场景索引分组关键帧文件路径
    ///
    /// - Parameters:
    ///   - frames: KeyframeExtractor 返回的帧列表
    ///   - sceneCount: 场景总数
    /// - Returns: 按场景索引分组的文件路径数组，`result[sceneIndex]` 为该场景的帧路径列表
    static func groupFramesByScene(
        frames: [KeyframeExtractor.ExtractedFrame],
        sceneCount: Int
    ) -> [[String]] {
        var groups = Array(repeating: [String](), count: sceneCount)
        for frame in frames {
            guard frame.sceneIndex >= 0 && frame.sceneIndex < sceneCount else { continue }
            groups[frame.sceneIndex].append(frame.filePath)
        }
        return groups
    }

    /// 将字符串数组编码为 JSON 字符串
    ///
    /// 输入: `["海滩", "户外"]`
    /// 输出: `"[\"海滩\",\"户外\"]"`
    ///
    /// 空数组返回 nil。
    static func encodeJSONArray(_ array: [String]) -> String? {
        guard !array.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(array),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    /// 为 clip 选择代表性缩略图路径
    ///
    /// 返回该场景的第一帧路径（如有）。
    static func selectThumbnail(from frames: [String]) -> String? {
        frames.first
    }
}
