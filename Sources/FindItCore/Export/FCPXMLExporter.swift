import Foundation

/// FCPXML 1.11 导出器
///
/// 生成 Final Cut Pro 兼容的 FCPXML 文件。
/// 搜索结果导出为一个 project 中的 sequence，每个 clip 作为 asset-clip。
/// 支持嵌入 keyword（来自 tags）和 note（来自 AI 元数据）。
public enum FCPXMLExporter {

    /// 导出选项
    public struct Options: Sendable {
        public var projectName: String
        public var fps: Double
        public var includeKeywords: Bool
        public var includeNotes: Bool

        public init(
            projectName: String = "FindIt Export",
            fps: Double = 24,
            includeKeywords: Bool = true,
            includeNotes: Bool = true
        ) {
            self.projectName = projectName
            self.fps = fps
            self.includeKeywords = includeKeywords
            self.includeNotes = includeNotes
        }
    }

    /// 生成 FCPXML 1.11 文本
    public static func generate(
        clips: [SearchEngine.SearchResult],
        options: Options = Options()
    ) -> String {
        let fps = options.fps
        let denom = fpsDenominator(fps)

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.11">
          <resources>
            <format id="r1" frameDuration="\(frameDuration(fps: fps))" width="1920" height="1080"/>

        """

        // Collect unique video files → assets
        var assetMap: [String: String] = [:]  // filePath → assetId
        var assetIndex = 1

        for clip in clips {
            guard let filePath = clip.filePath else { continue }
            if assetMap[filePath] == nil {
                let assetId = "a\(assetIndex)"
                assetMap[filePath] = assetId
                let escapedPath = xmlEscape(filePath)
                let fileName = clip.fileName.map(xmlEscape) ?? "unknown"
                xml += "    <asset id=\"\(assetId)\" name=\"\(fileName)\" src=\"file://\(escapedPath)\" hasVideo=\"1\" hasAudio=\"1\"/>\n"
                assetIndex += 1
            }
        }

        xml += "  </resources>\n"

        // Calculate total duration
        var totalDuration: Double = 0
        for clip in clips {
            totalDuration += clip.endTime - clip.startTime
        }

        let totalDurStr = rationalTime(seconds: totalDuration, fps: fps, denominator: denom)

        xml += """
          <library>
            <event name="\(xmlEscape(options.projectName))">
              <project name="\(xmlEscape(options.projectName))">
                <sequence format="r1" duration="\(totalDurStr)">
                  <spine>

        """

        // Emit clip elements
        var offset: Double = 0
        for clip in clips {
            guard let filePath = clip.filePath,
                  let assetId = assetMap[filePath] else { continue }

            let clipDuration = clip.endTime - clip.startTime
            let startStr = rationalTime(seconds: clip.startTime, fps: fps, denominator: denom)
            let durStr = rationalTime(seconds: clipDuration, fps: fps, denominator: denom)
            let offsetStr = rationalTime(seconds: offset, fps: fps, denominator: denom)
            let clipName = xmlEscape(clip.fileName ?? "clip")

            xml += "            <asset-clip ref=\"\(assetId)\" name=\"\(clipName)\" offset=\"\(offsetStr)\" start=\"\(startStr)\" duration=\"\(durStr)\">\n"

            // Keywords from tags
            if options.includeKeywords, let tags = clip.tags, !tags.isEmpty, tags != "[]" {
                let tagList = parseJSONArray(tags).joined(separator: ", ")
                if !tagList.isEmpty {
                    xml += "              <keyword start=\"0/1s\" duration=\"\(durStr)\" value=\"\(xmlEscape(tagList))\"/>\n"
                }
            }

            // Note from metadata
            if options.includeNotes {
                let note = buildNote(clip)
                if !note.isEmpty {
                    xml += "              <note>\(xmlEscape(note))</note>\n"
                }
            }

            xml += "            </asset-clip>\n"
            offset += clipDuration
        }

        xml += """
                  </spine>
                </sequence>
              </project>
            </event>
          </library>
        </fcpxml>

        """

        return xml
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

    // MARK: - Time Helpers

    /// 是否为非整数帧率（29.97, 23.976, 59.94）
    private static func isNonIntegerFps(_ fps: Double) -> (Bool, kind: String) {
        let nominalFps = Int(round(fps))
        let diff = abs(fps - Double(nominalFps))
        if nominalFps == 30 && diff > 0.01 { return (true, "29.97") }
        if nominalFps == 24 && diff > 0.01 { return (true, "23.976") }
        if nominalFps == 60 && diff > 0.01 { return (true, "59.94") }
        return (false, "")
    }

    /// 帧率分母（24fps → 24000, 25fps → 25000, 29.97fps → 30000）
    static func fpsDenominator(_ fps: Double) -> Int {
        let (isNonInt, kind) = isNonIntegerFps(fps)
        if isNonInt {
            switch kind {
            case "29.97": return 30000
            case "23.976": return 24000
            case "59.94": return 60000
            default: break
            }
        }
        return Int(round(fps)) * 1000
    }

    /// 帧时长有理数（24fps → "1/24s", 29.97fps → "1001/30000s"）
    static func frameDuration(fps: Double) -> String {
        let (isNonInt, kind) = isNonIntegerFps(fps)
        if isNonInt {
            switch kind {
            case "29.97": return "1001/30000s"
            case "23.976": return "1001/24000s"
            case "59.94": return "1001/60000s"
            default: break
            }
        }
        let nominalFps = Int(round(fps))
        return "1/\(nominalFps)s"
    }

    /// 秒数转有理数时间字符串
    ///
    /// 如 5.5 秒 @ 24fps → "132/24s" (= 5.5 * 24 = 132 帧)
    static func rationalTime(seconds: Double, fps: Double, denominator: Int) -> String {
        let (isNonInt, _) = isNonIntegerFps(fps)
        if isNonInt {
            // For non-integer fps, use frame count / denominator
            let frames = Int(round(seconds * fps))
            let numerator = frames * (denominator / Int(round(fps)))
            return "\(numerator)/\(denominator)s"
        } else {
            // Integer fps: use simpler fraction
            let nominalFps = Int(round(fps))
            let frames = Int(round(seconds * Double(nominalFps)))
            return "\(frames)/\(nominalFps)s"
        }
    }

    // MARK: - XML Helpers

    /// XML 特殊字符转义
    static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// 解析 JSON 数组字符串为字符串数组
    static func parseJSONArray(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return array
    }

    /// 构建 note 文本
    static func buildNote(_ clip: SearchEngine.SearchResult) -> String {
        var parts: [String] = []

        if let desc = clip.clipDescription, !desc.isEmpty {
            parts.append(desc)
        }
        if let scene = clip.scene, !scene.isEmpty {
            parts.append("Scene: \(scene)")
        }
        if let subjects = clip.subjects, !subjects.isEmpty, subjects != "[]" {
            let list = parseJSONArray(subjects).joined(separator: ", ")
            if !list.isEmpty { parts.append("Subjects: \(list)") }
        }
        if let transcript = clip.transcript, !transcript.isEmpty {
            let truncated = String(transcript.prefix(200))
            parts.append("Transcript: \(truncated)")
        }

        return parts.joined(separator: " | ")
    }
}
