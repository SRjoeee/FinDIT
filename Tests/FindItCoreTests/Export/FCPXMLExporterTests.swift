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
        XCTAssertTrue(xml.contains("frameDuration=\"1/24s\""))
    }

    func testFrameDuration25fps() {
        let options = FCPXMLExporter.Options(fps: 25)
        let xml = FCPXMLExporter.generate(clips: [makeResult()], options: options)
        XCTAssertTrue(xml.contains("frameDuration=\"1/25s\""))
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
        XCTAssertTrue(xml.contains("src=\"file:///media/beach.mov\""))
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

        // start=10s at 24fps = 240/24s
        XCTAssertTrue(xml.contains("start=\"240/24s\""))
        // duration=5s at 24fps = 120/24s
        XCTAssertTrue(xml.contains("duration=\"120/24s\""))
        // offset=0 for first clip
        XCTAssertTrue(xml.contains("offset=\"0/24s\""))
    }

    func testMultipleClipOffsets() {
        let clips = [
            makeResult(clipId: 1, startTime: 0, endTime: 5),
            makeResult(clipId: 2, startTime: 10, endTime: 15),
        ]
        let options = FCPXMLExporter.Options(fps: 24)
        let xml = FCPXMLExporter.generate(clips: clips, options: options)

        // Second clip offset should be 5s = 120/24s
        let lines = xml.components(separatedBy: "\n")
        let assetClipLines = lines.filter { $0.contains("<asset-clip") }
        XCTAssertEqual(assetClipLines.count, 2)
        XCTAssertTrue(assetClipLines[1].contains("offset=\"120/24s\""))
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
        let result = FCPXMLExporter.rationalTime(seconds: 5.0, fps: 24, denominator: 24000)
        XCTAssertEqual(result, "120/24s")
    }

    func testRationalTimeZero() {
        let result = FCPXMLExporter.rationalTime(seconds: 0, fps: 24, denominator: 24000)
        XCTAssertEqual(result, "0/24s")
    }

    func testRationalTime25fps() {
        let result = FCPXMLExporter.rationalTime(seconds: 2.0, fps: 25, denominator: 25000)
        XCTAssertEqual(result, "50/25s")
    }

    func testFpsDenominator() {
        XCTAssertEqual(FCPXMLExporter.fpsDenominator(24), 24000)
        XCTAssertEqual(FCPXMLExporter.fpsDenominator(25), 25000)
        XCTAssertEqual(FCPXMLExporter.fpsDenominator(30), 30000)
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

    // MARK: - Total duration

    func testTotalDurationInSequence() {
        let clips = [
            makeResult(clipId: 1, startTime: 0, endTime: 10),  // 10s
            makeResult(clipId: 2, startTime: 5, endTime: 8),   // 3s
        ]
        let options = FCPXMLExporter.Options(fps: 24)
        let xml = FCPXMLExporter.generate(clips: clips, options: options)

        // Total duration = 10 + 3 = 13s = 312 frames at 24fps
        XCTAssertTrue(xml.contains("duration=\"312/24s\""))
    }
}
