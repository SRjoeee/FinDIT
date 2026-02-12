import AVFoundation
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
        public var dropFrame: Bool

        public init(
            projectName: String = "FindIt Export",
            fps: Double = 24,
            includeKeywords: Bool = true,
            includeNotes: Bool = true,
            dropFrame: Bool = false
        ) {
            self.projectName = projectName
            self.fps = fps
            self.includeKeywords = includeKeywords
            self.includeNotes = includeNotes
            self.dropFrame = dropFrame
        }
    }

    /// 源视频元数据（分辨率 + 帧率）
    public struct VideoInfo: Sendable {
        public var width: Int
        public var height: Int
        public var fps: Double

        public init(width: Int, height: Int, fps: Double) {
            self.width = width
            self.height = height
            self.fps = fps
        }
    }

    /// 探测 clips 中各源文件的实际分辨率和帧率
    ///
    /// 优先使用 AVFoundation，失败时回退到 FFmpeg（支持 R3D 等 RAW 格式）。
    /// 无法探测的文件会被跳过（导出时回退到序列格式）。
    public static func probeVideoFormats(clips: [SearchEngine.SearchResult]) async -> [String: VideoInfo] {
        let uniquePaths = Set(clips.compactMap(\.filePath))
        var result: [String: VideoInfo] = [:]

        // Phase 1: AVFoundation 并行探测
        await withTaskGroup(of: (String, VideoInfo?).self) { group in
            for path in uniquePaths {
                group.addTask {
                    let url = URL(fileURLWithPath: path)
                    do {
                        let asset = AVURLAsset(url: url)
                        let tracks = try await asset.loadTracks(withMediaType: .video)
                        guard let track = tracks.first else { return (path, nil) }
                        let size = try await track.load(.naturalSize)
                        let fps = try await track.load(.nominalFrameRate)
                        guard size.width > 0, size.height > 0, fps > 0 else { return (path, nil) }
                        return (path, VideoInfo(
                            width: Int(size.width),
                            height: Int(size.height),
                            fps: Double(fps)
                        ))
                    } catch {
                        return (path, nil)
                    }
                }
            }

            for await (path, info) in group {
                if let info = info {
                    result[path] = info
                }
            }
        }

        // Phase 2: AVFoundation 失败的文件 → CompositeMediaService 回退
        // 自动选择最优解码器：R3D→r3d-tool, BRAW→braw-tool, 其他→FFmpeg
        let missingPaths = uniquePaths.filter { result[$0] == nil }
        if !missingPaths.isEmpty {
            let service = CompositeMediaService.makeDefault()
            for path in missingPaths {
                do {
                    let probeResult = try await service.probe(filePath: path)
                    if let res = probeResult.resolution, let fps = probeResult.fps {
                        result[path] = VideoInfo(width: res.width, height: res.height, fps: fps)
                    }
                } catch {
                    continue
                }
            }
        }

        return result
    }

    /// 生成 FCPXML 1.11 文本
    public static func generate(
        clips: [SearchEngine.SearchResult],
        options: Options = Options(),
        videoFormats: [String: VideoInfo] = [:]
    ) -> String {
        let fps = options.fps
        let denom = fpsDenominator(fps)

        let tcFormat = (options.dropFrame && isNonIntegerFps(fps).0) ? "DF" : "NDF"

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.11">
          <resources>
            <format id="r1" name="\(formatName(fps: fps))" frameDuration="\(frameDuration(fps: fps))" width="1920" height="1080"/>

        """

        // Phase 1: Collect unique source files
        struct AssetEntry {
            let id: String
            let fileName: String
            let filePath: String
        }
        var assetMap: [String: String] = [:]  // filePath → assetId
        var assetEntries: [AssetEntry] = []
        var assetIndex = 1

        for clip in clips {
            guard let filePath = clip.filePath else { continue }
            if assetMap[filePath] == nil {
                let assetId = "a\(assetIndex)"
                assetMap[filePath] = assetId
                assetEntries.append(AssetEntry(
                    id: assetId,
                    fileName: clip.fileName ?? "unknown",
                    filePath: filePath
                ))
                assetIndex += 1
            }
        }

        // Phase 2: Emit per-source <format> elements
        for entry in assetEntries {
            guard let info = videoFormats[entry.filePath] else { continue }
            let formatId = "r_\(entry.id)"
            xml += "    <format id=\"\(formatId)\" frameDuration=\"\(frameDuration(fps: info.fps))\" width=\"\(info.width)\" height=\"\(info.height)\"/>\n"
        }

        // Phase 3: Emit <asset> elements
        for entry in assetEntries {
            let formatId = videoFormats[entry.filePath] != nil ? "r_\(entry.id)" : "r1"
            let fileName = xmlEscape(entry.fileName)
            let fileURL = xmlEscape(URL(fileURLWithPath: entry.filePath).absoluteString)
            let maxEnd = clips.filter { $0.filePath == entry.filePath }.map(\.endTime).max() ?? 0
            let assetDur = rationalTime(seconds: maxEnd, fps: fps, denominator: denom)
            xml += "    <asset id=\"\(entry.id)\" name=\"\(fileName)\" start=\"0s\" duration=\"\(assetDur)\" hasVideo=\"1\" format=\"\(formatId)\" hasAudio=\"1\">\n"
            xml += "      <media-rep kind=\"original-media\" src=\"\(fileURL)\"/>\n"
            xml += "    </asset>\n"
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
                <sequence format="r1" duration="\(totalDurStr)" tcStart="0s" tcFormat="\(tcFormat)" audioLayout="stereo" audioRate="48k">
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
        options: Options = Options(),
        videoFormats: [String: VideoInfo] = [:]
    ) throws {
        let content = generate(clips: clips, options: options, videoFormats: videoFormats)
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

    /// 帧率分母（Apple 惯例: 24fps → 2400, 29.97fps → 30000）
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
        return Int(round(fps)) * 100
    }

    /// 帧时长有理数（Apple 惯例: 24fps → "100/2400s", 29.97fps → "1001/30000s"）
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
        let denom = Int(round(fps)) * 100
        return "100/\(denom)s"
    }

    /// 秒数转有理数时间字符串（Apple FCPXML 惯例）
    ///
    /// 如 5.0 秒 @ 24fps → "12000/2400s" (= 120 帧 × 100)
    static func rationalTime(seconds: Double, fps: Double, denominator: Int) -> String {
        let nominalFps = Int(round(fps))
        let frames = Int(round(seconds * Double(nominalFps)))
        let numerator = frames * (denominator / nominalFps)
        return "\(numerator)/\(denominator)s"
    }

    /// Apple 标准格式名（如 "FFVideoFormat1080p24"）
    static func formatName(fps: Double) -> String {
        let (isNonInt, kind) = isNonIntegerFps(fps)
        if isNonInt {
            switch kind {
            case "29.97": return "FFVideoFormat1080p2997"
            case "23.976": return "FFVideoFormat1080p2398"
            case "59.94": return "FFVideoFormat1080p5994"
            default: break
            }
        }
        let nominalFps = Int(round(fps))
        return "FFVideoFormat1080p\(nominalFps)"
    }

    // MARK: - RAW Format Detection

    /// RAW 视频格式扩展名（FCP FCPXML 导入存在已知 bug，Apple FB13563506）
    public static let rawVideoExtensions: Set<String> = ["r3d", "braw", "dng", "nev"]

    /// 判断是否为 RAW 视频格式
    public static func isRawVideoFormat(fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return rawVideoExtensions.contains(ext)
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
