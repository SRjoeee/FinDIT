import Foundation
import GRDB
import WhisperKit
import MLXLMCommon

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
        case metadataDone = "metadata_done"
        case vectorsDone = "vectors_done"
        case sttRunning = "stt_running"
        case sttDone = "stt_done"
        case visionRunning = "vision_running"
        case completed = "completed"
        case failed = "failed"
        case orphaned = "orphaned"

        /// 阶段顺序索引（用于比较进度）
        var order: Int {
            switch self {
            case .pending:        return 0
            case .metadataDone:   return 1
            case .vectorsDone:    return 2
            case .sttRunning:     return 3
            case .sttDone:        return 4
            case .visionRunning:  return 5
            case .completed:      return 6
            case .failed:         return -1
            case .orphaned:       return -2
            }
        }

        /// 当前阶段是否早于目标阶段
        public func isBefore(_ other: Stage) -> Bool {
            order < other.order
        }
    }

    /// 单视频处理结果
    public struct ProcessingResult: Sendable {
        /// 视频 ID
        public let videoId: Int64
        /// 创建的 clip 数量
        public let clipsCreated: Int
        /// 已完成视觉分析的 clip 数量
        public let clipsAnalyzed: Int
        /// 已完成嵌入计算的 clip 数量
        public let clipsEmbedded: Int
        /// SRT 文件路径（如有）
        public let srtPath: String?
        /// 同步结果（如有）
        public let syncResult: SyncEngine.SyncResult?
        /// 是否需要调用方执行 force 同步（并行模式恢复 orphaned 时使用）
        public let requiresForceSync: Bool
        /// 是否因无音轨而跳过 STT（非致命降级）
        public let sttSkippedNoAudio: Bool

        public init(
            videoId: Int64,
            clipsCreated: Int,
            clipsAnalyzed: Int,
            clipsEmbedded: Int,
            srtPath: String?,
            syncResult: SyncEngine.SyncResult?,
            requiresForceSync: Bool = false,
            sttSkippedNoAudio: Bool = false
        ) {
            self.videoId = videoId
            self.clipsCreated = clipsCreated
            self.clipsAnalyzed = clipsAnalyzed
            self.clipsEmbedded = clipsEmbedded
            self.srtPath = srtPath
            self.syncResult = syncResult
            self.requiresForceSync = requiresForceSync
            self.sttSkippedNoAudio = sttSkippedNoAudio
        }
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

    // MARK: - 全流程编排

    /// 处理单个视频的完整管线
    ///
    // MARK: - 分层索引入口

    /// 分层索引入口（推荐）
    ///
    /// 使用 LayeredIndexer 四层架构:
    /// - Layer 0: 元数据提取
    /// - Layer 1: 场景检测 + CLIP 编码 → **可搜索**
    /// - Layer 2: 语音转录
    /// - Layer 3: VLM 描述 + 文本嵌入
    ///
    /// Layer 1 完成后视频即可通过 CLIP 向量搜索。
    public static func processVideoLayered(
        videoPath: String,
        folderPath: String,
        folderDB: DatabaseWriter,
        globalDB: DatabaseWriter? = nil,
        config: LayeredIndexer.Config,
        skipSync: Bool = false,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessingResult {
        try await LayeredIndexer.indexVideo(
            videoPath: videoPath,
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB,
            config: config,
            skipSync: skipSync,
            onProgress: onProgress
        )
    }

    // MARK: - 内部辅助方法

    /// 清理全局库中指定视频的旧 clips
    ///
    /// 在重索引视频时调用，防止旧 source_clip_id 在全局库中残留为孤儿记录。
    ///
    /// - Parameters:
    ///   - folderPath: 文件夹路径
    ///   - sourceVideoId: 文件夹库中的 video_id
    ///   - globalDB: 全局搜索索引数据库
    /// - Returns: 被删除的 clips 数量
    @discardableResult
    static func cleanGlobalClipsForVideo(
        folderPath: String,
        sourceVideoId: Int64,
        globalDB: DatabaseWriter
    ) throws -> Int {
        try globalDB.write { db in
            let globalVideoRow = try Row.fetchOne(db, sql: """
                SELECT video_id FROM videos
                WHERE source_folder = ? AND source_video_id = ?
                """, arguments: [folderPath, sourceVideoId])
            guard let globalVideoId: Int64 = globalVideoRow?["video_id"] else {
                return 0
            }
            try db.execute(
                sql: "DELETE FROM clips WHERE video_id = ?",
                arguments: [globalVideoId]
            )
            return db.changesCount
        }
    }

    /// 注册视频到文件夹库（已存在则返回现有记录）
    static func registerVideo(
        videoPath: String,
        folderPath: String,
        folderDB: DatabaseWriter
    ) throws -> (Video, Int64) {
        // 查找已有记录
        if let existing = try folderDB.read({ db in
            try Video.fetchByPath(db, path: videoPath)
        }) {
            guard let id = existing.videoId else {
                throw StorageError.openFailed(underlying: NSError(
                    domain: "PipelineManager", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "视频记录无 ID"]
                ))
            }
            return (existing, id)
        }

        // 查找文件夹的 folderId
        let folderId = try folderDB.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT folder_id FROM watched_folders WHERE folder_path = ?
                """, arguments: [folderPath])
        }

        // 获取文件信息
        let fileName = (videoPath as NSString).lastPathComponent
        let attrs = try? FileManager.default.attributesOfItem(atPath: videoPath)
        let fileSize = attrs?[.size] as? Int64
        let fileMtime = (attrs?[.modificationDate] as? Date)
            .map { Clip.utcFormatter.string(from: $0) }

        // 插入新记录
        var video = Video(
            folderId: folderId,
            filePath: videoPath,
            fileName: fileName,
            fileSize: fileSize,
            fileModified: fileMtime,
            createdAt: Clip.sqliteDatetime()
        )
        try folderDB.write { db in
            try video.insert(db)
        }

        guard let videoId = video.videoId else {
            throw StorageError.openFailed(underlying: NSError(
                domain: "PipelineManager", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "视频插入后无 ID"]
            ))
        }

        return (video, videoId)
    }

    /// 更新视频状态
    static func updateVideoStatus(
        folderDB: DatabaseWriter,
        videoId: Int64,
        status: Stage,
        error: String? = nil
    ) throws {
        try folderDB.write { db in
            try db.execute(sql: """
                UPDATE videos SET index_status = ?, index_error = ?,
                    indexed_at = CASE WHEN ? = 'completed' THEN datetime('now') ELSE indexed_at END
                WHERE video_id = ?
                """, arguments: [status.rawValue, error, status.rawValue, videoId])
        }
    }

    /// 更新视频时长
    static func updateVideoDuration(
        folderDB: DatabaseWriter,
        videoId: Int64,
        duration: Double
    ) throws {
        try folderDB.write { db in
            try db.execute(
                sql: "UPDATE videos SET duration = ? WHERE video_id = ?",
                arguments: [duration, videoId]
            )
        }
    }

    /// 创建 Clip 骨架记录（含缩略图路径）
    @discardableResult
    static func createClipRecords(
        videoId: Int64,
        segments: [SceneSegment],
        frameGroups: [[String]],
        folderDB: DatabaseWriter
    ) throws -> Int {
        try folderDB.write { db in
            for (index, segment) in segments.enumerated() {
                let thumbnail = index < frameGroups.count
                    ? selectThumbnail(from: frameGroups[index])
                    : nil

                var clip = Clip(
                    videoId: videoId,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    thumbnailPath: thumbnail
                )
                try clip.insert(db)
            }
            return segments.count
        }
    }

    /// 更新 clips 的 transcript 字段
    static func updateClipsTranscript(
        videoId: Int64,
        texts: [String?],
        folderDB: DatabaseWriter
    ) throws {
        try folderDB.write { db in
            let clips = try Clip.fetchAll(forVideo: videoId, in: db)
            for (index, clip) in clips.enumerated() {
                guard index < texts.count, let text = texts[index], !text.isEmpty else { continue }
                guard let clipId = clip.clipId else { continue }
                try db.execute(
                    sql: "UPDATE clips SET transcript = ? WHERE clip_id = ?",
                    arguments: [text, clipId]
                )
            }
        }
    }

    /// 更新 clip 的视觉分析结果
    ///
    /// 使用 VisionField 动态生成 SQL SET 子句和参数。
    static func updateClipVision(
        clipId: Int64,
        result: AnalysisResult,
        folderDB: DatabaseWriter
    ) throws {
        try batchUpdateClipVision(
            updates: [(clipId: clipId, result: result)],
            videoId: nil,
            folderDB: folderDB
        )
    }

    /// 批量更新多个 clip 的视觉分析结果（单事务）
    ///
    /// 同时更新 `last_processed_clip` 断点（取批次中最大的 clipId）。
    /// 50 个场景的视频从 50 次事务降为 ~5 次。
    static func batchUpdateClipVision(
        updates: [(clipId: Int64, result: AnalysisResult)],
        videoId: Int64?,
        folderDB: DatabaseWriter
    ) throws {
        guard !updates.isEmpty else { return }

        let fields = VisionField.allActive
        let setClause = VisionField.sqlSetClause(fields: fields)
        let visionSQL = "UPDATE clips SET \(setClause), tags = ? WHERE clip_id = ?"

        try folderDB.write { db in
            let stmt = try db.makeStatement(sql: visionSQL)

            for update in updates {
                var args: [DatabaseValueConvertible?] = []
                for field in fields {
                    if field.isArray {
                        args.append(encodeJSONArray(update.result.arrayValue(for: field)))
                    } else {
                        args.append(update.result.stringValue(for: field))
                    }
                }
                args.append(encodeJSONArray(update.result.tags))
                args.append(update.clipId)

                try stmt.execute(arguments: StatementArguments(args))
            }

            // 更新断点到批次中最大的 clipId
            if let vid = videoId, let maxClipId = updates.map(\.clipId).max() {
                try db.execute(
                    sql: "UPDATE videos SET last_processed_clip = ? WHERE video_id = ?",
                    arguments: [maxClipId, vid]
                )
            }
        }
    }

    /// 更新 clip 的嵌入向量
    static func updateClipEmbedding(
        clipId: Int64,
        data: Data,
        model: String,
        folderDB: DatabaseWriter
    ) throws {
        try folderDB.write { db in
            try db.execute(
                sql: "UPDATE clips SET embedding = ?, embedding_model = ? WHERE clip_id = ?",
                arguments: [data, model, clipId]
            )
        }
    }

    /// 检查是否有可用的 STT 引擎
    ///
    /// 根据 `sttEngine` 偏好检查可用性:
    /// - `.whisperKitOnly`: 仅 WhisperKit 可用时返回 true
    /// - `.speechAnalyzerOnly`: 仅 SpeechAnalyzer 可用时返回 true
    /// - `.auto`: WhisperKit 或 SpeechAnalyzer 任一可用即返回 true
    static func isSttAvailable(
        whisperKit: WhisperKit?,
        sttEngine: STTEngine = .auto
    ) async -> Bool {
        switch sttEngine {
        case .whisperKitOnly:
            return whisperKit != nil
        case .speechAnalyzerOnly:
            if #available(macOS 26.0, *) {
                return await SpeechAnalyzerBridge.isAvailable()
            }
            return false
        case .auto:
            if whisperKit != nil { return true }
            if #available(macOS 26.0, *) {
                return await SpeechAnalyzerBridge.isAvailable()
            }
            return false
        }
    }

    /// 从已有缩略图目录加载帧路径（恢复模式用）
    static func loadExistingThumbnails(
        clips: [Clip],
        thumbnailDir: String
    ) -> [[String]] {
        clips.map { clip in
            if let path = clip.thumbnailPath,
               FileManager.default.fileExists(atPath: path) {
                return [path]
            }
            return []
        }
    }
}
