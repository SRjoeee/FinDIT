import Foundation

/// 关键帧提取器
///
/// 从视频中按场景切点提取关键帧缩略图。
/// 根据场景时长动态计算帧数，并压缩为 512px 短边 JPEG。
public enum KeyframeExtractor {

    /// 关键帧提取配置
    public struct Config: Sendable {
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
            maxFramesPerScene: 3,
            frameDurationDivisor: 5.0
        )

        public init(
            thumbnailShortEdge: Int = 512,
            jpegQuality: Int = 5,
            maxFramesPerScene: Int = 3,
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
    /// 每个场景使用单次 FFmpeg 调用批量提取所有关键帧，
    /// 避免逐帧启动子进程的开销（10 场景 × 3 帧 = 30 次降为 10 次调用）。
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
            guard !timestamps.isEmpty else { continue }

            if timestamps.count == 1 {
                // 单帧：沿用 -ss seek 模式（最快）
                let fileName = String(format: "scene_%03d_frame_%02d.jpg", sceneIndex, 0)
                let outputPath = (outputDirectory as NSString).appendingPathComponent(fileName)
                let args = buildExtractArguments(
                    inputPath: inputPath,
                    timestamp: timestamps[0],
                    outputPath: outputPath,
                    config: config
                )
                _ = try FFmpegBridge.run(arguments: args, config: ffmpegConfig)
                if FileManager.default.fileExists(atPath: outputPath) {
                    frames.append(ExtractedFrame(
                        sceneIndex: sceneIndex,
                        timestamp: timestamps[0],
                        filePath: outputPath
                    ))
                }
            } else {
                // 多帧：单次 FFmpeg 调用批量提取
                let outputPattern = (outputDirectory as NSString)
                    .appendingPathComponent(String(format: "scene_%03d_frame_%%02d.jpg", sceneIndex))
                let args = buildBatchExtractArguments(
                    inputPath: inputPath,
                    segment: segment,
                    timestamps: timestamps,
                    outputPattern: outputPattern,
                    config: config
                )
                _ = try FFmpegBridge.run(arguments: args, config: ffmpegConfig)

                // 收集实际生成的文件
                var batchFrameCount = 0
                for (frameIndex, timestamp) in timestamps.enumerated() {
                    let fileName = String(format: "scene_%03d_frame_%02d.jpg", sceneIndex, frameIndex)
                    let outputPath = (outputDirectory as NSString).appendingPathComponent(fileName)
                    if FileManager.default.fileExists(atPath: outputPath) {
                        frames.append(ExtractedFrame(
                            sceneIndex: sceneIndex,
                            timestamp: timestamp,
                            filePath: outputPath
                        ))
                        batchFrameCount += 1
                    }
                }

                // 安全网：批量提取产出 0 帧时，用单帧模式在场景中点补提 1 帧
                if batchFrameCount == 0 {
                    let midpoint = (segment.startTime + segment.endTime) / 2
                    let fallbackName = String(format: "scene_%03d_frame_00.jpg", sceneIndex)
                    let fallbackPath = (outputDirectory as NSString).appendingPathComponent(fallbackName)
                    let fallbackArgs = buildExtractArguments(
                        inputPath: inputPath,
                        timestamp: midpoint,
                        outputPath: fallbackPath,
                        config: config
                    )
                    _ = try? FFmpegBridge.run(arguments: fallbackArgs, config: ffmpegConfig)
                    if FileManager.default.fileExists(atPath: fallbackPath) {
                        frames.append(ExtractedFrame(
                            sceneIndex: sceneIndex,
                            timestamp: midpoint,
                            filePath: fallbackPath
                        ))
                    }
                }
            }
        }

        return frames
    }

    /// 异步关键帧提取（不阻塞 Swift 并发线程）
    public static func extractKeyframesAsync(
        inputPath: String,
        segments: [SceneSegment],
        outputDirectory: String,
        config: Config = .default,
        ffmpegConfig: FFmpegConfig = .default
    ) async throws -> [ExtractedFrame] {
        guard FileManager.default.fileExists(atPath: inputPath) else {
            throw FFmpegError.inputFileNotFound(path: inputPath)
        }

        try FileManager.default.createDirectory(
            atPath: outputDirectory,
            withIntermediateDirectories: true
        )

        var frames: [ExtractedFrame] = []

        for (sceneIndex, segment) in segments.enumerated() {
            let frameCount = framesPerScene(duration: segment.duration, config: config)
            let timestamps = frameTimestamps(segment: segment, frameCount: frameCount)
            guard !timestamps.isEmpty else { continue }

            if timestamps.count == 1 {
                let fileName = String(format: "scene_%03d_frame_%02d.jpg", sceneIndex, 0)
                let outputPath = (outputDirectory as NSString).appendingPathComponent(fileName)
                let args = buildExtractArguments(
                    inputPath: inputPath,
                    timestamp: timestamps[0],
                    outputPath: outputPath,
                    config: config
                )
                _ = try await FFmpegBridge.runAsync(arguments: args, config: ffmpegConfig)
                if FileManager.default.fileExists(atPath: outputPath) {
                    frames.append(ExtractedFrame(
                        sceneIndex: sceneIndex,
                        timestamp: timestamps[0],
                        filePath: outputPath
                    ))
                }
            } else {
                let outputPattern = (outputDirectory as NSString)
                    .appendingPathComponent(String(format: "scene_%03d_frame_%%02d.jpg", sceneIndex))
                let args = buildBatchExtractArguments(
                    inputPath: inputPath,
                    segment: segment,
                    timestamps: timestamps,
                    outputPattern: outputPattern,
                    config: config
                )
                _ = try await FFmpegBridge.runAsync(arguments: args, config: ffmpegConfig)

                var batchFrameCount = 0
                for (frameIndex, timestamp) in timestamps.enumerated() {
                    let fileName = String(format: "scene_%03d_frame_%02d.jpg", sceneIndex, frameIndex)
                    let outputPath = (outputDirectory as NSString).appendingPathComponent(fileName)
                    if FileManager.default.fileExists(atPath: outputPath) {
                        frames.append(ExtractedFrame(
                            sceneIndex: sceneIndex,
                            timestamp: timestamp,
                            filePath: outputPath
                        ))
                        batchFrameCount += 1
                    }
                }

                if batchFrameCount == 0 {
                    let midpoint = (segment.startTime + segment.endTime) / 2
                    let fallbackName = String(format: "scene_%03d_frame_00.jpg", sceneIndex)
                    let fallbackPath = (outputDirectory as NSString).appendingPathComponent(fallbackName)
                    let fallbackArgs = buildExtractArguments(
                        inputPath: inputPath,
                        timestamp: midpoint,
                        outputPath: fallbackPath,
                        config: config
                    )
                    _ = try? await FFmpegBridge.runAsync(arguments: fallbackArgs, config: ffmpegConfig)
                    if FileManager.default.fileExists(atPath: fallbackPath) {
                        frames.append(ExtractedFrame(
                            sceneIndex: sceneIndex,
                            timestamp: midpoint,
                            filePath: fallbackPath
                        ))
                    }
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
    /// - 15s 场景 → 3 帧（上限）
    /// - 45s 场景 → 3 帧（上限）
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

    /// 构建多帧批量提取的 FFmpeg 命令参数
    ///
    /// 使用 `-ss`/`-to` 限定场景范围，`select` 滤镜按时间戳选帧，
    /// 单次 FFmpeg 调用输出场景内所有关键帧。
    /// 输出文件名通过 `%02d` 自动编号（从 00 开始）。
    static func buildBatchExtractArguments(
        inputPath: String,
        segment: SceneSegment,
        timestamps: [Double],
        outputPattern: String,
        config: Config
    ) -> [String] {
        let edge = config.thumbnailShortEdge
        let scaleFilter = "scale='if(lt(iw,ih),\(edge),-2)':'if(lt(iw,ih),-2,\(edge))'"

        // 构建 select 表达式：对每个目标时间戳选取最近的帧
        // 注意: -ss 作为输入选项会将流时间戳重置为 ~0，
        // 因此 select 中必须使用相对于 segment.startTime 的时间戳
        // select='lt(abs(t-T0),0.05)+lt(abs(t-T1),0.05)+...'
        let selectParts = timestamps.map { t in
            let relativeT = t - segment.startTime
            return String(format: "lt(abs(t-%.3f)\\,0.05)", relativeT)
        }
        let selectExpr = selectParts.joined(separator: "+")

        return [
            "-ss", String(format: "%.3f", segment.startTime),
            "-to", String(format: "%.3f", segment.endTime),
            "-i", inputPath,
            "-vf", "select='\(selectExpr)',\(scaleFilter)",
            "-fps_mode", "vfr",
            "-q:v", String(config.jpegQuality),
            "-y",
            outputPattern
        ]
    }
}
