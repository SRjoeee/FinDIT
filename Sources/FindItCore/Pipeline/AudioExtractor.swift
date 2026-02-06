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

    /// 构建音频提取命令参数
    static func buildArguments(inputPath: String, outputPath: String) -> [String] {
        [
            "-i", inputPath,
            "-vn",                   // 不处理视频流
            "-acodec", "pcm_s16le",  // 16-bit PCM
            "-ar", "16000",          // 16kHz 采样率
            "-ac", "1",              // 单声道
            "-y",                    // 覆盖已有文件
            outputPath
        ]
    }
}
