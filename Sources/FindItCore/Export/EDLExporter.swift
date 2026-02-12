import Foundation

/// CMX 3600 EDL 导出器
///
/// 生成标准 CMX 3600 格式的 Edit Decision List，兼容
/// DaVinci Resolve、Premiere Pro、Avid Media Composer 等主流 NLE。
///
/// 每个搜索结果生成一个事件（event），包含 source timecode
/// 和可选的 comment 行（嵌入 FindIt AI 元数据）。
public enum EDLExporter {

    /// Reel 命名策略
    public enum ReelNaming: Sendable {
        /// 文件名前 8 字符（大写，特殊字符替换为 _）
        case fileName8
        /// 顺序编号: REEL001, REEL002...
        case sequential
        /// 固定名称
        case fixed(String)
    }

    /// 导出选项
    public struct Options: Sendable {
        public var title: String
        public var fps: Double
        public var dropFrame: Bool
        public var includeComments: Bool
        public var reelNaming: ReelNaming

        public init(
            title: String = "FindIt Export",
            fps: Double = 24,
            dropFrame: Bool = false,
            includeComments: Bool = true,
            reelNaming: ReelNaming = .fileName8
        ) {
            self.title = title
            self.fps = fps
            self.dropFrame = dropFrame
            self.includeComments = includeComments
            self.reelNaming = reelNaming
        }
    }

    /// 生成 CMX 3600 EDL 文本
    ///
    /// - Parameters:
    ///   - clips: 搜索结果列表
    ///   - options: 导出选项
    /// - Returns: EDL 格式文本
    public static func generate(
        clips: [SearchEngine.SearchResult],
        options: Options = Options()
    ) -> String {
        var lines: [String] = []

        // Header
        lines.append("TITLE: \(options.title)")
        if options.dropFrame && Timecode.isDropFrameRate(options.fps) {
            lines.append("FCM: DROP FRAME")
        } else {
            lines.append("FCM: NON-DROP FRAME")
        }
        lines.append("")

        // Track record timecode (output timeline position)
        var recordOffset: Double = 0

        // CMX 3600 max 999 events
        let maxEvents = min(clips.count, 999)

        for i in 0..<maxEvents {
            let clip = clips[i]
            let eventNum = String(format: "%03d", i + 1)
            let reel = reelName(for: clip, index: i, naming: options.reelNaming)

            let sourceIn = Timecode(seconds: clip.startTime, fps: options.fps, dropFrame: options.dropFrame)
            let sourceOut = Timecode(seconds: clip.endTime, fps: options.fps, dropFrame: options.dropFrame)
            let duration = clip.endTime - clip.startTime
            let recordIn = Timecode(seconds: recordOffset, fps: options.fps, dropFrame: options.dropFrame)
            let recordOut = Timecode(seconds: recordOffset + duration, fps: options.fps, dropFrame: options.dropFrame)

            // Event line: EVENT REEL V/A C SOURCE_IN SOURCE_OUT RECORD_IN RECORD_OUT
            lines.append("\(eventNum)  \(reel) V     C        \(sourceIn) \(sourceOut) \(recordIn) \(recordOut)")

            // Comment lines
            if options.includeComments {
                if let fileName = clip.fileName {
                    lines.append("* FROM CLIP NAME: \(fileName)")
                }
                if let filePath = clip.filePath {
                    lines.append("* SOURCE FILE: \(filePath)")
                }

                let metadata = buildMetadataComment(clip)
                if !metadata.isEmpty {
                    lines.append("* COMMENT: \(metadata)")
                }

                if let transcript = clip.transcript, !transcript.isEmpty {
                    let truncated = String(transcript.prefix(120))
                    lines.append("* COMMENT: TRANSCRIPT: \(truncated)")
                }
            }

            lines.append("")
            recordOffset += duration
        }

        return lines.joined(separator: "\n")
    }

    /// 导出到文件
    public static func export(
        clips: [SearchEngine.SearchResult],
        to path: String,
        options: Options = Options()
    ) throws {
        let content = generate(clips: clips, options: options)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    /// 生成 reel 名称（最多 8 字符，大写）
    static func reelName(
        for clip: SearchEngine.SearchResult,
        index: Int,
        naming: ReelNaming
    ) -> String {
        switch naming {
        case .fileName8:
            guard let fileName = clip.fileName else {
                return String(format: "REEL%04d", index + 1)
            }
            let stem = (fileName as NSString).deletingPathExtension
            let sanitized = stem
                .replacingOccurrences(of: " ", with: "_")
                .unicodeScalars
                .filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
                .map { Character($0) }
            let name = String(sanitized.prefix(8)).uppercased()
            return name.isEmpty ? String(format: "REEL%04d", index + 1) : name.padding(toLength: 8, withPad: " ", startingAt: 0)

        case .sequential:
            return String(format: "REEL%04d", index + 1)

        case .fixed(let name):
            let truncated = String(name.prefix(8)).uppercased()
            return truncated.padding(toLength: 8, withPad: " ", startingAt: 0)
        }
    }

    /// 构建元数据 comment 字符串
    static func buildMetadataComment(_ clip: SearchEngine.SearchResult) -> String {
        var parts: [String] = []

        if let scene = clip.scene, !scene.isEmpty {
            parts.append("scene=\"\(scene)\"")
        }
        if let subjects = clip.subjects, !subjects.isEmpty, subjects != "[]" {
            parts.append("subjects=\(subjects)")
        }
        if let actions = clip.actions, !actions.isEmpty, actions != "[]" {
            parts.append("actions=\(actions)")
        }
        if let mood = clip.mood, !mood.isEmpty {
            parts.append("mood=\"\(mood)\"")
        }
        if let shotType = clip.shotType, !shotType.isEmpty {
            parts.append("shot_type=\"\(shotType)\"")
        }
        if let tags = clip.tags, !tags.isEmpty, tags != "[]" {
            parts.append("tags=\(tags)")
        }
        if clip.rating > 0 {
            parts.append("rating=\(clip.rating)")
        }
        if let colorLabel = clip.colorLabel, !colorLabel.isEmpty {
            parts.append("color=\"\(colorLabel)\"")
        }

        return parts.joined(separator: " ")
    }
}
