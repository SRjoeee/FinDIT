import Foundation

/// 音频提取器
///
/// 从视频文件中提取 16kHz 单声道 WAV 音频，供 WhisperKit 转录使用。
public enum AudioExtractor {

    /// 从视频文件提取 16kHz mono WAV 音频
    ///
    /// 命令: `ffmpeg -i input.mp4 -vn -acodec pcm_s16le -ar 16000 -ac 1 -y output.wav`
    ///
    /// - Parameters:
    ///   - inputPath: 视频文件路径
    ///   - outputPath: 输出 WAV 文件路径
    ///   - config: FFmpeg 配置
    /// - Returns: 输出文件路径
    @discardableResult
    public static func extractAudio(
        inputPath: String,
        outputPath: String,
        config: FFmpegConfig = .default
    ) throws -> String {
        guard FileManager.default.fileExists(atPath: inputPath) else {
            throw FFmpegError.inputFileNotFound(path: inputPath)
        }

        let args = buildArguments(inputPath: inputPath, outputPath: outputPath)
        _ = try FFmpegBridge.run(arguments: args, config: config)

        guard FileManager.default.fileExists(atPath: outputPath) else {
            throw FFmpegError.outputFileNotCreated(path: outputPath)
        }

        return outputPath
    }

    /// 异步提取音频（不阻塞 Swift 并发线程）
    ///
    /// - Parameters:
    ///   - inputPath: 视频文件路径
    ///   - outputPath: 输出 WAV 文件路径
    ///   - startTime: 起始位置（秒），nil = 从头开始
    ///   - duration: 最大时长（秒），nil = 不限
    ///   - config: FFmpeg 配置
    /// - Returns: 输出文件路径
    @discardableResult
    public static func extractAudioAsync(
        inputPath: String,
        outputPath: String,
        startTime: Double? = nil,
        duration: Double? = nil,
        config: FFmpegConfig = .default
    ) async throws -> String {
        guard FileManager.default.fileExists(atPath: inputPath) else {
            throw FFmpegError.inputFileNotFound(path: inputPath)
        }

        let args = buildArguments(
            inputPath: inputPath, outputPath: outputPath,
            startTime: startTime, duration: duration
        )
        _ = try await FFmpegBridge.runAsync(arguments: args, config: config)

        guard FileManager.default.fileExists(atPath: outputPath) else {
            throw FFmpegError.outputFileNotCreated(path: outputPath)
        }

        return outputPath
    }

    /// 构建音频提取命令参数
    ///
    /// `-ss` 放在 `-i` 前面（输入级 seek），比输出级更快。
    static func buildArguments(
        inputPath: String,
        outputPath: String,
        startTime: Double? = nil,
        duration: Double? = nil
    ) -> [String] {
        var args: [String] = []

        // 输入级 seek（放在 -i 前面）
        if let ss = startTime, ss > 0 {
            args += ["-ss", String(format: "%.3f", ss)]
        }

        args += ["-i", inputPath]

        // 时长限制
        if let t = duration, t > 0 {
            args += ["-t", String(format: "%.3f", t)]
        }

        args += [
            "-vn",                   // 不处理视频流
            "-acodec", "pcm_s16le",  // 16-bit PCM
            "-ar", "16000",          // 16kHz 采样率
            "-ac", "1",              // 单声道
            "-y",                    // 覆盖已有文件
            outputPath
        ]

        return args
    }
}
