import Foundation
import GRDB
@preconcurrency import WhisperKit
@preconcurrency import MLXLMCommon

/// 分层索引引擎
///
/// 将视频索引分为 4 层，每层可独立完成、可断点续传:
/// ```
/// Layer 0: 元数据提取 (< 1s)
/// Layer 1: 场景检测 + CLIP 编码 → 可搜索
/// Layer 2: 语音转录
/// Layer 3: VLM 描述 + 文本嵌入
/// ```
///
/// Layer 1 完成后视频即可通过 CLIP 向量搜索。
/// 后续层增强搜索质量但非必须。
public enum LayeredIndexer {

    // MARK: - 索引层级

    /// 索引层级定义
    public enum Layer: Int, CaseIterable, Comparable, Sendable {
        case metadata = 0        // 元数据提取 (< 1s)
        case clipVector = 1      // 场景检测 + CLIP 编码 (10-60s)
        case stt = 2             // 语音转录 (1-5min)
        case textDescription = 3 // VLM 描述 + 文本嵌入

        public static func < (lhs: Layer, rhs: Layer) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        /// 该层是否适用于指定媒体类型
        public func isApplicable(for mediaType: MediaType) -> Bool {
            switch (self, mediaType) {
            case (.metadata, _):              return true
            case (.clipVector, .audio):       return false
            case (.clipVector, _):            return true
            case (.stt, .photo):              return false
            case (.stt, _):                   return true
            case (.textDescription, .audio):  return false
            case (.textDescription, _):       return true
            }
        }

        /// 对应的 PipelineManager.Stage
        var completedStage: PipelineManager.Stage {
            switch self {
            case .metadata:        return .metadataDone
            case .clipVector:      return .vectorsDone
            case .stt:             return .sttDone
            case .textDescription: return .completed
            }
        }
    }

    // MARK: - 配置

    /// 索引配置
    ///
    /// 封装所有依赖以替代旧的 13+ 独立参数。
    public struct Config: Sendable {
        public let mediaService: (any MediaService)?
        public let clipProvider: CLIPEmbeddingProvider?
        public let whisperKit: WhisperKit?
        public let vlmContainer: ModelContainer?
        public let embeddingProvider: (any EmbeddingProvider)?
        public let apiKey: String?
        public let rateLimiter: GeminiRateLimiter?
        public let ffmpegConfig: FFmpegConfig
        public let skipLayers: Set<Layer>
        public let networkResilience: NetworkResilience?
        /// STT 语言提示（ISO 639-1），nil = 自动检测
        public let sttLanguageHint: String?
        /// STT 引擎偏好
        public let sttEngine: STTEngine
        /// 在 Finder 中隐藏生成的 SRT 文件
        public let hideSrtFiles: Bool

        public init(
            mediaService: (any MediaService)? = nil,
            clipProvider: CLIPEmbeddingProvider? = nil,
            whisperKit: WhisperKit? = nil,
            vlmContainer: ModelContainer? = nil,
            embeddingProvider: (any EmbeddingProvider)? = nil,
            apiKey: String? = nil,
            rateLimiter: GeminiRateLimiter? = nil,
            ffmpegConfig: FFmpegConfig = .default,
            skipLayers: Set<Layer> = [],
            networkResilience: NetworkResilience? = nil,
            sttLanguageHint: String? = nil,
            sttEngine: STTEngine = .auto,
            hideSrtFiles: Bool = true
        ) {
            self.mediaService = mediaService
            self.clipProvider = clipProvider
            self.whisperKit = whisperKit
            self.vlmContainer = vlmContainer
            self.embeddingProvider = embeddingProvider
            self.apiKey = apiKey
            self.rateLimiter = rateLimiter
            self.ffmpegConfig = ffmpegConfig
            self.skipLayers = skipLayers
            self.networkResilience = networkResilience
            self.sttLanguageHint = sttLanguageHint
            self.sttEngine = sttEngine
            self.hideSrtFiles = hideSrtFiles
        }
    }

    // MARK: - 主入口

    /// 对单个视频执行分层索引
    ///
    /// 从 `video.indexLayer` 恢复，逐层推进。
    /// Layer 1 完成后视频即可搜索。
    ///
    /// - Parameters:
    ///   - videoPath: 视频文件绝对路径
    ///   - folderPath: 素材文件夹路径
    ///   - folderDB: 文件夹级数据库
    ///   - globalDB: 全局搜索索引（nil = 不同步）
    ///   - config: 索引配置
    ///   - skipSync: 跳过同步（并行模式由调用方统一同步）
    ///   - onProgress: 进度回调
    /// - Returns: 处理结果
    public static func indexVideo(
        videoPath: String,
        folderPath: String,
        folderDB: DatabaseWriter,
        globalDB: DatabaseWriter? = nil,
        config: Config,
        skipSync: Bool = false,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> PipelineManager.ProcessingResult {
        let progress = onProgress ?? { _ in }
        try Task.checkCancellation()

        // 1. 注册视频（复用 PipelineManager）
        let (video, videoId) = try PipelineManager.registerVideo(
            videoPath: videoPath,
            folderPath: folderPath,
            folderDB: folderDB
        )

        let currentLayer = Layer(rawValue: video.indexLayer) ?? .metadata
        let currentStage = PipelineManager.Stage(rawValue: video.indexStatus) ?? .pending

        // 已完成 → 三层跳过检测（复用旧逻辑的快速路径）
        if currentStage == .completed {
            let skipResult = try await checkCompletedVideoSkip(
                video: video, videoId: videoId, videoPath: videoPath,
                folderDB: folderDB, progress: progress
            )
            if let result = skipResult {
                return result
            }
            // skipResult == nil 意味着需要重新索引，下面会继续
        }

        // Orphaned 恢复
        if currentStage == .orphaned {
            let recoverResult = try await handleOrphanedRecovery(
                video: video, videoId: videoId, videoPath: videoPath,
                folderPath: folderPath, folderDB: folderDB,
                globalDB: globalDB, skipSync: skipSync, progress: progress
            )
            if let result = recoverResult {
                return result
            }
            // nil = 需要重建索引，继续
        }

        // 新视频哈希 + orphan 恢复
        if video.fileHash == nil && currentStage == .pending {
            try Task.checkCancellation()
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

            // 尝试 orphan 恢复
            if let recovery = try OrphanRecovery.attemptRecovery(
                fileHash: hash,
                newVideoPath: videoPath,
                pendingVideoId: videoId,
                folderDB: folderDB
            ) {
                progress("恢复 orphaned 记录 (\(recovery.clipCount) clips)")
                var syncResult: SyncEngine.SyncResult?
                var requiresForceSync = false
                if let globalDB = globalDB {
                    if skipSync {
                        requiresForceSync = true
                    } else {
                        syncResult = try SyncEngine.sync(
                            folderPath: folderPath,
                            folderDB: folderDB,
                            globalDB: globalDB,
                            force: true
                        )
                    }
                }
                return PipelineManager.ProcessingResult(
                    videoId: recovery.recoveredVideoId,
                    clipsCreated: recovery.clipCount, clipsAnalyzed: 0,
                    clipsEmbedded: 0, srtPath: nil,
                    syncResult: syncResult,
                    requiresForceSync: requiresForceSync
                )
            }
        }

        // 层级执行状态
        var srtPath: String? = video.srtPath
        var clipsCreated = 0
        var clipsAnalyzed = 0
        var clipsEmbedded = 0
        var frameGroups: [[String]] = []
        var sceneSegments: [SceneSegment] = []
        var extractedAudioPath: String?
        var skipSttBecauseNoAudio = false

        // ── Layer 0: 元数据 ──
        if shouldRunLayer(.metadata, currentLayer: currentLayer, config: config) {
            try Task.checkCancellation()
            progress("[L0] 提取元数据...")
            do {
                let duration: Double
                if let ms = config.mediaService {
                    let probe = try await ms.probe(filePath: videoPath)
                    duration = probe.duration ?? 0
                } else {
                    // 用 SceneDetector 获取时长（不做场景分割，Layer 1 会重新做）
                    let detection = try await SceneDetector.detectScenesOptimizedAsync(
                        inputPath: videoPath,
                        audioOutputPath: nil,
                        ffmpegConfig: config.ffmpegConfig
                    )
                    duration = detection.duration
                }
                try PipelineManager.updateVideoDuration(
                    folderDB: folderDB, videoId: videoId, duration: duration
                )
                try updateVideoLayer(
                    folderDB: folderDB, videoId: videoId,
                    layer: .metadata, stage: .metadataDone
                )
                progress("[L0] 时长: \(Int(duration))s")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try? updateVideoLayer(
                    folderDB: folderDB, videoId: videoId,
                    layer: .metadata, stage: .failed, error: error.localizedDescription
                )
                throw error
            }
        }

        // ── Layer 1: 场景检测 + CLIP 编码 ──
        if shouldRunLayer(.clipVector, currentLayer: currentLayer, config: config) {
            do {
                try Task.checkCancellation()
                progress("[L1] 场景检测中...")

                // 场景检测 + 可选音频预提取
                let needsAudio: Bool
                if config.skipLayers.contains(.stt) {
                    needsAudio = false
                } else {
                    needsAudio = await PipelineManager.isSttAvailable(
                        whisperKit: config.whisperKit,
                        sttEngine: config.sttEngine
                    )
                }
                var audioOutputPath: String?
                if needsAudio {
                    let tmpDir = PipelineManager.tmpDirectory(folderPath: folderPath)
                    try FileManager.default.createDirectory(
                        atPath: tmpDir, withIntermediateDirectories: true
                    )
                    audioOutputPath = (tmpDir as NSString)
                        .appendingPathComponent("video_\(videoId).wav")
                }

                // 场景检测（BRAW 等格式可能失败，用 try? 捕获后走 fallback）
                let detection: SceneDetector.CombinedDetectionResult?
                do {
                    if let sceneDetector = config.mediaService as? SceneDetectable {
                        detection = try await sceneDetector.detectScenesOptimized(
                            filePath: videoPath,
                            audioOutputPath: audioOutputPath,
                            config: .default
                        )
                    } else {
                        detection = try await SceneDetector.detectScenesOptimizedAsync(
                            inputPath: videoPath,
                            audioOutputPath: audioOutputPath,
                            ffmpegConfig: config.ffmpegConfig
                        )
                    }
                } catch {
                    // 场景检测失败（BRAW 等格式 FFmpeg 无法读取）
                    progress("[L1] 场景检测失败: \(error.localizedDescription)")
                    detection = nil
                }
                try Task.checkCancellation()

                var duration: Double = 0
                if let det = detection {
                    duration = det.duration
                    sceneSegments = det.scenes
                    extractedAudioPath = det.audioExtracted ? audioOutputPath : nil
                    if needsAudio && !det.audioExtracted {
                        skipSttBecauseNoAudio = true
                    }
                } else {
                    // Fallback: 从 probe 获取 duration
                    if let ms = config.mediaService {
                        let probeResult = try await ms.probe(filePath: videoPath)
                        duration = probeResult.duration ?? 0
                    }
                    // 音频稍后由 extractAudio 单独提取
                }

                // 固定间隔 fallback（BRAW 等无法场景检测的格式）
                if sceneSegments.isEmpty && duration > 0 {
                    sceneSegments = Self.fixedIntervalSegments(duration: duration)
                    progress("[L1] 固定间隔采样: \(sceneSegments.count) segments (10s)")
                }

                try PipelineManager.updateVideoDuration(
                    folderDB: folderDB, videoId: videoId, duration: duration
                )
                progress("[L1] \(sceneSegments.count) 个场景 (时长: \(Int(duration))s)")

                guard !sceneSegments.isEmpty else {
                    progress("[L1] 无有效场景，标记完成")
                    try updateVideoLayer(
                        folderDB: folderDB, videoId: videoId,
                        layer: .textDescription, stage: .completed
                    )
                    return PipelineManager.ProcessingResult(
                        videoId: videoId, clipsCreated: 0, clipsAnalyzed: 0,
                        clipsEmbedded: 0, srtPath: nil, syncResult: nil
                    )
                }

                // 关键帧提取
                progress("[L1] 提取关键帧...")
                let thumbDir = PipelineManager.thumbnailDirectory(
                    folderPath: folderPath, videoId: videoId
                )
                if let ms = config.mediaService {
                    var msFrameGroups: [[String]] = Array(
                        repeating: [], count: sceneSegments.count
                    )
                    var totalFrames = 0
                    for (sceneIdx, segment) in sceneSegments.enumerated() {
                        let frameCount = max(1, min(3, Int(segment.duration / 5.0)))
                        var times: [Double] = []
                        if frameCount == 1 {
                            times.append(segment.startTime + segment.duration / 2.0)
                        } else {
                            let step = segment.duration / Double(frameCount + 1)
                            for i in 1...frameCount {
                                times.append(segment.startTime + step * Double(i))
                            }
                        }
                        let sceneDir = (thumbDir as NSString)
                            .appendingPathComponent("scene_\(sceneIdx)")
                        let paths = try await ms.extractKeyframes(
                            filePath: videoPath,
                            times: times,
                            outputDir: sceneDir,
                            maxDimension: 512
                        )
                        msFrameGroups[sceneIdx] = paths
                        totalFrames += paths.count
                    }
                    frameGroups = msFrameGroups
                    progress("[L1] 提取了 \(totalFrames) 帧")
                } else {
                    let frames = try await KeyframeExtractor.extractKeyframesAsync(
                        inputPath: videoPath,
                        segments: sceneSegments,
                        outputDirectory: thumbDir,
                        ffmpegConfig: config.ffmpegConfig
                    )
                    frameGroups = PipelineManager.groupFramesByScene(
                        frames: frames, sceneCount: sceneSegments.count
                    )
                    progress("[L1] 提取了 \(frames.count) 帧")
                }
                try Task.checkCancellation()

                // 清理旧 clips（重索引场景）
                if let globalDB = globalDB {
                    try PipelineManager.cleanGlobalClipsForVideo(
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
                clipsCreated = try PipelineManager.createClipRecords(
                    videoId: videoId,
                    segments: sceneSegments,
                    frameGroups: frameGroups,
                    folderDB: folderDB
                )
                progress("[L1] 创建了 \(clipsCreated) 个片段")

                // 本地视觉分析 (Apple Vision, 零网络, ~10-30ms/帧)
                progress("[L1] 本地视觉分析...")
                let freshClips = try await folderDB.read { db in
                    try Clip.fetchAll(forVideo: videoId, in: db)
                }
                var localAnalyzed = 0
                for (index, clip) in freshClips.enumerated() {
                    try Task.checkCancellation()
                    guard let clipId = clip.clipId else { continue }
                    let paths = index < frameGroups.count ? frameGroups[index] : []
                    guard !paths.isEmpty else { continue }
                    do {
                        let localResult = try LocalVisionAnalyzer.analyzeClip(
                            imagePaths: paths
                        )
                        try PipelineManager.updateClipVision(
                            clipId: clipId, result: localResult, folderDB: folderDB
                        )
                        // 标记视觉分析来源
                        try await folderDB.write { db in
                            try db.execute(
                                sql: "UPDATE clips SET vision_provider = ? WHERE clip_id = ?",
                                arguments: ["local_vision", clipId]
                            )
                        }
                        localAnalyzed += 1
                    } catch {
                        progress("[L1] 场景 \(index + 1) 本地分析失败: \(error.localizedDescription)")
                    }
                }
                progress("[L1] 本地分析: \(localAnalyzed)/\(freshClips.count)")

                // CLIP 图像编码
                if let clipProvider = config.clipProvider,
                   await clipProvider.isImageEncoderAvailable {
                    progress("[L1] CLIP 编码中...")
                    let clipsForCLIP = try await folderDB.read { db in
                        try Clip.fetchAll(forVideo: videoId, in: db)
                    }
                    var encoded = 0
                    for (clipIdx, clip) in clipsForCLIP.enumerated() {
                        try Task.checkCancellation()
                        guard let clipId = clip.clipId else { continue }
                        let paths = clipIdx < frameGroups.count ? frameGroups[clipIdx] : []
                        guard !paths.isEmpty else { continue }

                        do {
                            // 每个 clip 取第一帧编码（代表性帧）
                            let vector = try await clipProvider.encodeImage(path: paths[0])
                            let data = EmbeddingUtils.serializeEmbedding(vector)
                            try await folderDB.write { db in
                                try db.execute(sql: """
                                    INSERT OR REPLACE INTO clip_vectors
                                    (clip_id, model_name, dimensions, vector)
                                    VALUES (?, ?, ?, ?)
                                    """, arguments: [
                                        clipId, CLIPEmbeddingProvider.modelName,
                                        vector.count, data
                                    ])
                            }
                            encoded += 1
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            progress("[L1] clip \(clipId) CLIP 编码失败: \(error.localizedDescription)")
                        }
                    }
                    progress("[L1] CLIP 编码: \(encoded)/\(clipsForCLIP.count)")
                } else {
                    progress("[L1] 跳过 CLIP 编码（provider 不可用）")
                }

                try updateVideoLayer(
                    folderDB: folderDB, videoId: videoId,
                    layer: .clipVector, stage: .vectorsDone
                )

                // Layer 1 完成 → 同步到全局库（此时已可搜索）
                if let globalDB = globalDB, !skipSync {
                    try Task.checkCancellation()
                    progress("[L1] 同步到全局索引...")
                    let _ = try SyncEngine.sync(
                        folderPath: folderPath,
                        folderDB: folderDB,
                        globalDB: globalDB
                    )
                }

            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try? updateVideoLayer(
                    folderDB: folderDB, videoId: videoId,
                    layer: .clipVector, stage: .failed, error: error.localizedDescription
                )
                throw error
            }
        } else if currentLayer.rawValue >= Layer.clipVector.rawValue {
            // 恢复模式：从数据库加载已有的 clips + frameGroups
            let existingClips = try await folderDB.read { db in
                try Clip.fetchAll(forVideo: videoId, in: db)
            }
            clipsCreated = existingClips.count
            sceneSegments = existingClips.map {
                SceneSegment(startTime: $0.startTime, endTime: $0.endTime)
            }
        }

        // ── Layer 2: 语音转录 ──
        if shouldRunLayer(.stt, currentLayer: currentLayer, config: config) {
            let sttAvailable: Bool
            if skipSttBecauseNoAudio {
                sttAvailable = false
            } else {
                sttAvailable = await PipelineManager.isSttAvailable(
                    whisperKit: config.whisperKit,
                    sttEngine: config.sttEngine
                )
            }
            if sttAvailable {
                do {
                    try Task.checkCancellation()
                    progress("[L2] 语音转录中...")

                    // 音频（使用 Layer 1 预提取的，或现场提取）
                    let audioPath: String
                    if let preExtracted = extractedAudioPath {
                        audioPath = preExtracted
                    } else {
                        let tmpDir = PipelineManager.tmpDirectory(folderPath: folderPath)
                        try FileManager.default.createDirectory(
                            atPath: tmpDir, withIntermediateDirectories: true
                        )
                        audioPath = (tmpDir as NSString)
                            .appendingPathComponent("video_\(videoId).wav")

                        if let ms = config.mediaService {
                            let _ = try await ms.extractAudio(
                                filePath: videoPath,
                                outputPath: audioPath,
                                sampleRate: 16000
                            )
                        } else {
                            try await AudioExtractor.extractAudioAsync(
                                inputPath: videoPath,
                                outputPath: audioPath,
                                config: config.ffmpegConfig
                            )
                        }
                    }
                    defer { try? FileManager.default.removeItem(atPath: audioPath) }

                    // 语言检测
                    var detectedLanguage: String?

                    if let hint = config.sttLanguageHint {
                        // 用户指定语言 → 跳过检测
                        detectedLanguage = hint
                        progress("[L2] 语言 (用户指定): \(hint)")
                    } else if config.sttEngine != .speechAnalyzerOnly,
                              let wk = config.whisperKit {
                        // WhisperKit 语言检测（最准确，但 speechAnalyzerOnly 模式跳过）
                        progress("[L2] 检测语言...")
                        let langResult = try await STTProcessor.detectLanguage(
                            audioPath: audioPath,
                            scenes: sceneSegments,
                            whisperKit: wk
                        )
                        detectedLanguage = langResult.language
                        progress("[L2] 语言: \(langResult.language)")
                    } else if #available(macOS 26.0, *) {
                        progress("[L2] 检测语言 (探测)...")
                        let (lang, segs) = await STTProcessor.detectLanguageViaSpeechProbe(
                            audioPath: audioPath,
                            ffmpegConfig: config.ffmpegConfig
                        )
                        detectedLanguage = lang
                        if let lang, !segs.isEmpty {
                            // 探测产出的 segments 仅覆盖 15 秒样本，不复用为完整转录
                            progress("[L2] 语言: \(lang)")
                        }
                    }

                    // 转录（使用检测到的语言）
                    try Task.checkCancellation()
                    let result = try await STTProcessor.transcribeWithBestAvailable(
                        audioPath: audioPath,
                        language: detectedLanguage,
                        whisperKit: config.whisperKit,
                        sttEngine: config.sttEngine,
                        onProgress: onProgress
                    )
                    let segments = result.segments
                    let engine = result.engine
                    progress("[L2] 转录完成 [\(engine)]: \(segments.count) 条字幕")

                    // SRT + 映射
                    let srtContent = STTProcessor.generateSRT(from: segments)
                    let generatedSrtPath = try STTProcessor.writeSRT(
                        content: srtContent, videoPath: videoPath,
                        hidden: config.hideSrtFiles
                    )
                    srtPath = generatedSrtPath

                    let mappedTexts = STTProcessor.mapTranscriptToClips(
                        transcriptSegments: segments,
                        sceneSegments: sceneSegments
                    )
                    try PipelineManager.updateClipsTranscript(
                        videoId: videoId,
                        texts: mappedTexts,
                        folderDB: folderDB
                    )

                    let currentSrtPath = srtPath
                    try await folderDB.write { db in
                        try db.execute(
                            sql: "UPDATE videos SET srt_path = ? WHERE video_id = ?",
                            arguments: [currentSrtPath, videoId]
                        )
                    }

                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // STT 失败不致命
                    progress("[L2] 转录失败: \(error.localizedDescription)")
                }
            }

            try updateVideoLayer(
                folderDB: folderDB, videoId: videoId,
                layer: .stt, stage: .sttDone
            )
        }

        // ── Layer 3: VLM 描述 + 文本嵌入 ──
        if shouldRunLayer(.textDescription, currentLayer: currentLayer, config: config) {
            // 网络容错: Gemini API 调用前等待网络恢复
            if config.apiKey != nil, let net = config.networkResilience {
                let connected = await net.isConnected
                if !connected {
                    progress("[L3] 等待网络连接...")
                    try await net.waitForConnection()
                    progress("[L3] 网络已恢复")
                }
            }

            // 3a. Vision 分析 (Gemini > LocalVLM > skip)
            let hasVisionEngine = config.apiKey != nil || config.vlmContainer != nil
            if hasVisionEngine {
                progress("[L3] 视觉分析中...")
                let clips = try await folderDB.read { db in
                    try Clip.fetchAll(forVideo: videoId, in: db)
                }
                let lastProcessed = Int64(video.lastProcessedClip ?? 0)

                // 恢复 frameGroups（如需要）
                if frameGroups.isEmpty {
                    let thumbDir = PipelineManager.thumbnailDirectory(
                        folderPath: folderPath, videoId: videoId
                    )
                    frameGroups = PipelineManager.loadExistingThumbnails(
                        clips: clips, thumbnailDir: thumbDir
                    )
                }

                let engineName = config.apiKey != nil ? "Gemini" : "LocalVLM"
                progress("[L3] 引擎: \(engineName)")

                let visionBatchSize = 10
                var pendingUpdates: [(clipId: Int64, result: AnalysisResult)] = []

                func flushPendingUpdates() throws {
                    guard !pendingUpdates.isEmpty else { return }
                    let updates = pendingUpdates
                    pendingUpdates.removeAll()
                    try PipelineManager.batchUpdateClipVision(
                        updates: updates,
                        videoId: videoId,
                        folderDB: folderDB
                    )
                }

                for (index, clip) in clips.enumerated() {
                    try Task.checkCancellation()
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
                        if let key = config.apiKey {
                            if let limiter = config.rateLimiter {
                                try await limiter.waitForPermission()
                            }
                            result = try await VisionAnalyzer.analyzeScene(
                                imagePaths: paths, apiKey: key
                            )
                            if let limiter = config.rateLimiter {
                                await limiter.reportSuccess()
                            }
                        } else if let container = config.vlmContainer {
                            result = try await LocalVLMAnalyzer.analyzeClip(
                                imagePaths: paths, container: container
                            )
                        } else {
                            continue
                        }

                        let localResult = AnalysisResult.fromClip(clip)
                        let merged = LocalVisionAnalyzer.mergeResults(
                            local: localResult, remote: result
                        )
                        pendingUpdates.append((clipId: clipId, result: merged))
                        clipsAnalyzed += 1

                        // 标记视觉分析来源
                        let provider = config.apiKey != nil ? "gemini" : "local_vlm"
                        try await folderDB.write { db in
                            try db.execute(
                                sql: "UPDATE clips SET vision_provider = ? WHERE clip_id = ?",
                                arguments: [provider, clipId]
                            )
                        }

                        progress("[L3] 场景 \(index + 1)/\(clips.count)")

                        if pendingUpdates.count >= visionBatchSize {
                            try flushPendingUpdates()
                        }
                    } catch is CancellationError {
                        try? flushPendingUpdates()
                        throw CancellationError()
                    } catch {
                        if let limiter = config.rateLimiter,
                           let visionErr = error as? VisionAnalyzerError,
                           case .rateLimitExceeded = visionErr {
                            await limiter.reportRateLimit()
                        }
                        progress("[L3] 场景 \(index + 1) 失败: \(error.localizedDescription)")
                    }
                }
                try flushPendingUpdates()
            }

            // 3b. 文本嵌入
            if let provider = config.embeddingProvider {
                try Task.checkCancellation()
                progress("[L3] 文本嵌入中...")
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
                        try Task.checkCancellation()
                        let vectors = try await provider.embedBatch(
                            texts: clipTexts.map(\.text)
                        )
                        for (index, vector) in vectors.enumerated()
                            where index < clipTexts.count {
                            try Task.checkCancellation()
                            let data = EmbeddingUtils.serializeEmbedding(vector)
                            try PipelineManager.updateClipEmbedding(
                                clipId: clipTexts[index].clipId, data: data,
                                model: provider.name, folderDB: folderDB
                            )
                            clipsEmbedded += 1
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        progress("[L3] 批量嵌入失败，逐个重试...")
                        for (cid, text) in clipTexts {
                            try Task.checkCancellation()
                            do {
                                let vector = try await provider.embed(text: text)
                                let data = EmbeddingUtils.serializeEmbedding(vector)
                                try PipelineManager.updateClipEmbedding(
                                    clipId: cid, data: data,
                                    model: provider.name, folderDB: folderDB
                                )
                                clipsEmbedded += 1
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                progress("[L3] clip \(cid) 嵌入失败: \(error.localizedDescription)")
                            }
                        }
                    }
                }
                progress("[L3] 嵌入完成: \(clipsEmbedded)/\(allClips.count)")
            }

            try updateVideoLayer(
                folderDB: folderDB, videoId: videoId,
                layer: .textDescription, stage: .completed
            )
        }

        // 最终同步
        var syncResult: SyncEngine.SyncResult?
        if let globalDB = globalDB, !skipSync {
            try Task.checkCancellation()
            progress("同步到全局索引...")
            syncResult = try SyncEngine.sync(
                folderPath: folderPath,
                folderDB: folderDB,
                globalDB: globalDB
            )
        }

        return PipelineManager.ProcessingResult(
            videoId: videoId,
            clipsCreated: clipsCreated,
            clipsAnalyzed: clipsAnalyzed,
            clipsEmbedded: clipsEmbedded,
            srtPath: srtPath,
            syncResult: syncResult,
            sttSkippedNoAudio: skipSttBecauseNoAudio
        )
    }

    // MARK: - 固定间隔采样

    /// 生成固定间隔的场景分段
    ///
    /// 当场景检测不可用时（如 BRAW 等格式），按固定时间间隔切分视频。
    /// - Parameters:
    ///   - duration: 视频总时长（秒）
    ///   - interval: 每段时长（秒），默认 10
    /// - Returns: 场景分段数组，duration ≤ 0 时返回空数组
    public static func fixedIntervalSegments(
        duration: Double,
        interval: Double = 10.0
    ) -> [SceneSegment] {
        guard duration > 0, interval > 0 else { return [] }
        let count = max(1, Int(ceil(duration / interval)))
        return (0..<count).map { i in
            let start = Double(i) * interval
            let end = min(start + interval, duration)
            return SceneSegment(startTime: start, endTime: end)
        }
    }

    // MARK: - 内部辅助

    /// 判断是否需要运行指定层
    static func shouldRunLayer(
        _ layer: Layer,
        currentLayer: Layer,
        config: Config
    ) -> Bool {
        // 已完成该层 → 跳过
        guard layer.rawValue >= currentLayer.rawValue else { return false }
        // 如果 currentLayer == layer 且非 metadata (0)，说明当前层已完成
        // 但 currentLayer 表示的是已完成的最高层，所以需要 > 才跳过
        if layer.rawValue < currentLayer.rawValue { return false }
        // 被配置跳过
        if config.skipLayers.contains(layer) { return false }
        return true
    }

    /// 更新视频的 index_layer 和 index_status
    static func updateVideoLayer(
        folderDB: DatabaseWriter,
        videoId: Int64,
        layer: Layer,
        stage: PipelineManager.Stage,
        error: String? = nil
    ) throws {
        try folderDB.write { db in
            try db.execute(sql: """
                UPDATE videos
                SET index_layer = ?, index_status = ?, index_error = ?,
                    indexed_at = CASE WHEN ? = 'completed' THEN datetime('now') ELSE indexed_at END
                WHERE video_id = ?
                """, arguments: [
                    layer.rawValue, stage.rawValue, error,
                    stage.rawValue, videoId
                ])
        }
    }

    /// 检查已完成视频是否需要重新索引
    ///
    /// - Returns: ProcessingResult 如果可跳过，nil 如果需要重新索引
    private static func checkCompletedVideoSkip(
        video: Video,
        videoId: Int64,
        videoPath: String,
        folderDB: DatabaseWriter,
        progress: (String) -> Void
    ) async throws -> PipelineManager.ProcessingResult? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: videoPath)
        let currentSize = attrs?[.size] as? Int64
        let currentMtime = (attrs?[.modificationDate] as? Date)
            .map { Clip.utcFormatter.string(from: $0) }

        let sizeMatch = currentSize == video.fileSize
        let mtimeMatch = currentMtime == video.fileModified

        if sizeMatch && mtimeMatch {
            progress("已完成且文件未变，跳过")
            return PipelineManager.ProcessingResult(
                videoId: videoId, clipsCreated: 0, clipsAnalyzed: 0,
                clipsEmbedded: 0, srtPath: video.srtPath, syncResult: nil
            )
        }

        // size/mtime 变了 → 计算哈希验证
        if let storedHash = video.fileHash {
            try Task.checkCancellation()
            progress("元数据变更，哈希校验中...")
            let currentHash = try FileHasher.hash128(filePath: videoPath)
            if currentHash == storedHash {
                try await folderDB.write { db in
                    try db.execute(sql: """
                        UPDATE videos SET file_size = ?, file_modified = ?
                        WHERE video_id = ?
                        """, arguments: [currentSize, currentMtime, videoId])
                }
                progress("内容未变（哈希匹配），跳过")
                return PipelineManager.ProcessingResult(
                    videoId: videoId, clipsCreated: 0, clipsAnalyzed: 0,
                    clipsEmbedded: 0, srtPath: video.srtPath, syncResult: nil
                )
            }

            // 内容已变更 → 重置为 pending
            progress("文件内容已变更，重新索引")
            try await folderDB.write { db in
                try db.execute(sql: """
                    UPDATE videos SET index_status = 'pending', index_layer = 0,
                        index_error = NULL, file_size = ?, file_modified = ?,
                        file_hash = NULL, last_processed_clip = NULL
                    WHERE video_id = ?
                    """, arguments: [currentSize, currentMtime, videoId])
            }
            return nil
        } else {
            // storedHash == nil → 旧数据无哈希
            let hasReliableSizeChange =
                currentSize != nil &&
                video.fileSize != nil &&
                !sizeMatch

            if hasReliableSizeChange {
                progress("旧索引无哈希且文件大小变更，重新索引")
                try await folderDB.write { db in
                    try db.execute(sql: """
                        UPDATE videos SET index_status = 'pending', index_layer = 0,
                            index_error = NULL, file_size = ?, file_modified = ?,
                            file_hash = NULL, last_processed_clip = NULL
                        WHERE video_id = ?
                        """, arguments: [currentSize, currentMtime, videoId])
                }
                return nil
            } else {
                progress("补充文件哈希...")
                try Task.checkCancellation()
                let hash = try FileHasher.hash128(filePath: videoPath)
                try await folderDB.write { db in
                    try db.execute(sql: """
                        UPDATE videos SET file_hash = ?, file_size = ?, file_modified = ?
                        WHERE video_id = ?
                        """, arguments: [hash, currentSize, currentMtime, videoId])
                }
                progress("已完成，已补充哈希")
                return PipelineManager.ProcessingResult(
                    videoId: videoId, clipsCreated: 0, clipsAnalyzed: 0,
                    clipsEmbedded: 0, srtPath: video.srtPath, syncResult: nil
                )
            }
        }
    }

    /// 处理 orphaned 视频恢复
    ///
    /// - Returns: ProcessingResult 如果恢复成功，nil 如果需要重建
    private static func handleOrphanedRecovery(
        video: Video,
        videoId: Int64,
        videoPath: String,
        folderPath: String,
        folderDB: DatabaseWriter,
        globalDB: DatabaseWriter?,
        skipSync: Bool,
        progress: (String) -> Void
    ) async throws -> PipelineManager.ProcessingResult? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: videoPath)
        let currentSize = attrs?[.size] as? Int64
        let currentMtime = (attrs?[.modificationDate] as? Date)
            .map { Clip.utcFormatter.string(from: $0) }

        if let storedHash = video.fileHash {
            try Task.checkCancellation()
            progress("检测 orphaned 内容一致性...")
            let currentHash = try FileHasher.hash128(filePath: videoPath)
            if currentHash == storedHash {
                progress("orphaned 哈希匹配，快速恢复")
                try await folderDB.write { db in
                    try db.execute(sql: """
                        UPDATE videos
                        SET index_status = 'completed',
                            index_error = NULL,
                            orphaned_at = NULL,
                            file_size = ?,
                            file_modified = ?,
                            file_hash = ?
                        WHERE video_id = ?
                        """, arguments: [currentSize, currentMtime, currentHash, videoId])
                }

                let recoveredClipCount = try await folderDB.read { db in
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM clips WHERE video_id = ?",
                        arguments: [videoId]
                    ) ?? 0
                }

                var recoverySyncResult: SyncEngine.SyncResult?
                var requiresForceSync = false
                if let globalDB = globalDB {
                    if skipSync {
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

                return PipelineManager.ProcessingResult(
                    videoId: videoId,
                    clipsCreated: recoveredClipCount,
                    clipsAnalyzed: 0,
                    clipsEmbedded: 0,
                    srtPath: video.srtPath,
                    syncResult: recoverySyncResult,
                    requiresForceSync: requiresForceSync
                )
            }
        }

        // 内容不匹配 → 重建
        progress("orphaned 内容不匹配，重建索引")
        try await folderDB.write { db in
            try db.execute(sql: """
                UPDATE videos
                SET index_status = 'pending', index_layer = 0,
                    index_error = NULL, orphaned_at = NULL,
                    file_size = ?, file_modified = ?,
                    file_hash = NULL, last_processed_clip = NULL
                WHERE video_id = ?
                """, arguments: [currentSize, currentMtime, videoId])
        }
        return nil
    }

    // MARK: - CLIP 向量补填

    /// CLIP 向量补填结果
    public struct BackfillResult: Sendable {
        public let totalClips: Int
        public let encoded: Int
        public let skipped: Int
        public let failed: Int
    }

    /// 为已有 clips 补充 CLIP 向量（不重建场景/clips）
    ///
    /// 安全地遍历文件夹库中所有缺少 CLIP 向量的 clips，
    /// 使用 thumbnail_path 进行 SigLIP2 编码并写入 clip_vectors。
    /// 不删除、不修改任何已有数据。
    ///
    /// - Parameters:
    ///   - folderPath: 素材文件夹路径
    ///   - folderDB: 文件夹级数据库
    ///   - globalDB: 全局搜索索引（nil = 不同步）
    ///   - clipProvider: CLIP 嵌入服务
    ///   - onProgress: 进度回调 (已处理数, 总数, 当前视频名)
    /// - Returns: 补填结果
    public static func backfillCLIP(
        folderPath: String,
        folderDB: DatabaseWriter,
        globalDB: DatabaseWriter? = nil,
        clipProvider: CLIPEmbeddingProvider,
        onProgress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async throws -> BackfillResult {
        let modelName = CLIPEmbeddingProvider.modelName

        // 1. 查找所有缺少 CLIP 向量的 clips
        let clipsToProcess: [(clipId: Int64, thumbnailPath: String, videoPath: String)] =
            try await folderDB.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT c.clip_id, c.thumbnail_path, v.file_path
                    FROM clips c
                    JOIN videos v ON v.video_id = c.video_id
                    WHERE c.thumbnail_path IS NOT NULL
                      AND c.clip_id NOT IN (
                          SELECT cv.clip_id FROM clip_vectors cv
                          WHERE cv.model_name = ?
                      )
                    ORDER BY v.video_id, c.clip_id
                    """, arguments: [modelName])
                return rows.compactMap { row -> (Int64, String, String)? in
                    let clipId: Int64? = row["clip_id"]
                    let thumb: String? = row["thumbnail_path"]
                    let videoPath: String? = row["file_path"]
                    guard let cid = clipId, let t = thumb, let vp = videoPath else {
                        return nil
                    }
                    return (cid, t, vp)
                }
            }

        let total = clipsToProcess.count
        guard total > 0 else {
            return BackfillResult(totalClips: 0, encoded: 0, skipped: 0, failed: 0)
        }

        // 2. 确认 image encoder 可用
        guard await clipProvider.isImageEncoderAvailable else {
            throw NSError(domain: "LayeredIndexer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "SigLIP2 image encoder 不可用"
            ])
        }

        // 3. 逐个编码
        var encoded = 0
        var skipped = 0
        var failed = 0

        for (index, item) in clipsToProcess.enumerated() {
            try Task.checkCancellation()

            let videoName = (item.videoPath as NSString).lastPathComponent
            onProgress?(index, total, videoName)

            // 检查缩略图文件存在
            guard FileManager.default.fileExists(atPath: item.thumbnailPath) else {
                skipped += 1
                continue
            }

            do {
                let vector = try await clipProvider.encodeImage(path: item.thumbnailPath)
                let data = EmbeddingUtils.serializeEmbedding(vector)
                try await folderDB.write { db in
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO clip_vectors
                        (clip_id, model_name, dimensions, vector)
                        VALUES (?, ?, ?, ?)
                        """, arguments: [
                            item.clipId, modelName,
                            vector.count, data
                        ])
                }
                encoded += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed += 1
            }
        }

        // 4. 同步到全局库
        if let globalDB = globalDB {
            let _ = try SyncEngine.sync(
                folderPath: folderPath,
                folderDB: folderDB,
                globalDB: globalDB,
                force: true
            )
        }

        return BackfillResult(
            totalClips: total,
            encoded: encoded,
            skipped: skipped,
            failed: failed
        )
    }
}
