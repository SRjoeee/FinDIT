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
            case .sttRunning:     return 1
            case .sttDone:        return 2
            case .visionRunning:  return 3
            case .completed:      return 4
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

        public init(
            videoId: Int64,
            clipsCreated: Int,
            clipsAnalyzed: Int,
            clipsEmbedded: Int,
            srtPath: String?,
            syncResult: SyncEngine.SyncResult?,
            requiresForceSync: Bool = false
        ) {
            self.videoId = videoId
            self.clipsCreated = clipsCreated
            self.clipsAnalyzed = clipsAnalyzed
            self.clipsEmbedded = clipsEmbedded
            self.srtPath = srtPath
            self.syncResult = syncResult
            self.requiresForceSync = requiresForceSync
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
    /// 流程:
    /// 1. 注册视频到数据库
    /// 2. 场景检测 + 关键帧提取（FFmpeg）
    /// 3. 创建 Clip 骨架记录
    /// 4. 音频提取 + STT 转录（WhisperKit）
    /// 5. 逐 clip 视觉分析（Gemini Flash）
    /// 6. 同步到全局搜索索引
    ///
    /// - Parameters:
    ///   - videoPath: 视频文件绝对路径
    ///   - folderPath: 素材文件夹路径（数据库所在位置）
    ///   - folderDB: 文件夹级数据库连接
    ///   - globalDB: 全局搜索索引连接（nil = 不同步）
    ///   - apiKey: Gemini API Key（nil = 跳过 Gemini 视觉分析）
    ///   - rateLimiter: Gemini 限速器（nil = 不限速）
    ///   - whisperKit: WhisperKit 实例（nil = 跳过 STT，macOS 26+ 仍可用 SpeechAnalyzer）
    ///   - vlmContainer: 本地 VLM 模型容器（nil = 跳过本地 VLM）
    ///   - embeddingProvider: 向量嵌入提供者（nil = 跳过嵌入）
    ///   - skipStt: 跳过所有语音转录（包括 SpeechAnalyzer）
    ///   - skipSync: 跳过同步到全局索引（并行模式由调用方统一同步）
    ///   - ffmpegConfig: FFmpeg 配置
    ///   - onProgress: 进度回调
    /// - Returns: 处理结果
    public static func processVideo(
        videoPath: String,
        folderPath: String,
        folderDB: DatabaseWriter,
        globalDB: DatabaseWriter? = nil,
        apiKey: String? = nil,
        rateLimiter: GeminiRateLimiter? = nil,
        whisperKit: WhisperKit? = nil,
        vlmContainer: ModelContainer? = nil,
        embeddingProvider: EmbeddingProvider? = nil,
        skipStt: Bool = false,
        skipSync: Bool = false,
        ffmpegConfig: FFmpegConfig = .default,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessingResult {
        let progress = onProgress ?? { _ in }

        // 1. 注册视频
        let (video, videoId) = try registerVideo(
            videoPath: videoPath,
            folderPath: folderPath,
            folderDB: folderDB
        )
        var currentStage = Stage(rawValue: video.indexStatus) ?? .pending

        // 三层跳过检测（已完成的视频）
        if currentStage == .completed {
            // 层 1: file_size + file_modified 快速比较（零文件 I/O）
            let attrs = try? FileManager.default.attributesOfItem(atPath: videoPath)
            let currentSize = attrs?[.size] as? Int64
            let currentMtime = (attrs?[.modificationDate] as? Date)
                .map { Clip.utcFormatter.string(from: $0) }

            let sizeMatch = currentSize == video.fileSize
            let mtimeMatch = currentMtime == video.fileModified

            if sizeMatch && mtimeMatch {
                progress("已完成且文件未变，跳过")
                return ProcessingResult(
                    videoId: videoId, clipsCreated: 0, clipsAnalyzed: 0,
                    clipsEmbedded: 0, srtPath: video.srtPath, syncResult: nil
                )
            }

            // 层 2: size/mtime 变了 → 计算哈希验证内容是否真的变了
            if let storedHash = video.fileHash {
                progress("元数据变更，哈希校验中...")
                let currentHash = try FileHasher.hash128(filePath: videoPath)
                if currentHash == storedHash {
                    // 内容未变，仅元数据变更 → 更新 mtime 后跳过
                    try await folderDB.write { db in
                        try db.execute(sql: """
                            UPDATE videos SET file_size = ?, file_modified = ?
                            WHERE video_id = ?
                            """, arguments: [currentSize, currentMtime, videoId])
                    }
                    progress("内容未变（哈希匹配），跳过")
                    return ProcessingResult(
                        videoId: videoId, clipsCreated: 0, clipsAnalyzed: 0,
                        clipsEmbedded: 0, srtPath: video.srtPath, syncResult: nil
                    )
                }

                // 内容已变更 → 重置为 pending 以重新索引
                progress("文件内容已变更，重新索引")
                try await folderDB.write { db in
                    try db.execute(sql: """
                        UPDATE videos SET index_status = 'pending', index_error = NULL,
                            file_size = ?, file_modified = ?, file_hash = NULL,
                            last_processed_clip = NULL
                        WHERE video_id = ?
                        """, arguments: [currentSize, currentMtime, videoId])
                }
                currentStage = .pending
                // 不 return，继续执行管线
            } else {
                // storedHash == nil → 旧数据无哈希 → 补充哈希后跳过
                progress("补充文件哈希...")
                let hash = try FileHasher.hash128(filePath: videoPath)
                try await folderDB.write { db in
                    try db.execute(sql: """
                        UPDATE videos SET file_hash = ?, file_size = ?, file_modified = ?
                        WHERE video_id = ?
                        """, arguments: [hash, currentSize, currentMtime, videoId])
                }
                progress("已完成，已补充哈希")
                return ProcessingResult(
                    videoId: videoId, clipsCreated: 0, clipsAnalyzed: 0,
                    clipsEmbedded: 0, srtPath: video.srtPath, syncResult: nil
                )
            }
        }

        // 新视频 → 计算并存储哈希（在场景检测前）
        if video.fileHash == nil && currentStage == .pending {
            progress("计算文件哈希...")
            let hash = try FileHasher.hash128(filePath: videoPath)
            let attrs = try? FileManager.default.attributesOfItem(atPath: videoPath)
            let currentMtime = (attrs?[.modificationDate] as? Date)
                .map { Clip.utcFormatter.string(from: $0) }
            try await folderDB.write { db in
                try db.execute(sql: """
                    UPDATE videos SET file_hash = ?, file_modified = ?
                    WHERE video_id = ?
                    """, arguments: [hash, currentMtime, videoId])
            }
        }

        // Orphan 恢复: 新 pending 视频计算 hash 后，尝试匹配 orphaned 记录
        if currentStage == .pending, let hash = try await folderDB.read({ db in
            try String.fetchOne(db, sql: """
                SELECT file_hash FROM videos WHERE video_id = ?
                """, arguments: [videoId])
        }) {
            if let recovery = try OrphanRecovery.attemptRecovery(
                fileHash: hash,
                newVideoPath: videoPath,
                pendingVideoId: videoId,
                folderDB: folderDB
            ) {
                progress("恢复 orphaned 记录 (\(recovery.clipCount) clips)")
                var recoverySyncResult: SyncEngine.SyncResult?
                var requiresForceSync = false
                if let globalDB = globalDB {
                    if skipSync {
                        // 并行调度模式：交由调度器在最终合并阶段执行 force 同步
                        requiresForceSync = true
                    } else {
                        recoverySyncResult = try SyncEngine.sync(
                            folderPath: folderPath,
                            folderDB: folderDB,
                            globalDB: globalDB,
                            force: true
                        )
                    }
                }
                return ProcessingResult(
                    videoId: recovery.recoveredVideoId,
                    clipsCreated: recovery.clipCount, clipsAnalyzed: 0,
                    clipsEmbedded: 0, srtPath: nil,
                    syncResult: recoverySyncResult,
                    requiresForceSync: requiresForceSync
                )
            }
        }

        var srtPath: String? = video.srtPath
        var clipsCreated = 0
        var clipsAnalyzed = 0
        var sceneSegments: [SceneSegment] = []
        var frameGroups: [[String]] = []
        var extractedAudioPath: String?

        // 2. FFmpeg 准备阶段（场景检测 + 关键帧 + 本地视觉分析）
        //    对 pending 或 failed 状态的视频需要执行
        if currentStage == .pending || currentStage == .failed {
            do {
                // 场景检测 + 时长获取 + 可选音频提取（单次 FFmpeg 调用）
                progress("场景检测中...")
                let needsAudio = skipStt ? false : await isSttAvailable(whisperKit: whisperKit)
                var audioOutputPath: String?
                if needsAudio {
                    let tmpDir = tmpDirectory(folderPath: folderPath)
                    try FileManager.default.createDirectory(
                        atPath: tmpDir, withIntermediateDirectories: true
                    )
                    audioOutputPath = (tmpDir as NSString)
                        .appendingPathComponent("video_\(videoId).wav")
                }

                let detection = try SceneDetector.detectScenesOptimized(
                    inputPath: videoPath,
                    audioOutputPath: audioOutputPath,
                    ffmpegConfig: ffmpegConfig
                )
                let duration = detection.duration
                sceneSegments = detection.scenes
                extractedAudioPath = audioOutputPath

                try updateVideoDuration(folderDB: folderDB, videoId: videoId, duration: duration)
                progress("检测到 \(sceneSegments.count) 个场景 (时长: \(Int(duration))s)")

                guard !sceneSegments.isEmpty else {
                    progress("视频无有效场景，标记为完成")
                    try updateVideoStatus(folderDB: folderDB, videoId: videoId, status: .completed)
                    return ProcessingResult(
                        videoId: videoId, clipsCreated: 0, clipsAnalyzed: 0,
                        clipsEmbedded: 0, srtPath: nil, syncResult: nil
                    )
                }

                // 关键帧提取
                progress("提取关键帧中...")
                let thumbDir = thumbnailDirectory(folderPath: folderPath, videoId: videoId)
                let frames = try KeyframeExtractor.extractKeyframes(
                    inputPath: videoPath,
                    segments: sceneSegments,
                    outputDirectory: thumbDir,
                    ffmpegConfig: ffmpegConfig
                )
                progress("提取了 \(frames.count) 帧")
                frameGroups = groupFramesByScene(frames: frames, sceneCount: sceneSegments.count)

                // 删除旧 clips（重索引场景）
                // 先清理全局库中该视频的旧 clips，防止孤儿记录
                if let globalDB = globalDB {
                    try cleanGlobalClipsForVideo(
                        folderPath: folderPath,
                        sourceVideoId: videoId,
                        globalDB: globalDB
                    )
                }
                try await folderDB.write { db in
                    try db.execute(
                        sql: "DELETE FROM clips WHERE video_id = ?",
                        arguments: [videoId]
                    )
                }

                // 创建 Clip 骨架记录
                clipsCreated = try createClipRecords(
                    videoId: videoId,
                    segments: sceneSegments,
                    frameGroups: frameGroups,
                    folderDB: folderDB
                )
                progress("创建了 \(clipsCreated) 个片段记录")

                // 2f. 本地视觉分析 (Apple Vision 框架，零网络)
                progress("本地视觉分析中...")
                let freshClips = try await folderDB.read { db in
                    try Clip.fetchAll(forVideo: videoId, in: db)
                }
                var localAnalyzed = 0
                for (index, clip) in freshClips.enumerated() {
                    guard let clipId = clip.clipId else { continue }
                    let paths = index < frameGroups.count ? frameGroups[index] : []
                    guard !paths.isEmpty else { continue }
                    do {
                        let localResult = try LocalVisionAnalyzer.analyzeClip(imagePaths: paths)
                        try updateClipVision(clipId: clipId, result: localResult, folderDB: folderDB)
                        localAnalyzed += 1
                    } catch {
                        progress("场景 \(index + 1) 本地分析失败: \(error.localizedDescription)")
                    }
                }
                progress("本地分析完成: \(localAnalyzed)/\(freshClips.count)")

            } catch {
                try? updateVideoStatus(
                    folderDB: folderDB, videoId: videoId,
                    status: .failed, error: error.localizedDescription
                )
                throw error
            }
        } else {
            // 恢复模式：从数据库加载已有的 clips
            let existingClips = try await folderDB.read { db in
                try Clip.fetchAll(forVideo: videoId, in: db)
            }
            clipsCreated = existingClips.count
            sceneSegments = existingClips.map {
                SceneSegment(startTime: $0.startTime, endTime: $0.endTime)
            }
        }

        // 3. STT 阶段
        //    skipStt=true: 跳过所有 STT（包括 SpeechAnalyzer）
        //    macOS 26+: 优先 SpeechAnalyzer（即使 whisperKit 为 nil）
        //    较旧 macOS: 需要 whisperKit
        let sttAvailable = skipStt ? false : await isSttAvailable(whisperKit: whisperKit)
        if sttAvailable && currentStage.isBefore(.sttDone) {
            do {
                try updateVideoStatus(folderDB: folderDB, videoId: videoId, status: .sttRunning)

                // 音频（使用 FFmpeg 阶段预提取的，或现场提取）
                let audioPath: String
                if let preExtracted = extractedAudioPath {
                    audioPath = preExtracted
                } else {
                    progress("提取音频中...")
                    let tmpDir = tmpDirectory(folderPath: folderPath)
                    try FileManager.default.createDirectory(
                        atPath: tmpDir, withIntermediateDirectories: true
                    )
                    audioPath = (tmpDir as NSString).appendingPathComponent("video_\(videoId).wav")
                    try AudioExtractor.extractAudio(
                        inputPath: videoPath,
                        outputPath: audioPath,
                        config: ffmpegConfig
                    )
                }
                // 确保临时音频文件在成功或失败时都被清理
                defer { try? FileManager.default.removeItem(atPath: audioPath) }

                // 语言检测
                var detectedLanguage: String?
                var preTranscribedSegments: [TranscriptSegment]?

                if let wk = whisperKit {
                    // WhisperKit 多采样投票检测
                    progress("检测语言中...")
                    let langResult = try await STTProcessor.detectLanguage(
                        audioPath: audioPath,
                        scenes: sceneSegments,
                        whisperKit: wk
                    )
                    detectedLanguage = langResult.language
                    progress("检测到语言: \(langResult.language)")
                } else if #available(macOS 26.0, *) {
                    // 无 WhisperKit：用 NLLanguageRecognizer 检测
                    progress("检测语言中 (NL)...")
                    let (lang, segs) = await STTProcessor.detectLanguageViaNL(
                        audioPath: audioPath
                    )
                    detectedLanguage = lang
                    // 英语结果可直接复用，避免二次转录
                    if lang == "en" {
                        preTranscribedSegments = segs
                    }
                    if let lang {
                        progress("检测到语言: \(lang)")
                    }
                }

                // 转录（自动选择最优引擎）
                let segments: [TranscriptSegment]
                let engine: String

                if let preSegs = preTranscribedSegments, !preSegs.isEmpty {
                    // 复用语言检测阶段的英语转录结果
                    segments = preSegs
                    engine = "SpeechAnalyzer"
                    progress("转录完成 [\(engine)]: \(segments.count) 条字幕（复用检测结果）")
                } else {
                    progress("语音转录中...")
                    let result = try await STTProcessor.transcribeWithBestAvailable(
                        audioPath: audioPath,
                        language: detectedLanguage,
                        whisperKit: whisperKit,
                        onProgress: onProgress
                    )
                    segments = result.segments
                    engine = result.engine
                    progress("转录完成 [\(engine)]: \(segments.count) 条字幕")
                }

                // 保存 SRT
                let srtContent = STTProcessor.generateSRT(from: segments)
                let generatedSrtPath = try STTProcessor.writeSRT(
                    content: srtContent, videoPath: videoPath
                )
                srtPath = generatedSrtPath

                // 映射转录文本到 clips
                let mappedTexts = STTProcessor.mapTranscriptToClips(
                    transcriptSegments: segments,
                    sceneSegments: sceneSegments
                )
                try updateClipsTranscript(
                    videoId: videoId,
                    texts: mappedTexts,
                    folderDB: folderDB
                )

                // 更新 SRT 路径
                let currentSrtPath = srtPath
                try await folderDB.write { db in
                    try db.execute(
                        sql: "UPDATE videos SET srt_path = ? WHERE video_id = ?",
                        arguments: [currentSrtPath, videoId]
                    )
                }


                try updateVideoStatus(folderDB: folderDB, videoId: videoId, status: .sttDone)

            } catch {
                // STT 失败不致命，记录错误继续
                progress("语音转录失败: \(error.localizedDescription)")
                // 仍然推进到 sttDone 以允许 vision 继续
                try? updateVideoStatus(folderDB: folderDB, videoId: videoId, status: .sttDone)
            }
        } else if !sttAvailable && currentStage.isBefore(.sttDone) {
            // 跳过 STT
            try updateVideoStatus(folderDB: folderDB, videoId: videoId, status: .sttDone)
        }

        // 4. Vision 分析阶段
        //    策略: Gemini (apiKey) > LocalVLM (vlmContainer) > skip (LocalVisionAnalyzer 已在步骤 2f 填充)
        let hasVisionEngine = apiKey != nil || vlmContainer != nil
        if hasVisionEngine && currentStage.isBefore(.completed) {
            try updateVideoStatus(folderDB: folderDB, videoId: videoId, status: .visionRunning)

            let clips = try await folderDB.read { db in
                try Clip.fetchAll(forVideo: videoId, in: db)
            }
            let lastProcessed = Int64(video.lastProcessedClip ?? 0)

            // 如果没有 frameGroups（恢复模式），重新加载缩略图
            if frameGroups.isEmpty {
                let thumbDir = thumbnailDirectory(folderPath: folderPath, videoId: videoId)
                frameGroups = loadExistingThumbnails(
                    clips: clips,
                    thumbnailDir: thumbDir
                )
            }

            let engineName = apiKey != nil ? "Gemini" : "LocalVLM"
            progress("视觉分析中 [\(engineName)]...")

            for (index, clip) in clips.enumerated() {
                guard let clipId = clip.clipId, clipId > lastProcessed else { continue }

                var paths = index < frameGroups.count ? frameGroups[index] : [String]()
                if paths.isEmpty,
                   let thumb = clip.thumbnailPath,
                   FileManager.default.fileExists(atPath: thumb) {
                    paths = [thumb]
                }
                guard !paths.isEmpty else { continue }

                do {
                    let result: AnalysisResult
                    if let key = apiKey {
                        // Gemini 云端分析
                        if let limiter = rateLimiter {
                            try await limiter.waitForPermission()
                        }
                        result = try await VisionAnalyzer.analyzeScene(
                            imagePaths: paths,
                            apiKey: key
                        )
                        if let limiter = rateLimiter {
                            await limiter.reportSuccess()
                        }
                    } else if let container = vlmContainer {
                        // 本地 VLM 分析
                        result = try await LocalVLMAnalyzer.analyzeClip(
                            imagePaths: paths,
                            container: container
                        )
                    } else {
                        continue
                    }

                    // 合并本地分析结果（步骤 2f）与远程结果，避免覆盖已有的高质量本地数据
                    let localResult = AnalysisResult.fromClip(clip)
                    let merged = LocalVisionAnalyzer.mergeResults(local: localResult, remote: result)

                    try updateClipVision(
                        clipId: clipId,
                        result: merged,
                        folderDB: folderDB
                    )
                    // 仅在成功写入视觉结果后推进断点，避免失败 clip 被跳过
                    try await folderDB.write { db in
                        try db.execute(
                            sql: "UPDATE videos SET last_processed_clip = ? WHERE video_id = ?",
                            arguments: [clipId, videoId]
                        )
                    }
                    clipsAnalyzed += 1
                    progress("场景 \(index + 1)/\(clips.count) 分析完成")

                } catch {
                    if let limiter = rateLimiter,
                       let visionErr = error as? VisionAnalyzerError,
                       case .rateLimitExceeded = visionErr {
                        await limiter.reportRateLimit()
                    }
                    progress("场景 \(index + 1) 分析失败: \(error.localizedDescription)")
                    // 继续处理下一个 clip
                }
            }

            try updateVideoStatus(folderDB: folderDB, videoId: videoId, status: .completed)
        } else if !hasVisionEngine && currentStage.isBefore(.completed) {
            // 跳过 Gemini/VLM vision，直接标记完成（LocalVisionAnalyzer 已在步骤 2f 填充基础数据）
            try updateVideoStatus(folderDB: folderDB, videoId: videoId, status: .completed)
        }

        // 5. 向量嵌入（批量，非致命）
        var clipsEmbedded = 0
        if let provider = embeddingProvider {
            progress("计算向量嵌入中...")
            let allClips = try await folderDB.read { db in
                try Clip.fetchAll(forVideo: videoId, in: db)
            }

            var clipTexts: [(clipId: Int64, text: String)] = []
            for clip in allClips {
                guard let cid = clip.clipId else { continue }
                let text = EmbeddingUtils.composeClipText(clip: clip)
                guard !text.isEmpty else { continue }
                clipTexts.append((cid, text))
            }

            if !clipTexts.isEmpty {
                do {
                    let vectors = try await provider.embedBatch(texts: clipTexts.map(\.text))
                    for (index, vector) in vectors.enumerated() where index < clipTexts.count {
                        let data = EmbeddingUtils.serializeEmbedding(vector)
                        try updateClipEmbedding(
                            clipId: clipTexts[index].clipId, data: data,
                            model: provider.name, folderDB: folderDB
                        )
                        clipsEmbedded += 1
                    }
                } catch {
                    // 批量失败，降级为逐个嵌入
                    progress("批量嵌入失败，逐个重试...")
                    for (cid, text) in clipTexts {
                        do {
                            let vector = try await provider.embed(text: text)
                            let data = EmbeddingUtils.serializeEmbedding(vector)
                            try updateClipEmbedding(
                                clipId: cid, data: data,
                                model: provider.name, folderDB: folderDB
                            )
                            clipsEmbedded += 1
                        } catch {
                            progress("clip \(cid) 嵌入失败: \(error.localizedDescription)")
                        }
                    }
                }
            }
            progress("嵌入完成: \(clipsEmbedded)/\(allClips.count)")
        }

        // 6. 同步到全局索引（skipSync 时跳过，由调用方统一同步）
        var syncResult: SyncEngine.SyncResult?
        if let globalDB = globalDB, !skipSync {
            progress("同步到全局索引...")
            let sr = try SyncEngine.sync(
                folderPath: folderPath,
                folderDB: folderDB,
                globalDB: globalDB
            )
            syncResult = sr
            progress("同步完成: \(sr.syncedVideos) 视频, \(sr.syncedClips) 片段")
        }

        return ProcessingResult(
            videoId: videoId,
            clipsCreated: clipsCreated,
            clipsAnalyzed: clipsAnalyzed,
            clipsEmbedded: clipsEmbedded,
            srtPath: srtPath,
            syncResult: syncResult
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
        let fields = VisionField.allActive
        let setClause = VisionField.sqlSetClause(fields: fields)
        let sql = "UPDATE clips SET \(setClause), tags = ? WHERE clip_id = ?"

        var args: [DatabaseValueConvertible?] = []
        for field in fields {
            if field.isArray {
                args.append(encodeJSONArray(result.arrayValue(for: field)))
            } else {
                args.append(result.stringValue(for: field))
            }
        }
        args.append(encodeJSONArray(result.tags))
        args.append(clipId)

        try folderDB.write { db in
            try db.execute(sql: sql, arguments: StatementArguments(args))
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
    /// macOS 26+: SpeechAnalyzer 可用则返回 true（即使 whisperKit 为 nil）
    /// 较旧 macOS: 需要 whisperKit 不为 nil
    static func isSttAvailable(whisperKit: WhisperKit?) async -> Bool {
        if whisperKit != nil { return true }
        if #available(macOS 26.0, *) {
            return await SpeechAnalyzerBridge.isAvailable()
        }
        return false
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
