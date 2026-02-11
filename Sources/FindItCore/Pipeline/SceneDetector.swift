import Foundation

/// 场景片段
public struct SceneSegment: Equatable {
    /// 场景起始时间（秒）
    public let startTime: Double
    /// 场景结束时间（秒）
    public let endTime: Double
    /// 场景时长
    public var duration: Double { endTime - startTime }

    public init(startTime: Double, endTime: Double) {
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// 场景检测器
///
/// 使用 FFmpeg scene filter 检测视频场景切换点。
/// 支持短镜头合并（< 2s）和长镜头拆分（> 30s 按 15s 间隔）。
///
/// 算法流程:
/// 1. FFmpeg `select='gt(scene,threshold)'` + `showinfo` 获取候选切点
/// 2. 过滤间距 < minSegmentDuration 的短脉冲（去噪）
/// 3. 切点列表 → SceneSegment 数组
/// 4. 合并短镜头
/// 5. 拆分长镜头
public enum SceneDetector {

    /// 场景检测配置
    public struct Config: Sendable {
        /// 场景检测阈值（0-1，越小越敏感）
        public var threshold: Double
        /// 短镜头最小时长（秒），短于此值的片段将被合并
        public var minSegmentDuration: Double
        /// 长镜头最大时长（秒），超过此值将按 paddingInterval 拆分
        public var maxSegmentDuration: Double
        /// 长镜头拆分间隔（秒）
        public var paddingInterval: Double

        public static let `default` = Config(
            threshold: 0.3,
            minSegmentDuration: 2.0,
            maxSegmentDuration: 30.0,
            paddingInterval: 15.0
        )

        public init(
            threshold: Double = 0.3,
            minSegmentDuration: Double = 2.0,
            maxSegmentDuration: Double = 30.0,
            paddingInterval: Double = 15.0
        ) {
            self.threshold = threshold
            self.minSegmentDuration = minSegmentDuration
            self.maxSegmentDuration = maxSegmentDuration
            self.paddingInterval = paddingInterval
        }
    }

    /// 从视频文件检测场景切换点
    ///
    /// - Parameters:
    ///   - inputPath: 视频文件路径
    ///   - videoDuration: 视频总时长。为 nil 时自动通过 FFmpeg 获取
    ///   - config: 场景检测配置
    ///   - ffmpegConfig: FFmpeg 路径配置
    /// - Returns: 按时间排序的场景片段数组
    public static func detectScenes(
        inputPath: String,
        videoDuration: Double? = nil,
        config: Config = .default,
        ffmpegConfig: FFmpegConfig = .default
    ) throws -> [SceneSegment] {
        guard FileManager.default.fileExists(atPath: inputPath) else {
            throw FFmpegError.inputFileNotFound(path: inputPath)
        }

        let duration = try videoDuration ?? FFmpegBridge.videoDuration(inputPath: inputPath, config: ffmpegConfig)
        guard duration > 0 else {
            return []
        }

        // 运行 FFmpeg 场景检测
        let args = buildDetectionArguments(inputPath: inputPath, threshold: config.threshold)
        // 场景检测以 -f null - 结尾，FFmpeg 退出码为 0
        let result = try FFmpegBridge.run(arguments: args, config: ffmpegConfig)

        // 解析时间戳
        let timestamps = parseTimestamps(from: result.stderr)

        // 过滤噪声
        let filtered = filterByMinGap(timestamps, minGap: config.minSegmentDuration)

        // 生成片段
        var segments = segmentsFromCutPoints(filtered, videoDuration: duration)

        // 合并短镜头
        segments = mergeShortSegments(segments, minDuration: config.minSegmentDuration)

        // 拆分长镜头
        segments = splitLongSegments(segments, maxDuration: config.maxSegmentDuration, interval: config.paddingInterval)

        return segments
    }

    /// 异步场景检测（不阻塞 Swift 并发线程）
    public static func detectScenesAsync(
        inputPath: String,
        videoDuration: Double? = nil,
        config: Config = .default,
        ffmpegConfig: FFmpegConfig = .default
    ) async throws -> [SceneSegment] {
        guard FileManager.default.fileExists(atPath: inputPath) else {
            throw FFmpegError.inputFileNotFound(path: inputPath)
        }

        let duration: Double
        if let provided = videoDuration {
            duration = provided
        } else {
            duration = try await FFmpegBridge.videoDurationAsync(inputPath: inputPath, config: ffmpegConfig)
        }
        guard duration > 0 else { return [] }

        let args = buildDetectionArguments(inputPath: inputPath, threshold: config.threshold)
        let result = try await FFmpegBridge.runAsync(arguments: args, config: ffmpegConfig)

        let timestamps = parseTimestamps(from: result.stderr)
        let filtered = filterByMinGap(timestamps, minGap: config.minSegmentDuration)
        var segments = segmentsFromCutPoints(filtered, videoDuration: duration)
        segments = mergeShortSegments(segments, minDuration: config.minSegmentDuration)
        segments = splitLongSegments(segments, maxDuration: config.maxSegmentDuration, interval: config.paddingInterval)
        return segments
    }

    // MARK: - 优化版：合并场景检测 + 时长 + 音频提取

    /// 合并结果
    public struct CombinedDetectionResult {
        /// 检测到的场景分段
        public let scenes: [SceneSegment]
        /// 视频时长（秒）
        public let duration: Double
        /// 是否成功提取了音频（请求了音频输出时使用）
        public let audioExtracted: Bool

        public init(scenes: [SceneSegment], duration: Double, audioExtracted: Bool = false) {
            self.scenes = scenes
            self.duration = duration
            self.audioExtracted = audioExtracted
        }
    }

    /// 优化版场景检测：单次 FFmpeg 调用获取场景 + 时长 + 可选音频
    ///
    /// 消除独立的 `FFmpegBridge.videoDuration()` 调用（节省一次进程启动），
    /// 从场景检测的 stderr 中解析 Duration。
    /// 可选同时提取音频（双输出 FFmpeg 命令），减少一次文件 I/O。
    ///
    /// - Parameters:
    ///   - inputPath: 视频文件路径
    ///   - audioOutputPath: 音频输出路径（nil = 不提取音频）
    ///   - config: 场景检测配置
    ///   - ffmpegConfig: FFmpeg 路径配置
    /// - Returns: 场景分段 + 视频时长
    public static func detectScenesOptimized(
        inputPath: String,
        audioOutputPath: String? = nil,
        config: Config = .default,
        ffmpegConfig: FFmpegConfig = .default
    ) throws -> CombinedDetectionResult {
        guard FileManager.default.fileExists(atPath: inputPath) else {
            throw FFmpegError.inputFileNotFound(path: inputPath)
        }

        if let audioPath = audioOutputPath {
            let combinedArgs = buildCombinedArguments(
                inputPath: inputPath,
                threshold: config.threshold,
                audioOutputPath: audioPath
            )
            do {
                let result = try FFmpegBridge.run(arguments: combinedArgs, config: ffmpegConfig)
                return try buildCombinedResult(
                    ffmpegResult: result,
                    config: config,
                    audioOutputPath: audioPath,
                    audioExtracted: true
                )
            } catch let FFmpegError.processExitedWithError(_, stderr)
                where FFmpegBridge.isMissingAudioStreamError(stderr: stderr) {
                // 无音轨是可恢复场景：回退为“仅场景检测”，避免整条管线失败。
                try? FileManager.default.removeItem(atPath: audioPath)
            }
        }

        let args = buildDetectionArguments(inputPath: inputPath, threshold: config.threshold)
        let result = try FFmpegBridge.run(arguments: args, config: ffmpegConfig)
        return try buildCombinedResult(
            ffmpegResult: result,
            config: config,
            audioOutputPath: nil,
            audioExtracted: false
        )
    }

    /// 异步优化版场景检测（不阻塞 Swift 并发线程）
    public static func detectScenesOptimizedAsync(
        inputPath: String,
        audioOutputPath: String? = nil,
        config: Config = .default,
        ffmpegConfig: FFmpegConfig = .default
    ) async throws -> CombinedDetectionResult {
        guard FileManager.default.fileExists(atPath: inputPath) else {
            throw FFmpegError.inputFileNotFound(path: inputPath)
        }

        if let audioPath = audioOutputPath {
            let combinedArgs = buildCombinedArguments(
                inputPath: inputPath,
                threshold: config.threshold,
                audioOutputPath: audioPath
            )
            do {
                let result = try await FFmpegBridge.runAsync(arguments: combinedArgs, config: ffmpegConfig)
                return try buildCombinedResult(
                    ffmpegResult: result,
                    config: config,
                    audioOutputPath: audioPath,
                    audioExtracted: true
                )
            } catch let FFmpegError.processExitedWithError(_, stderr)
                where FFmpegBridge.isMissingAudioStreamError(stderr: stderr) {
                try? FileManager.default.removeItem(atPath: audioPath)
            }
        }

        let args = buildDetectionArguments(inputPath: inputPath, threshold: config.threshold)
        let result = try await FFmpegBridge.runAsync(arguments: args, config: ffmpegConfig)
        return try buildCombinedResult(
            ffmpegResult: result,
            config: config,
            audioOutputPath: nil,
            audioExtracted: false
        )
    }

    private static func buildCombinedResult(
        ffmpegResult: FFmpegBridge.ProcessResult,
        config: Config,
        audioOutputPath: String?,
        audioExtracted: Bool
    ) throws -> CombinedDetectionResult {
        // 从 stderr 解析时长（FFmpeg 总会打印输入文件的 Duration）
        guard let duration = FFmpegBridge.parseDuration(from: ffmpegResult.stderr) else {
            throw FFmpegError.outputParsingFailed(detail: "未从场景检测输出中找到 Duration")
        }
        guard duration > 0 else {
            return CombinedDetectionResult(scenes: [], duration: 0, audioExtracted: audioExtracted)
        }

        // 解析场景切点
        let timestamps = parseTimestamps(from: ffmpegResult.stderr)
        let filtered = filterByMinGap(timestamps, minGap: config.minSegmentDuration)
        var segments = segmentsFromCutPoints(filtered, videoDuration: duration)
        segments = mergeShortSegments(segments, minDuration: config.minSegmentDuration)
        segments = splitLongSegments(
            segments, maxDuration: config.maxSegmentDuration, interval: config.paddingInterval
        )

        // 验证音频输出
        if let audioPath = audioOutputPath {
            guard FileManager.default.fileExists(atPath: audioPath) else {
                throw FFmpegError.outputFileNotCreated(path: audioPath)
            }
        }

        return CombinedDetectionResult(
            scenes: segments,
            duration: duration,
            audioExtracted: audioExtracted
        )
    }

    /// 构建合并命令的参数（包含音频提取）
    static func buildCombinedArguments(
        inputPath: String,
        threshold: Double,
        audioOutputPath: String
    ) -> [String] {
        [
            "-hwaccel", "videotoolbox",
            "-i", inputPath,
            "-vf", "fps=5,select='gt(scene,\(threshold))',showinfo",
            "-fps_mode", "vfr",
            "-f", "null",
            "-",
            "-vn", "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1",
            "-y", audioOutputPath
        ]
    }

    // MARK: - Internal 纯函数

    /// 构建场景检测 FFmpeg 命令参数
    ///
    /// 性能优化:
    /// - `-hwaccel videotoolbox`: Apple Silicon 硬件解码，释放 CPU
    /// - `fps=5`: 降采样到 5fps，减少 ~6x 需解码的帧数
    ///   （对硬切检测精度影响极小，硬切边界误差 ≤ 0.2s）
    static func buildDetectionArguments(inputPath: String, threshold: Double) -> [String] {
        [
            "-hwaccel", "videotoolbox",
            "-i", inputPath,
            "-vf", "fps=5,select='gt(scene,\(threshold))',showinfo",
            "-fps_mode", "vfr",
            "-f", "null",
            "-"
        ]
    }

    /// 从 FFmpeg showinfo 输出解析时间戳
    ///
    /// showinfo 输出格式:
    /// `[Parsed_showinfo_1 @ 0x...] n:0 pts:12345 pts_time:12.345 ...`
    static func parseTimestamps(from stderr: String) -> [Double] {
        var timestamps: [Double] = []
        let pattern = #"pts_time:\s*([0-9]+\.?[0-9]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return timestamps
        }

        let nsString = stderr as NSString
        let matches = regex.matches(in: stderr, range: NSRange(location: 0, length: nsString.length))

        for match in matches {
            if match.numberOfRanges >= 2 {
                let valueRange = match.range(at: 1)
                let valueStr = nsString.substring(with: valueRange)
                if let value = Double(valueStr) {
                    timestamps.append(value)
                }
            }
        }

        return timestamps.sorted()
    }

    /// 过滤间距小于 minGap 的连续切点（去噪）
    ///
    /// 保留每组聚集切点中的第一个。
    static func filterByMinGap(_ timestamps: [Double], minGap: Double) -> [Double] {
        guard !timestamps.isEmpty else { return [] }

        var result = [timestamps[0]]
        for i in 1..<timestamps.count {
            if timestamps[i] - result.last! >= minGap {
                result.append(timestamps[i])
            }
        }
        return result
    }

    /// 从切点列表生成场景片段
    ///
    /// 切点 [5.0, 12.5] + duration 120.0 → [0-5, 5-12.5, 12.5-120]
    static func segmentsFromCutPoints(_ cutPoints: [Double], videoDuration: Double) -> [SceneSegment] {
        guard !cutPoints.isEmpty else {
            // 无切点，整个视频为一个场景
            return [SceneSegment(startTime: 0, endTime: videoDuration)]
        }

        var segments: [SceneSegment] = []

        // 第一个片段: 0 → 第一个切点
        if cutPoints[0] > 0.01 {
            segments.append(SceneSegment(startTime: 0, endTime: cutPoints[0]))
        }

        // 中间片段
        for i in 0..<(cutPoints.count - 1) {
            segments.append(SceneSegment(startTime: cutPoints[i], endTime: cutPoints[i + 1]))
        }

        // 最后一个片段: 最后切点 → 视频结尾
        if let last = cutPoints.last, videoDuration - last > 0.01 {
            segments.append(SceneSegment(startTime: last, endTime: videoDuration))
        }

        return segments
    }

    /// 合并短镜头（< minDuration 的片段与后续片段合并）
    static func mergeShortSegments(_ segments: [SceneSegment], minDuration: Double) -> [SceneSegment] {
        guard segments.count > 1 else { return segments }

        var result: [SceneSegment] = []
        var i = 0

        while i < segments.count {
            var current = segments[i]

            // 不断吸收后续的短片段
            while current.duration < minDuration && i + 1 < segments.count {
                i += 1
                current = SceneSegment(startTime: current.startTime, endTime: segments[i].endTime)
            }

            result.append(current)
            i += 1
        }

        return result
    }

    /// 拆分长镜头（> maxDuration 的片段按 interval 间隔拆分）
    static func splitLongSegments(
        _ segments: [SceneSegment],
        maxDuration: Double,
        interval: Double
    ) -> [SceneSegment] {
        var result: [SceneSegment] = []

        for segment in segments {
            if segment.duration <= maxDuration {
                result.append(segment)
            } else {
                // 按 interval 拆分
                var start = segment.startTime
                while start < segment.endTime {
                    let end = min(start + interval, segment.endTime)
                    // 避免尾部产生极短片段
                    if segment.endTime - end < interval * 0.5 && end < segment.endTime {
                        result.append(SceneSegment(startTime: start, endTime: segment.endTime))
                        break
                    }
                    result.append(SceneSegment(startTime: start, endTime: end))
                    start = end
                }
            }
        }

        return result
    }
}
