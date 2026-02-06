import XCTest
@testable import FindItCore

final class PipelineManagerTests: XCTestCase {

    // MARK: - Stage

    func testStageRawValues() {
        XCTAssertEqual(PipelineManager.Stage.pending.rawValue, "pending")
        XCTAssertEqual(PipelineManager.Stage.sttRunning.rawValue, "stt_running")
        XCTAssertEqual(PipelineManager.Stage.sttDone.rawValue, "stt_done")
        XCTAssertEqual(PipelineManager.Stage.visionRunning.rawValue, "vision_running")
        XCTAssertEqual(PipelineManager.Stage.completed.rawValue, "completed")
        XCTAssertEqual(PipelineManager.Stage.failed.rawValue, "failed")
    }

    func testStageOrdering() {
        let pending = PipelineManager.Stage.pending
        let sttRunning = PipelineManager.Stage.sttRunning
        let sttDone = PipelineManager.Stage.sttDone
        let visionRunning = PipelineManager.Stage.visionRunning
        let completed = PipelineManager.Stage.completed

        XCTAssertTrue(pending.isBefore(sttRunning))
        XCTAssertTrue(sttRunning.isBefore(sttDone))
        XCTAssertTrue(sttDone.isBefore(visionRunning))
        XCTAssertTrue(visionRunning.isBefore(completed))
        XCTAssertFalse(completed.isBefore(pending))
        XCTAssertFalse(sttDone.isBefore(sttDone))
    }

    func testStageFailedOrder() {
        // failed 的 order 为 -1，应早于所有正常阶段
        let failed = PipelineManager.Stage.failed
        XCTAssertTrue(failed.isBefore(.pending))
        XCTAssertTrue(failed.isBefore(.completed))
    }

    // MARK: - thumbnailDirectory

    func testThumbnailDirectory() {
        let dir = PipelineManager.thumbnailDirectory(folderPath: "/Volumes/SSD/素材", videoId: 42)
        XCTAssertEqual(dir, "/Volumes/SSD/素材/.clip-index/thumbnails/video_42")
    }

    // MARK: - tmpDirectory

    func testTmpDirectory() {
        let dir = PipelineManager.tmpDirectory(folderPath: "/Volumes/SSD/素材")
        XCTAssertEqual(dir, "/Volumes/SSD/素材/.clip-index/tmp")
    }

    // MARK: - groupFramesByScene

    func testGroupFramesBySceneEmpty() {
        let groups = PipelineManager.groupFramesByScene(frames: [], sceneCount: 3)
        XCTAssertEqual(groups.count, 3)
        XCTAssertTrue(groups.allSatisfy { $0.isEmpty })
    }

    func testGroupFramesByScene() {
        let frames = [
            KeyframeExtractor.ExtractedFrame(sceneIndex: 0, timestamp: 1.0, filePath: "/a.jpg"),
            KeyframeExtractor.ExtractedFrame(sceneIndex: 0, timestamp: 2.0, filePath: "/b.jpg"),
            KeyframeExtractor.ExtractedFrame(sceneIndex: 1, timestamp: 5.0, filePath: "/c.jpg"),
            KeyframeExtractor.ExtractedFrame(sceneIndex: 2, timestamp: 10.0, filePath: "/d.jpg"),
        ]
        let groups = PipelineManager.groupFramesByScene(frames: frames, sceneCount: 3)
        XCTAssertEqual(groups[0], ["/a.jpg", "/b.jpg"])
        XCTAssertEqual(groups[1], ["/c.jpg"])
        XCTAssertEqual(groups[2], ["/d.jpg"])
    }

    func testGroupFramesBySceneOutOfBounds() {
        let frames = [
            KeyframeExtractor.ExtractedFrame(sceneIndex: 5, timestamp: 1.0, filePath: "/a.jpg"),
            KeyframeExtractor.ExtractedFrame(sceneIndex: -1, timestamp: 2.0, filePath: "/b.jpg"),
        ]
        let groups = PipelineManager.groupFramesByScene(frames: frames, sceneCount: 3)
        XCTAssertTrue(groups.allSatisfy { $0.isEmpty }, "越界帧应被忽略")
    }

    // MARK: - encodeJSONArray

    func testEncodeJSONArray() {
        let json = PipelineManager.encodeJSONArray(["海滩", "户外"])
        XCTAssertNotNil(json)
        XCTAssertTrue(json!.contains("海滩"))
        XCTAssertTrue(json!.contains("户外"))
    }

    func testEncodeJSONArrayEmpty() {
        XCTAssertNil(PipelineManager.encodeJSONArray([]))
    }

    // MARK: - selectThumbnail

    func testSelectThumbnail() {
        XCTAssertEqual(PipelineManager.selectThumbnail(from: ["/a.jpg", "/b.jpg"]), "/a.jpg")
        XCTAssertNil(PipelineManager.selectThumbnail(from: []))
    }
}
