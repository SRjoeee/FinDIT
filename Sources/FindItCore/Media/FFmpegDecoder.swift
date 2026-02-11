import Foundation

/// FFmpeg 解码器
///
/// 通过委托给现有的 FFmpegBridge、SceneDetector、KeyframeExtractor、AudioExtractor
/// 实现 `MediaDecoder` 和 `SceneDetectable` 协议。
///
/// 作为通用 fallback 解码器 (priority=50)，支持所有常见视频格式。
public final class FFmpegDecoder: MediaDecoder, SceneDetectable, @unchecked Sendable {

    public let capability = MediaCapability(
        fileExtensions: ["mp4", "mov", "mkv", "avi", "mxf", "webm", "m4v", "ts", "mts"],
        utTypes: ["public.movie"],
        name: "FFmpeg",
        priority: 50
    )

    private let config: FFmpegConfig

    public init(config: FFmpegConfig = .default) {
        self.config = config
    }

    // MARK: - MediaDecoder

    public func probe(filePath: String) async throws -> ProbeResult {
        guard FileManager.default.fileExists(atPath: filePath) else {
            return .unsupported()
        }

        // FFmpeg -i 输出格式信息到 stderr，exit code 为 1（因为没有输出文件）
        let result: FFmpegBridge.ProcessResult
        do {
            result = try await FFmpegBridge.runAsync(
                arguments: ["-i", filePath],
                config: config,
                timeout: 10
            )
        } catch {
            // FFmpeg -i 总是返回非零退出码，需要从 FFmpegError 中提取 stderr
            if let ffmpegError = error as? FFmpegError,
               case .processExitedWithError(_, let stderr) = ffmpegError {
                return parseProbeOutput(stderr, filePath: filePath)
            }
            return .unsupported()
        }

        return parseProbeOutput(result.stderr, filePath: filePath)
    }

    public func extractKeyframes(
        filePath: String,
        times: [Double],
        outputDir: String,
        maxDimension: Int
    ) async throws -> [String] {
        // 将 times 转换为 SceneSegment（每个时间点构造一个 1 秒的 segment）
        let segments = times.map { time in
            SceneSegment(startTime: time, endTime: time + 1.0)
        }

        let extractConfig = KeyframeExtractor.Config(
            thumbnailShortEdge: maxDimension,
            maxFramesPerScene: 1
        )

        let frames = try await KeyframeExtractor.extractKeyframesAsync(
            inputPath: filePath,
            segments: segments,
            outputDirectory: outputDir,
            config: extractConfig,
            ffmpegConfig: config
        )

        return frames.map(\.filePath)
    }

    public func extractAudio(
        filePath: String,
        outputPath: String,
        sampleRate: Int
    ) async throws -> String {
        // AudioExtractor 固定 16kHz mono WAV，sampleRate 参数暂不使用
        return try await AudioExtractor.extractAudioAsync(
            inputPath: filePath,
            outputPath: outputPath,
            config: config
        )
    }

    // MARK: - SceneDetectable

    public func detectScenesOptimized(
        filePath: String,
        audioOutputPath: String?,
        config sceneConfig: SceneDetector.Config
    ) async throws -> SceneDetector.CombinedDetectionResult {
        try await SceneDetector.detectScenesOptimizedAsync(
            inputPath: filePath,
            audioOutputPath: audioOutputPath,
            config: sceneConfig,
            ffmpegConfig: config
        )
    }

    // MARK: - FFmpeg 输出解析

    /// 解析 FFmpeg -i 的 stderr 输出
    ///
    /// 典型输出:
    /// ```
    /// Input #0, mov,mp4,...
    ///   Duration: 00:05:23.45, start: 0.000000, bitrate: 12345 kb/s
    ///   Stream #0:0: Video: h264 (High), ..., 1920x1080, 30 fps
    ///   Stream #0:1: Audio: aac, 44100 Hz, stereo, ...
    /// ```
    func parseProbeOutput(_ stderr: String, filePath: String) -> ProbeResult {
        // 解析容器格式
        let containerFormat = parseContainerFormat(stderr)

        // 解析时长
        let duration = parseDuration(stderr)

        // 解析视频流信息
        let (codec, resolution, fps) = parseVideoStream(stderr)

        // 如果连时长都解析不出来，可能不是有效的媒体文件
        guard duration != nil || codec != nil else {
            return .unsupported()
        }

        return ProbeResult(
            score: 70,
            mediaType: .video,
            containerFormat: containerFormat,
            codec: codec,
            duration: duration,
            resolution: resolution,
            fps: fps
        )
    }

    /// 解析容器格式: `Input #0, mov,mp4,m4a,3gp,...`
    private func parseContainerFormat(_ stderr: String) -> String? {
        // 匹配 "Input #0, <format_list>,"
        let pattern = #"Input #\d+, ([^,]+)"#
        guard let match = stderr.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let fullMatch = String(stderr[match])
        // 提取逗号后的第一个格式名
        let parts = fullMatch.split(separator: ",", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }

    /// 解析时长: `Duration: 00:05:23.45`
    private func parseDuration(_ stderr: String) -> Double? {
        let pattern = #"Duration:\s+(\d{2}):(\d{2}):(\d{2})\.(\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: stderr,
                range: NSRange(stderr.startIndex..., in: stderr)
              ) else {
            return nil
        }

        guard let hRange = Range(match.range(at: 1), in: stderr),
              let mRange = Range(match.range(at: 2), in: stderr),
              let sRange = Range(match.range(at: 3), in: stderr),
              let csRange = Range(match.range(at: 4), in: stderr),
              let hours = Double(stderr[hRange]),
              let minutes = Double(stderr[mRange]),
              let seconds = Double(stderr[sRange]),
              let centiseconds = Double(stderr[csRange]) else {
            return nil
        }

        return hours * 3600 + minutes * 60 + seconds + centiseconds / 100
    }

    /// 解析视频流: `Stream #0:0: Video: h264 ..., 1920x1080 ..., 30 fps`
    private func parseVideoStream(_ stderr: String) -> (codec: String?, resolution: (width: Int, height: Int)?, fps: Double?) {
        // 找到 Video 流行
        guard let videoLine = stderr.split(separator: "\n")
            .first(where: { $0.contains("Video:") }) else {
            return (nil, nil, nil)
        }
        let line = String(videoLine)

        // 解析 codec: "Video: h264" 或 "Video: hevc"
        let codec: String?
        let codecPattern = #"Video:\s+(\w+)"#
        if let codecRegex = try? NSRegularExpression(pattern: codecPattern),
           let codecMatch = codecRegex.firstMatch(
            in: line,
            range: NSRange(line.startIndex..., in: line)
           ),
           let codecRange = Range(codecMatch.range(at: 1), in: line) {
            codec = String(line[codecRange])
        } else {
            codec = nil
        }

        // 解析分辨率: "1920x1080" 或 "3840x2160"
        let resolution: (width: Int, height: Int)?
        let resPattern = #"(\d{2,5})x(\d{2,5})"#
        if let resRegex = try? NSRegularExpression(pattern: resPattern),
           let resMatch = resRegex.firstMatch(
            in: line,
            range: NSRange(line.startIndex..., in: line)
           ),
           let wRange = Range(resMatch.range(at: 1), in: line),
           let hRange = Range(resMatch.range(at: 2), in: line),
           let w = Int(line[wRange]),
           let h = Int(line[hRange]) {
            resolution = (width: w, height: h)
        } else {
            resolution = nil
        }

        // 解析帧率: "30 fps" 或 "29.97 fps" 或 "25 tbr"
        let fps: Double?
        let fpsPattern = #"([\d.]+)\s+(?:fps|tbr)"#
        if let fpsRegex = try? NSRegularExpression(pattern: fpsPattern),
           let fpsMatch = fpsRegex.firstMatch(
            in: line,
            range: NSRange(line.startIndex..., in: line)
           ),
           let fpsRange = Range(fpsMatch.range(at: 1), in: line),
           let fpsVal = Double(line[fpsRange]) {
            fps = fpsVal
        } else {
            fps = nil
        }

        return (codec, resolution, fps)
    }
}
