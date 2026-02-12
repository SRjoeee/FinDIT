import XCTest
@testable import FindItCore

final class EDLExporterTests: XCTestCase {

    // MARK: - Helpers

    /// 构造测试用 SearchResult
    private func makeResult(
        clipId: Int64 = 1,
        filePath: String = "/media/beach.mov",
        fileName: String = "beach.mov",
        startTime: Double = 0,
        endTime: Double = 5,
        scene: String? = nil,
        subjects: String? = nil,
        actions: String? = nil,
        tags: String? = nil,
        transcript: String? = nil,
        mood: String? = nil,
        shotType: String? = nil,
        rating: Int = 0,
        colorLabel: String? = nil
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
            clipDescription: nil,
            subjects: subjects,
            actions: actions,
            objects: nil,
            tags: tags,
            transcript: transcript,
            thumbnailPath: nil,
            userTags: nil,
            rating: rating,
            colorLabel: colorLabel,
            shotType: shotType,
            mood: mood,
            lighting: nil,
            colors: nil,
            rank: 0,
            similarity: nil,
            finalScore: nil
        )
    }

    // MARK: - 基础生成

    func testEmptyClips() {
        let edl = EDLExporter.generate(clips: [])
        XCTAssertTrue(edl.contains("TITLE:"))
        XCTAssertTrue(edl.contains("FCM:"))
        // No events
        XCTAssertFalse(edl.contains("001"))
    }

    func testSingleClip() {
        let clip = makeResult(startTime: 10, endTime: 15)
        let edl = EDLExporter.generate(clips: [clip])

        // Should contain event 001
        XCTAssertTrue(edl.contains("001"))
        // Should contain V C (video, cut)
        XCTAssertTrue(edl.contains("V     C"))
    }

    func testMultipleClips() {
        let clips = [
            makeResult(clipId: 1, startTime: 0, endTime: 5),
            makeResult(clipId: 2, startTime: 10, endTime: 20),
            makeResult(clipId: 3, startTime: 30, endTime: 35),
        ]
        let edl = EDLExporter.generate(clips: clips)

        XCTAssertTrue(edl.contains("001"))
        XCTAssertTrue(edl.contains("002"))
        XCTAssertTrue(edl.contains("003"))
    }

    // MARK: - Header

    func testHeaderTitle() {
        let options = EDLExporter.Options(title: "My Project")
        let edl = EDLExporter.generate(clips: [], options: options)
        XCTAssertTrue(edl.contains("TITLE: My Project"))
    }

    func testNonDropFrameHeader() {
        let edl = EDLExporter.generate(clips: [], options: EDLExporter.Options(fps: 24))
        XCTAssertTrue(edl.contains("FCM: NON-DROP FRAME"))
    }

    func testDropFrameHeader() {
        let options = EDLExporter.Options(fps: 29.97, dropFrame: true)
        let edl = EDLExporter.generate(clips: [], options: options)
        XCTAssertTrue(edl.contains("FCM: DROP FRAME"))
    }

    func testDropFrameIgnoredForNonDropRate() {
        let options = EDLExporter.Options(fps: 24, dropFrame: true)
        let edl = EDLExporter.generate(clips: [], options: options)
        XCTAssertTrue(edl.contains("FCM: NON-DROP FRAME"))
    }

    // MARK: - Timecodes

    func testSourceTimecodes() {
        // Clip from 10s to 15s at 24fps
        // 10s = 00:00:10:00, 15s = 00:00:15:00
        let clip = makeResult(startTime: 10, endTime: 15)
        let edl = EDLExporter.generate(clips: [clip], options: EDLExporter.Options(fps: 24))

        XCTAssertTrue(edl.contains("00:00:10:00"))
        XCTAssertTrue(edl.contains("00:00:15:00"))
    }

    func testRecordTimecodeStartsAtZero() {
        let clip = makeResult(startTime: 60, endTime: 65)
        let edl = EDLExporter.generate(clips: [clip], options: EDLExporter.Options(fps: 24))

        // Record IN should be 00:00:00:00 for first clip
        let lines = edl.components(separatedBy: "\n")
        let eventLine = lines.first { $0.starts(with: "001") }
        XCTAssertNotNil(eventLine)
        // Record out should be 5s duration
        XCTAssertTrue(eventLine?.contains("00:00:05:00") ?? false)
    }

    // MARK: - Reel naming

    func testReelNameFileName8() {
        let clip = makeResult(fileName: "beach-footage.mov")
        let options = EDLExporter.Options(reelNaming: .fileName8)
        let edl = EDLExporter.generate(clips: [clip], options: options)

        // "beach-footage" → sanitized "BEACH_FO" (8 chars, uppercase, - removed)
        XCTAssertTrue(edl.contains("BEACH_FO") || edl.contains("BEACHFOO"))
    }

    func testReelNameSequential() {
        let clips = [
            makeResult(clipId: 1, fileName: "a.mov"),
            makeResult(clipId: 2, fileName: "b.mov"),
        ]
        let options = EDLExporter.Options(reelNaming: .sequential)
        let edl = EDLExporter.generate(clips: clips, options: options)

        XCTAssertTrue(edl.contains("REEL0001"))
        XCTAssertTrue(edl.contains("REEL0002"))
    }

    func testReelNameFixed() {
        let clip = makeResult()
        let options = EDLExporter.Options(reelNaming: .fixed("MYPROJ"))
        let edl = EDLExporter.generate(clips: [clip], options: options)

        XCTAssertTrue(edl.contains("MYPROJ"))
    }

    // MARK: - Comments

    func testCommentsIncluded() {
        let clip = makeResult(
            scene: "outdoor",
            transcript: "Hello world"
        )
        let options = EDLExporter.Options(includeComments: true)
        let edl = EDLExporter.generate(clips: [clip], options: options)

        XCTAssertTrue(edl.contains("* FROM CLIP NAME:"))
        XCTAssertTrue(edl.contains("* SOURCE FILE:"))
        XCTAssertTrue(edl.contains("* COMMENT:"))
    }

    func testCommentsExcluded() {
        let clip = makeResult(scene: "outdoor")
        let options = EDLExporter.Options(includeComments: false)
        let edl = EDLExporter.generate(clips: [clip], options: options)

        XCTAssertFalse(edl.contains("* FROM CLIP NAME:"))
        XCTAssertFalse(edl.contains("* COMMENT:"))
    }

    func testMetadataComment() {
        let clip = makeResult(
            scene: "beach",
            subjects: "[\"person\",\"dog\"]",
            mood: "happy",
            shotType: "wide"
        )
        let edl = EDLExporter.generate(clips: [clip])

        XCTAssertTrue(edl.contains("scene=\"beach\""))
        XCTAssertTrue(edl.contains("mood=\"happy\""))
        XCTAssertTrue(edl.contains("shot_type=\"wide\""))
    }

    func testTranscriptComment() {
        let clip = makeResult(transcript: "This is a test transcript")
        let edl = EDLExporter.generate(clips: [clip])

        XCTAssertTrue(edl.contains("TRANSCRIPT: This is a test"))
    }

    func testTranscriptTruncated() {
        let longTranscript = String(repeating: "a", count: 200)
        let clip = makeResult(transcript: longTranscript)
        let edl = EDLExporter.generate(clips: [clip])

        // Transcript should be truncated to 120 chars
        let transcriptLine = edl.components(separatedBy: "\n")
            .first { $0.contains("TRANSCRIPT:") }
        XCTAssertNotNil(transcriptLine)
        // The "TRANSCRIPT: " part + 120 chars
        let content = transcriptLine?.components(separatedBy: "TRANSCRIPT: ").last ?? ""
        XCTAssertEqual(content.count, 120)
    }

    // MARK: - 999 event limit

    func testMax999Events() {
        let clips = (0..<1005).map { i in
            makeResult(clipId: Int64(i), startTime: Double(i) * 5, endTime: Double(i) * 5 + 5)
        }
        let edl = EDLExporter.generate(clips: clips)

        XCTAssertTrue(edl.contains("999"))
        // Should not contain event 1000
        XCTAssertFalse(edl.components(separatedBy: "\n").contains { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("1000")
        })
    }

    // MARK: - File export

    func testExportToFile() throws {
        let clip = makeResult()
        let tmpPath = NSTemporaryDirectory() + "test_export_\(UUID().uuidString).edl"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        try EDLExporter.export(clips: [clip], to: tmpPath)

        let content = try String(contentsOfFile: tmpPath, encoding: .utf8)
        XCTAssertTrue(content.contains("TITLE:"))
        XCTAssertTrue(content.contains("001"))
    }

    // MARK: - buildMetadataComment

    func testBuildMetadataCommentEmpty() {
        let clip = makeResult()
        let comment = EDLExporter.buildMetadataComment(clip)
        XCTAssertTrue(comment.isEmpty)
    }

    func testBuildMetadataCommentWithRating() {
        let clip = makeResult(rating: 5)
        let comment = EDLExporter.buildMetadataComment(clip)
        XCTAssertTrue(comment.contains("rating=5"))
    }

    func testBuildMetadataCommentWithColorLabel() {
        let clip = makeResult(colorLabel: "red")
        let comment = EDLExporter.buildMetadataComment(clip)
        XCTAssertTrue(comment.contains("color=\"red\""))
    }
}
