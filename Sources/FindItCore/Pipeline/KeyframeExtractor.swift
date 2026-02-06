import Foundation

/// 关键帧提取器
///
/// 从视频中按场景切点提取关键帧缩略图。
/// 根据场景时长动态计算帧数，并压缩为 512px 短边 JPEG。
public enum KeyframeExtractor {

    /// 关键帧提取配置
    public struct Config {
        /// 缩略图短边像素（长边按比例缩放）
        public var thumbnailShortEdge: Int
        /// JPEG 质量 (FFmpeg -q:v, 1-31, 越小质量越高; 5 ≈ 80%)
        public var jpegQuality: Int
        /// 每场景最大帧数
        public var maxFramesPerScene: Int
        /// 帧数计算的时长除数（秒）
        public var frameDurationDivisor: Double

        public static let `default` = Config(
            thumbnailShortEdge: 512,
            jpegQuality: 5,
            maxFramesPerScene: 5,
            frameDurationDivisor: 5.0
        )

        public init(
            thumbnailShortEdge: Int = 512,
            jpegQuality: Int = 5,
            maxFramesPerScene: Int = 5,
            frameDurationDivisor: Double = 5.0
        ) {
            self.thumbnailShortEdge = thumbnailShortEdge
            self.jpegQuality = jpegQuality
            self.maxFramesPerScene = maxFramesPerScene
            self.frameDurationDivisor = frameDurationDivisor
        }
    }

    /// 单帧提取结果
    public struct ExtractedFrame {
        /// 场景索引
        public let sceneIndex: Int
        /// 帧在视频中的时间戳（秒）
        public let timestamp: Double
        /// 输出文件路径
        public let filePath: String
    }

    /// 为一组场景片段提取关键帧
    ///
    /// - Parameters:
    ///   - inputPath: 视频文件路径
    ///   - segments: 场景片段数组（由 SceneDetector 生成）
    ///   - outputDirectory: 输出目录路径（不存在时自动创建）
    ///   - config: 提取配置
    ///   - ffmpegConfig: FFmpeg 路径配置
    /// - Returns: 提取的关键帧列表
    public static func extractKeyframes(
        inputPath: String,
        segments: [SceneSegment],
        outputDirectory: String,
        config: Config = .default,
        ffmpegConfig: FFmpegConfig = .default
    ) throws -> [ExtractedFrame] {
        guard FileManager.default.fileExists(atPath: inputPath) else {
            throw FFmpegError.inputFileNotFound(path: inputPath)
        }

        // 确保输出目录存在
        try FileManager.default.createDirectory(
            atPath: outputDirectory,
            withIntermediateDirectories: true
        )

        var frames: [ExtractedFrame] = []

        for (sceneIndex, segment) in segments.enumerated() {
            let frameCount = framesPerScene(duration: segment.duration, config: config)
            let timestamps = frameTimestamps(segment: segment, frameCount: frameCount)

            for (frameIndex, timestamp) in timestamps.enumerated() {
                let fileName = String(format: "scene_%03d_frame_%02d.jpg", sceneIndex, frameIndex)
                let outputPath = (outputDirectory as NSString).appendingPathComponent(fileName)

                let args = buildExtractArguments(
                    inputPath: inputPath,
                    timestamp: timestamp,
                    outputPath: outputPath,
                    config: config
                )

                _ = try FFmpegBridge.run(arguments: args, config: ffmpegConfig)

                if FileManager.default.fileExists(atPath: outputPath) {
                    frames.append(ExtractedFrame(
                        sceneIndex: sceneIndex,
                        timestamp: timestamp,
                        filePath: outputPath
                    ))
                }
            }
        }

        return frames
    }

    // MARK: - Internal 纯函数

    /// 计算场景应提取的帧数
    ///
    /// `max(1, min(maxFrames, duration / divisor))`
    /// - 3s 场景 → 1 帧
    /// - 15s 场景 → 3 帧
    /// - 45s 场景 → 5 帧（上限）
    static func framesPerScene(duration: Double, config: Config = .default) -> Int {
        max(1, min(config.maxFramesPerScene, Int(duration / config.frameDurationDivisor)))
    }

    /// 计算场景内各帧的提取时间戳
    ///
    /// 将场景均分为 N 段，取每段中点。
    /// 例: segment [10, 25], 3 帧 → [12.5, 17.5, 22.5]
    static func frameTimestamps(segment: SceneSegment, frameCount: Int) -> [Double] {
        guard frameCount > 0 else { return [] }
        let interval = segment.duration / Double(frameCount)
        return (0..<frameCount).map { i in
            segment.startTime + interval * (Double(i) + 0.5)
        }
    }

    /// 构建单帧提取的 FFmpeg 命令参数
    ///
    /// 使用 `-ss` 前置输入以利用关键帧快速 seek。
    /// 缩放短边到指定像素，长边按比例。
    static func buildExtractArguments(
        inputPath: String,
        timestamp: Double,
        outputPath: String,
        config: Config
    ) -> [String] {
        let edge = config.thumbnailShortEdge
        // scale filter: 短边缩放到 edge，长边自动 (-2 保证偶数)
        let scaleFilter = "scale='if(lt(iw,ih),\(edge),-2)':'if(lt(iw,ih),-2,\(edge))'"

        return [
            "-ss", String(format: "%.3f", timestamp),  // seek 前置
            "-i", inputPath,
            "-vframes", "1",
            "-vf", scaleFilter,
            "-q:v", String(config.jpegQuality),
            "-y",
            outputPath
        ]
    }
}
