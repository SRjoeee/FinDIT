import Foundation
import WhisperKit

// MARK: - TranscriptSegment

/// 转录片段（项目内部类型，不依赖 WhisperKit）
///
/// 表示一段带时间戳的转录文本，用于 SRT 生成和 Clip 映射。
public struct TranscriptSegment: Equatable {
    /// 片段序号（1-based，用于 SRT 编号）
    public let index: Int
    /// 起始时间（秒）
    public let startTime: Double
    /// 结束时间（秒）
    public let endTime: Double
    /// 转录文本
    public let text: String

    /// 片段时长（秒）
    public var duration: Double { endTime - startTime }

    public init(index: Int, startTime: Double, endTime: Double, text: String) {
        self.index = index
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

// MARK: - STTError

/// STT 相关错误
public enum STTError: LocalizedError {
    /// WhisperKit 模型加载失败
    case modelLoadFailed(detail: String)
    /// 音频文件不存在
    case audioFileNotFound(path: String)
    /// 转录结果为空
    case emptyTranscription
    /// SRT 文件写入失败
    case srtWriteFailed(path: String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let detail):
            return "WhisperKit 模型加载失败: \(detail)"
        case .audioFileNotFound(let path):
            return "音频文件不存在: \(path)"
        case .emptyTranscription:
            return "转录结果为空"
        case .srtWriteFailed(let path, let underlying):
            return "SRT 文件写入失败 \(path): \(underlying.localizedDescription)"
        }
    }
}

// MARK: - STTProcessor

/// 语音转文字处理器
///
/// 提供 SRT 字幕生成/解析、路径解析、转录文本到场景片段的映射等纯函数。
/// WhisperKit 依赖的异步方法在后续步骤中添加。
public enum STTProcessor {

    /// STT 配置
    public struct Config {
        /// WhisperKit 模型名称
        public var modelName: String
        /// 语言提示（nil = 自动检测）
        public var language: String?
        /// 是否启用 word-level 时间戳
        public var wordTimestamps: Bool

        public static let `default` = Config(
            modelName: "large-v3",
            language: nil,
            wordTimestamps: true
        )

        public init(
            modelName: String = "large-v3",
            language: String? = nil,
            wordTimestamps: Bool = true
        ) {
            self.modelName = modelName
            self.language = language
            self.wordTimestamps = wordTimestamps
        }
    }

    // MARK: - WhisperKit 异步方法

    /// 初始化 WhisperKit 实例并加载模型
    ///
    /// 首次调用会下载模型文件（large-v3 约 1.5GB）。
    /// 调用方应创建一次实例并复用于多次转录。
    ///
    /// - Parameter config: STT 配置
    /// - Returns: 已初始化的 WhisperKit 实例
    public static func initializeWhisperKit(config: Config = .default) async throws -> WhisperKit {
        do {
            let whisperConfig = WhisperKitConfig(
                model: config.modelName,
                verbose: false,
                logLevel: .error
            )
            return try await WhisperKit(whisperConfig)
        } catch {
            throw STTError.modelLoadFailed(detail: error.localizedDescription)
        }
    }

    /// 转录音频文件
    ///
    /// - Parameters:
    ///   - audioPath: WAV 音频文件路径（建议 16kHz mono）
    ///   - whisperKit: 已初始化的 WhisperKit 实例
    ///   - config: STT 配置
    /// - Returns: 转录片段数组
    public static func transcribe(
        audioPath: String,
        whisperKit: WhisperKit,
        config: Config = .default
    ) async throws -> [TranscriptSegment] {
        guard FileManager.default.fileExists(atPath: audioPath) else {
            throw STTError.audioFileNotFound(path: audioPath)
        }

        let options = DecodingOptions(
            language: config.language,
            wordTimestamps: config.wordTimestamps
        )

        let results = try await whisperKit.transcribe(
            audioPath: audioPath,
            decodeOptions: options
        )

        guard let result = results.first, !result.segments.isEmpty else {
            throw STTError.emptyTranscription
        }

        return convertSegments(result.segments)
    }

    /// 完整流水线：转录音频 → 生成 SRT → 保存文件
    ///
    /// - Parameters:
    ///   - audioPath: WAV 音频路径
    ///   - videoPath: 原始视频路径（用于 SRT 路径解析）
    ///   - whisperKit: 已初始化的 WhisperKit 实例
    ///   - config: STT 配置
    /// - Returns: (segments: 转录片段, srtPath: SRT 文件实际路径)
    public static func transcribeAndSaveSRT(
        audioPath: String,
        videoPath: String,
        whisperKit: WhisperKit,
        config: Config = .default
    ) async throws -> (segments: [TranscriptSegment], srtPath: String) {
        let segments = try await transcribe(
            audioPath: audioPath,
            whisperKit: whisperKit,
            config: config
        )

        let srtContent = generateSRT(from: segments)
        let srtPath = try writeSRT(content: srtContent, videoPath: videoPath)

        return (segments, srtPath)
    }

    /// 将 WhisperKit TranscriptionSegment 转换为内部 TranscriptSegment
    ///
    /// 过滤空白段，分配 1-based 索引。
    static func convertSegments(_ whisperSegments: [TranscriptionSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var index = 1

        for seg in whisperSegments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            result.append(TranscriptSegment(
                index: index,
                startTime: Double(seg.start),
                endTime: Double(seg.end),
                text: text
            ))
            index += 1
        }

        return result
    }

    // MARK: - SRT 时间戳格式化

    /// 将秒数格式化为 SRT 时间戳: "HH:MM:SS,mmm"
    ///
    /// - Parameter seconds: 时间（秒），负值会被钳位到 0
    /// - Returns: 格式化字符串，如 "01:02:03,456"
    static func formatSRTTimestamp(_ seconds: Double) -> String {
        let totalSeconds = max(0, seconds)
        let hours = Int(totalSeconds) / 3600
        let minutes = (Int(totalSeconds) % 3600) / 60
        let secs = Int(totalSeconds) % 60
        let millis = Int((totalSeconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }

    /// 解析 SRT 时间戳 "HH:MM:SS,mmm" 为秒数
    ///
    /// - Parameter timestamp: SRT 时间戳字符串
    /// - Returns: 秒数，格式不合法返回 nil
    static func parseSRTTimestamp(_ timestamp: String) -> Double? {
        let cleaned = timestamp.trimmingCharacters(in: .whitespaces)
        let parts = cleaned.components(separatedBy: ",")
        guard parts.count == 2,
              let millis = Int(parts[1]) else { return nil }

        let timeParts = parts[0].components(separatedBy: ":")
        guard timeParts.count == 3,
              let hours = Double(timeParts[0]),
              let minutes = Double(timeParts[1]),
              let seconds = Double(timeParts[2]) else { return nil }

        return hours * 3600 + minutes * 60 + seconds + Double(millis) / 1000.0
    }

    // MARK: - SRT 生成与解析

    /// 从转录片段生成 SRT 字幕内容
    ///
    /// 输出格式:
    /// ```
    /// 1
    /// 00:00:00,000 --> 00:00:05,500
    /// First subtitle text
    ///
    /// 2
    /// 00:00:05,500 --> 00:00:12,000
    /// Second subtitle text
    /// ```
    ///
    /// - Parameter segments: 转录片段数组
    /// - Returns: SRT 格式字符串
    static func generateSRT(from segments: [TranscriptSegment]) -> String {
        guard !segments.isEmpty else { return "" }

        var lines: [String] = []

        for (i, segment) in segments.enumerated() {
            let index = i + 1
            let start = formatSRTTimestamp(segment.startTime)
            let end = formatSRTTimestamp(segment.endTime)

            lines.append("\(index)")
            lines.append("\(start) --> \(end)")
            lines.append(segment.text)
            lines.append("") // 空行分隔
        }

        return lines.joined(separator: "\n")
    }

    /// 解析 SRT 字幕内容为转录片段
    ///
    /// 容忍末尾缺少空行、多余空白等常见格式偏差。
    ///
    /// - Parameter srtContent: SRT 格式字符串
    /// - Returns: 转录片段数组
    static func parseSRT(_ srtContent: String) -> [TranscriptSegment] {
        let blocks = srtContent
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var segments: [TranscriptSegment] = []

        for block in blocks {
            let lines = block
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")

            guard lines.count >= 3,
                  let index = Int(lines[0].trimmingCharacters(in: .whitespaces)) else {
                continue
            }

            let timeLine = lines[1]
            let timeParts = timeLine.components(separatedBy: " --> ")
            guard timeParts.count == 2,
                  let startTime = parseSRTTimestamp(timeParts[0]),
                  let endTime = parseSRTTimestamp(timeParts[1]) else {
                continue
            }

            let text = lines[2...].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            segments.append(TranscriptSegment(
                index: index,
                startTime: startTime,
                endTime: endTime,
                text: text
            ))
        }

        return segments
    }

    // MARK: - SRT 路径解析（ADR-012）

    /// 解析 SRT 文件路径，按 ADR-012 降级策略
    ///
    /// 优先级 1: `<视频目录>/<视频名>.srt`
    /// 优先级 2: `~/Library/Application Support/FindIt/srt/<hash>.srt`
    ///
    /// - Parameter videoPath: 视频文件绝对路径
    /// - Returns: (primary: 首选路径, fallback: 降级路径)
    static func resolveSRTPath(videoPath: String) -> (primary: String, fallback: String) {
        let videoURL = URL(fileURLWithPath: videoPath)
        let videoName = videoURL.deletingPathExtension().lastPathComponent
        let videoDir = videoURL.deletingLastPathComponent().path

        let primary = (videoDir as NSString).appendingPathComponent("\(videoName).srt")

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("FindIt/srt")

        // 用视频路径的简单 hash 作为文件名
        let pathHash = stableHash(videoPath)
        let fallback = appSupport.appendingPathComponent("\(pathHash).srt").path

        return (primary, fallback)
    }

    /// 写入 SRT 文件，遵循 ADR-012 降级策略
    ///
    /// 先尝试写入视频同目录，失败后降级到 App Support 目录。
    ///
    /// - Parameters:
    ///   - content: SRT 内容
    ///   - videoPath: 原始视频路径（用于路径解析）
    /// - Returns: 实际写入的路径
    static func writeSRT(content: String, videoPath: String) throws -> String {
        let paths = resolveSRTPath(videoPath: videoPath)

        // 尝试首选路径
        do {
            try content.write(toFile: paths.primary, atomically: true, encoding: .utf8)
            return paths.primary
        } catch {
            // 首选路径写入失败（只读卷、权限等），尝试降级
        }

        // 降级路径
        do {
            let fallbackDir = (paths.fallback as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: fallbackDir,
                withIntermediateDirectories: true
            )
            try content.write(toFile: paths.fallback, atomically: true, encoding: .utf8)
            return paths.fallback
        } catch {
            throw STTError.srtWriteFailed(path: paths.fallback, underlying: error)
        }
    }

    // MARK: - 转录文本映射到场景片段

    /// 将转录文本按时间重叠映射到场景片段
    ///
    /// 对每个场景片段，收集所有时间范围与其重叠的转录片段文本，
    /// 拼接为一个字符串。
    ///
    /// 重叠判定: `transcript.startTime < scene.endTime && transcript.endTime > scene.startTime`
    ///
    /// - Parameters:
    ///   - transcriptSegments: 转录片段数组
    ///   - sceneSegments: 场景片段数组（来自 SceneDetector）
    /// - Returns: 每个场景对应的转录文本，无重叠则为 nil
    static func mapTranscriptToClips(
        transcriptSegments: [TranscriptSegment],
        sceneSegments: [SceneSegment]
    ) -> [String?] {
        sceneSegments.map { scene in
            let overlapping = transcriptSegments.filter { transcript in
                transcript.startTime < scene.endTime && transcript.endTime > scene.startTime
            }

            guard !overlapping.isEmpty else { return nil }

            let combined = overlapping.map(\.text).joined(separator: " ")
            let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    // MARK: - Internal

    /// 稳定的字符串 hash（djb2 算法），用于生成降级路径文件名
    static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return String(format: "%016llx", hash)
    }
}
