import XCTest
@testable import FindItCore

final class FCPXMLExporterTests: XCTestCase {

    // MARK: - Helpers

    private func makeResult(
        clipId: Int64 = 1,
        filePath: String = "/media/beach.mov",
        fileName: String = "beach.mov",
        startTime: Double = 0,
        endTime: Double = 5,
        scene: String? = nil,
        clipDescription: String? = nil,
        subjects: String? = nil,
        tags: String? = nil,
        transcript: String? = nil
    ) -> SearchEngine.SearchResult {
        SearchEngine.SearchResult(
            clipId: clipId,
            sourceFolder: "/media",
            sourceClipId: 1,
            videoId: 1,
            filePath: filePath,
            fileName: fileName,
            startTime: startTime,
            endTime: endTime,
            scene: scene,
            clipDescription: clipDescription,
            subjects: subjects,
            actions: nil,
            objects: nil,
            tags: tags,
            transcript: transcript,
            thumbnailPath: nil,
            userTags: nil,
            rating: 0,
            colorLabel: nil,
            shotType: nil,
            mood: nil,
            lighting: nil,
            colors: nil,
            rank: 0,
            similarity: nil,
            finalScore: nil
        )
    }

    // MARK: - XML 结构

    func testXMLHeader() {
        let xml = FCPXMLExporter.generate(clips: [])
        XCTAssertTrue(xml.contains("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertTrue(xml.contains("<!DOCTYPE fcpxml>"))
        XCTAssertTrue(xml.contains("<fcpxml version=\"1.11\">"))
        XCTAssertTrue(xml.contains("name=\"FFVideoFormat1080p24\""))
    }

    func testEmptyClipsStructure() {
        let xml = FCPXMLExporter.generate(clips: [])
        XCTAssertTrue(xml.contains("<resources>"))
        XCTAssertTrue(xml.contains("<library>"))
        XCTAssertTrue(xml.contains("<spine>"))
        XCTAssertTrue(xml.contains("</fcpxml>"))
    }

    func testProjectName() {
        let options = FCPXMLExporter.Options(projectName: "My Video")
        let xml = FCPXMLExporter.generate(clips: [], options: options)
        XCTAssertTrue(xml.contains("name=\"My Video\""))
    }

    // MARK: - Format / Frame Duration

    func testFrameDuration24fps() {
        let options = FCPXMLExporter.Options(fps: 24)
        let xml = FCPXMLExporter.generate(clips: [makeResult()], options: options)
        XCTAssertTrue(xml.contains("frameDuration=\"100/2400s\""))
    }

    func testFrameDuration25fps() {
        let options = FCPXMLExporter.Options(fps: 25)
        let xml = FCPXMLExporter.generate(clips: [makeResult()], options: options)
        XCTAssertTrue(xml.contains("frameDuration=\"100/2500s\""))
    }

    func testFrameDuration2997fps() {
        let options = FCPXMLExporter.Options(fps: 29.97)
        let xml = FCPXMLExporter.generate(clips: [makeResult()], options: options)
        XCTAssertTrue(xml.contains("frameDuration=\"1001/30000s\""))
    }

    func testFrameDuration23976fps() {
        let dur = FCPXMLExporter.frameDuration(fps: 23.976)
        XCTAssertEqual(dur, "1001/24000s")
    }

    func testFrameDuration5994fps() {
        let dur = FCPXMLExporter.frameDuration(fps: 59.94)
        XCTAssertEqual(dur, "1001/60000s")
    }

    // MARK: - Assets

    func testSingleAsset() {
        let clip = makeResult(filePath: "/media/beach.mov", fileName: "beach.mov")
        let xml = FCPXMLExporter.generate(clips: [clip])

        XCTAssertTrue(xml.contains("<asset id=\"a1\""))
        XCTAssertTrue(xml.contains("name=\"beach.mov\""))
        XCTAssertTrue(xml.contains("<media-rep kind=\"original-media\" src=\"file:///media/beach.mov\"/>"))
    }

    func testAssetDeduplication() {
        let clips = [
            makeResult(clipId: 1, filePath: "/media/beach.mov", startTime: 0, endTime: 5),
            makeResult(clipId: 2, filePath: "/media/beach.mov", startTime: 5, endTime: 10),
            makeResult(clipId: 3, filePath: "/media/forest.mov", fileName: "forest.mov", startTime: 0, endTime: 8),
        ]
        let xml = FCPXMLExporter.generate(clips: clips)

        // Should have exactly 2 assets (beach + forest), not 3
        let assetCount = xml.components(separatedBy: "<asset id=").count - 1
        XCTAssertEqual(assetCount, 2)
    }

    // MARK: - Clip elements

    func testAssetClipAttributes() {
        let clip = makeResult(startTime: 10, endTime: 15)
        let options = FCPXMLExporter.Options(fps: 24)
        let xml = FCPXMLExporter.generate(clips: [clip], options: options)

        // start=10s at 24fps = 24000/2400s (Apple convention)
        XCTAssertTrue(xml.contains("start=\"24000/2400s\""))
        // duration=5s at 24fps = 12000/2400s
        XCTAssertTrue(xml.contains("duration=\"12000/2400s\""))
        // offset=0 for first clip
        XCTAssertTrue(xml.contains("offset=\"0/2400s\""))
    }

    func testMultipleClipOffsets() {
        let clips = [
            makeResult(clipId: 1, startTime: 0, endTime: 5),
            makeResult(clipId: 2, startTime: 10, endTime: 15),
        ]
        let options = FCPXMLExporter.Options(fps: 24)
        let xml = FCPXMLExporter.generate(clips: clips, options: options)

        // Second clip offset should be 5s = 12000/2400s (Apple convention)
        let lines = xml.components(separatedBy: "\n")
        let assetClipLines = lines.filter { $0.contains("<asset-clip") }
        XCTAssertEqual(assetClipLines.count, 2)
        XCTAssertTrue(assetClipLines[1].contains("offset=\"12000/2400s\""))
    }

    // MARK: - Keywords

    func testKeywordsFromTags() {
        let clip = makeResult(tags: "[\"beach\",\"sunset\",\"outdoor\"]")
        let options = FCPXMLExporter.Options(includeKeywords: true)
        let xml = FCPXMLExporter.generate(clips: [clip], options: options)

        XCTAssertTrue(xml.contains("<keyword"))
        XCTAssertTrue(xml.contains("beach, sunset, outdoor"))
    }

    func testKeywordsExcluded() {
        let clip = makeResult(tags: "[\"beach\"]")
        let options = FCPXMLExporter.Options(includeKeywords: false)
        let xml = FCPXMLExporter.generate(clips: [clip], options: options)

        XCTAssertFalse(xml.contains("<keyword"))
    }

    func testEmptyTagsNoKeyword() {
        let clip = makeResult(tags: "[]")
        let xml = FCPXMLExporter.generate(clips: [clip])
        XCTAssertFalse(xml.contains("<keyword"))
    }

    // MARK: - Notes

    func testNoteFromMetadata() {
        let clip = makeResult(
            scene: "beach",
            clipDescription: "A sunset over the ocean"
        )
        let options = FCPXMLExporter.Options(includeNotes: true)
        let xml = FCPXMLExporter.generate(clips: [clip], options: options)

        XCTAssertTrue(xml.contains("<note>"))
        XCTAssertTrue(xml.contains("A sunset over the ocean"))
        XCTAssertTrue(xml.contains("Scene: beach"))
    }

    func testNotesExcluded() {
        let clip = makeResult(clipDescription: "Something")
        let options = FCPXMLExporter.Options(includeNotes: false)
        let xml = FCPXMLExporter.generate(clips: [clip], options: options)

        XCTAssertFalse(xml.contains("<note>"))
    }

    // MARK: - XML 转义

    func testXMLEscape() {
        XCTAssertEqual(FCPXMLExporter.xmlEscape("a & b"), "a &amp; b")
        XCTAssertEqual(FCPXMLExporter.xmlEscape("<tag>"), "&lt;tag&gt;")
        XCTAssertEqual(FCPXMLExporter.xmlEscape("\"quoted\""), "&quot;quoted&quot;")
        XCTAssertEqual(FCPXMLExporter.xmlEscape("it's"), "it&apos;s")
    }

    func testXMLEscapeInOutput() {
        let clip = makeResult(fileName: "beach & sun.mov")
        let xml = FCPXMLExporter.generate(clips: [clip])
        XCTAssertTrue(xml.contains("beach &amp; sun.mov"))
        XCTAssertFalse(xml.contains("beach & sun.mov"))
    }

    // MARK: - Rational time helpers

    func testRationalTime24fps() {
        let result = FCPXMLExporter.rationalTime(seconds: 5.0, fps: 24, denominator: 2400)
        XCTAssertEqual(result, "12000/2400s")
    }

    func testRationalTimeZero() {
        let result = FCPXMLExporter.rationalTime(seconds: 0, fps: 24, denominator: 2400)
        XCTAssertEqual(result, "0/2400s")
    }

    func testRationalTime25fps() {
        let result = FCPXMLExporter.rationalTime(seconds: 2.0, fps: 25, denominator: 2500)
        XCTAssertEqual(result, "5000/2500s")
    }

    func testFpsDenominator() {
        XCTAssertEqual(FCPXMLExporter.fpsDenominator(24), 2400)
        XCTAssertEqual(FCPXMLExporter.fpsDenominator(25), 2500)
        XCTAssertEqual(FCPXMLExporter.fpsDenominator(30), 3000)
        XCTAssertEqual(FCPXMLExporter.fpsDenominator(29.97), 30000)
        XCTAssertEqual(FCPXMLExporter.fpsDenominator(59.94), 60000)
    }

    // MARK: - JSON 解析

    func testParseJSONArray() {
        let result = FCPXMLExporter.parseJSONArray("[\"a\",\"b\",\"c\"]")
        XCTAssertEqual(result, ["a", "b", "c"])
    }

    func testParseJSONArrayEmpty() {
        let result = FCPXMLExporter.parseJSONArray("[]")
        XCTAssertEqual(result, [])
    }

    func testParseJSONArrayInvalid() {
        let result = FCPXMLExporter.parseJSONArray("not json")
        XCTAssertEqual(result, [])
    }

    // MARK: - buildNote

    func testBuildNoteEmpty() {
        let clip = makeResult()
        let note = FCPXMLExporter.buildNote(clip)
        XCTAssertTrue(note.isEmpty)
    }

    func testBuildNoteWithAll() {
        let clip = makeResult(
            scene: "outdoor",
            clipDescription: "A walk in the park",
            subjects: "[\"person\"]",
            transcript: "Hello there"
        )
        let note = FCPXMLExporter.buildNote(clip)
        XCTAssertTrue(note.contains("A walk in the park"))
        XCTAssertTrue(note.contains("Scene: outdoor"))
        XCTAssertTrue(note.contains("Subjects: person"))
        XCTAssertTrue(note.contains("Transcript: Hello there"))
    }

    func testBuildNoteTranscriptTruncated() {
        let longTranscript = String(repeating: "x", count: 300)
        let clip = makeResult(transcript: longTranscript)
        let note = FCPXMLExporter.buildNote(clip)
        let transcriptPart = note.components(separatedBy: "Transcript: ").last ?? ""
        XCTAssertEqual(transcriptPart.count, 200)
    }

    // MARK: - File export

    func testExportToFile() throws {
        let clip = makeResult()
        let tmpPath = NSTemporaryDirectory() + "test_export_\(UUID().uuidString).fcpxml"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        try FCPXMLExporter.export(clips: [clip], to: tmpPath)

        let content = try String(contentsOfFile: tmpPath, encoding: .utf8)
        XCTAssertTrue(content.contains("<?xml"))
        XCTAssertTrue(content.contains("<fcpxml"))
    }

    // MARK: - RAW Format Detection

    func testIsRawVideoFormat() {
        XCTAssertTrue(FCPXMLExporter.isRawVideoFormat(fileName: "A001.R3D"))
        XCTAssertTrue(FCPXMLExporter.isRawVideoFormat(fileName: "shot.braw"))
        XCTAssertTrue(FCPXMLExporter.isRawVideoFormat(fileName: "frame.DNG"))
        XCTAssertTrue(FCPXMLExporter.isRawVideoFormat(fileName: "clip.nev"))
        XCTAssertFalse(FCPXMLExporter.isRawVideoFormat(fileName: "clip.mp4"))
        XCTAssertFalse(FCPXMLExporter.isRawVideoFormat(fileName: "clip.mov"))
    }

    func testR3DClipsIncludedInFCPXML() {
        let clips = [
            makeResult(clipId: 1, filePath: "/media/A001.R3D", fileName: "A001.R3D", startTime: 0, endTime: 5),
            makeResult(clipId: 2, filePath: "/media/beach.mp4", fileName: "beach.mp4", startTime: 0, endTime: 10),
        ]
        let xml = FCPXMLExporter.generate(clips: clips)

        // Both should be present
        XCTAssertTrue(xml.contains("A001.R3D"))
        XCTAssertTrue(xml.contains("beach.mp4"))
        // 2 assets
        let assetCount = xml.components(separatedBy: "<asset id=").count - 1
        XCTAssertEqual(assetCount, 2)
    }

    func testR3DAssetHasAudioEnabled() {
        let clip = makeResult(filePath: "/media/A001.R3D", fileName: "A001.R3D")
        let xml = FCPXMLExporter.generate(clips: [clip])
        // R3D cameras can record audio (up to 4ch), so hasAudio="1"
        XCTAssertTrue(xml.contains("hasAudio=\"1\""))
    }

    // MARK: - Asset start and duration

    func testAssetHasStartAndDuration() {
        let clip = makeResult(startTime: 2.0, endTime: 8.0)
        let xml = FCPXMLExporter.generate(clips: [clip], options: .init(fps: 24))
        // asset should have start="0s", format="r1"
        XCTAssertTrue(xml.contains("start=\"0s\""))
        XCTAssertTrue(xml.contains("format=\"r1\""))
        // asset duration should cover max endTime: 8s = 192 frames → 19200/2400s
        XCTAssertTrue(xml.contains("duration=\"19200/2400s\""))
    }

    func testAssetDurationCoversAllClips() {
        // Two clips from the same video: 0-5s and 10-20s
        let clips = [
            makeResult(clipId: 1, startTime: 0, endTime: 5),
            makeResult(clipId: 2, startTime: 10, endTime: 20),
        ]
        let xml = FCPXMLExporter.generate(clips: clips, options: .init(fps: 24))
        // Asset duration should be max(5, 20) = 20s = 480 frames → 48000/2400s
        XCTAssertTrue(xml.contains("duration=\"48000/2400s\""))
        // Only 1 asset (same filePath)
        let assetCount = xml.components(separatedBy: "<asset id=").count - 1
        XCTAssertEqual(assetCount, 1)
    }

    // MARK: - Sequence attributes

    func testSequenceAttributes() {
        let clip = makeResult()
        let xml = FCPXMLExporter.generate(clips: [clip])
        XCTAssertTrue(xml.contains("tcStart=\"0s\""))
        XCTAssertTrue(xml.contains("audioLayout=\"stereo\""))
        XCTAssertTrue(xml.contains("audioRate=\"48k\""))
    }

    // MARK: - Total duration

    func testTotalDurationInSequence() {
        let clips = [
            makeResult(clipId: 1, startTime: 0, endTime: 10),  // 10s
            makeResult(clipId: 2, startTime: 5, endTime: 8),   // 3s
        ]
        let options = FCPXMLExporter.Options(fps: 24)
        let xml = FCPXMLExporter.generate(clips: clips, options: options)

        // Total duration = 10 + 3 = 13s = 312 frames × 100 = 31200/2400s
        XCTAssertTrue(xml.contains("duration=\"31200/2400s\""))
    }

    // MARK: - Per-source format (VideoInfo)

    func testPerSourceFormatElements() {
        let clips = [
            makeResult(clipId: 1, filePath: "/media/6k.r3d", fileName: "6k.r3d", startTime: 0, endTime: 10),
            makeResult(clipId: 2, filePath: "/media/4k.mp4", fileName: "4k.mp4", startTime: 0, endTime: 5),
        ]
        let videoFormats: [String: FCPXMLExporter.VideoInfo] = [
            "/media/6k.r3d": .init(width: 6144, height: 3240, fps: 24),
            "/media/4k.mp4": .init(width: 3840, height: 2160, fps: 23.976),
        ]
        let xml = FCPXMLExporter.generate(clips: clips, options: .init(fps: 24), videoFormats: videoFormats)

        // Per-source format elements should exist
        XCTAssertTrue(xml.contains("<format id=\"r_a1\""), "R3D per-source format missing")
        XCTAssertTrue(xml.contains("width=\"6144\""), "R3D width wrong")
        XCTAssertTrue(xml.contains("height=\"3240\""), "R3D height wrong")
        XCTAssertTrue(xml.contains("<format id=\"r_a2\""), "MP4 per-source format missing")
        XCTAssertTrue(xml.contains("width=\"3840\""), "MP4 width wrong")
        XCTAssertTrue(xml.contains("height=\"2160\""), "MP4 height wrong")

        // Assets should reference their per-source format
        XCTAssertTrue(xml.contains("format=\"r_a1\""), "R3D asset format ref wrong")
        XCTAssertTrue(xml.contains("format=\"r_a2\""), "MP4 asset format ref wrong")

        // Per-source format frameDuration should match source fps
        XCTAssertTrue(xml.contains("frameDuration=\"100/2400s\""), "24fps frameDuration wrong")
        XCTAssertTrue(xml.contains("frameDuration=\"1001/24000s\""), "23.976fps frameDuration wrong")
    }

    func testFallbackToSequenceFormat() {
        let clip = makeResult(filePath: "/media/clip.mov", fileName: "clip.mov")
        // No videoFormats → fallback to r1
        let xml = FCPXMLExporter.generate(clips: [clip], options: .init(fps: 24))

        // Asset should use r1 (sequence format)
        XCTAssertTrue(xml.contains("format=\"r1\""))
        // No per-source format elements (only r1)
        let formatCount = xml.components(separatedBy: "<format id=").count - 1
        XCTAssertEqual(formatCount, 1, "Should only have sequence format r1")
    }

    func testMixedFormatsPartialProbe() {
        let clips = [
            makeResult(clipId: 1, filePath: "/media/probed.mp4", fileName: "probed.mp4", startTime: 0, endTime: 5),
            makeResult(clipId: 2, filePath: "/media/unknown.mov", fileName: "unknown.mov", startTime: 0, endTime: 3),
        ]
        // Only first file has VideoInfo
        let videoFormats: [String: FCPXMLExporter.VideoInfo] = [
            "/media/probed.mp4": .init(width: 1920, height: 1080, fps: 29.97),
        ]
        let xml = FCPXMLExporter.generate(clips: clips, options: .init(fps: 24), videoFormats: videoFormats)

        // Probed file → per-source format
        XCTAssertTrue(xml.contains("<format id=\"r_a1\""))
        XCTAssertTrue(xml.contains("frameDuration=\"1001/30000s\""), "29.97fps frameDuration wrong")

        // Unknown file → fallback to r1
        // a2 should reference r1
        let lines = xml.components(separatedBy: "\n")
        let a2Line = lines.first { $0.contains("id=\"a2\"") }
        XCTAssertNotNil(a2Line)
        XCTAssertTrue(a2Line?.contains("format=\"r1\"") ?? false, "Unknown asset should use r1")

        // 2 format elements total (r1 + r_a1)
        let formatCount = xml.components(separatedBy: "<format id=").count - 1
        XCTAssertEqual(formatCount, 2)
    }
}
