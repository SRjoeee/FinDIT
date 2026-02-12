import XCTest
import GRDB
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

    // MARK: - cleanGlobalClipsForVideo

    func testCleanGlobalClipsForVideoRemovesOrphanClips() throws {
        let folderPath = "/test/folder"
        let folderDB = try DatabaseManager.makeFolderInMemoryDatabase()
        let globalDB = try DatabaseManager.makeGlobalInMemoryDatabase()

        // 1. 在文件夹库中创建 watched_folder + video + clips
        try folderDB.write { db in
            var folder = WatchedFolder(folderPath: folderPath)
            try folder.insert(db)
            var video = Video(
                folderId: folder.folderId,
                filePath: "\(folderPath)/test.mp4",
                fileName: "test.mp4"
            )
            try video.insert(db)
            for i in 0..<3 {
                var clip = Clip(
                    videoId: video.videoId,
                    startTime: Double(i * 5),
                    endTime: Double((i + 1) * 5),
                    scene: "scene\(i)"
                )
                try clip.insert(db)
            }
        }

        // 2. 同步到全局库
        let syncResult = try SyncEngine.sync(
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )
        XCTAssertEqual(syncResult.syncedClips, 3)

        // 3. 验证全局库有 3 个 clips
        let beforeCount = try globalDB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips")
        }
        XCTAssertEqual(beforeCount, 3)

        // 4. 清理全局库中该视频的旧 clips（模拟 re-index 前的清理步骤）
        let sourceVideoId: Int64 = try folderDB.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT video_id FROM videos LIMIT 1")!
            return row["video_id"]
        }
        let deleted = try PipelineManager.cleanGlobalClipsForVideo(
            folderPath: folderPath,
            sourceVideoId: sourceVideoId,
            globalDB: globalDB
        )
        XCTAssertEqual(deleted, 3, "应删除全局库中该视频的 3 个旧 clips")

        // 5. 验证全局库 clips 已清空
        let afterCount = try globalDB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips")
        }
        XCTAssertEqual(afterCount, 0, "全局库不应有孤儿 clips")
    }

    func testCleanGlobalClipsForVideoNoGlobalRecord() throws {
        let globalDB = try DatabaseManager.makeGlobalInMemoryDatabase()

        // 全局库中无该视频记录，应返回 0 且不崩溃
        let deleted = try PipelineManager.cleanGlobalClipsForVideo(
            folderPath: "/nonexistent",
            sourceVideoId: 999,
            globalDB: globalDB
        )
        XCTAssertEqual(deleted, 0)
    }

    // NOTE: processVideo() 旧管线回归测试已在 R6 工程清理中移除。
    // 索引功能测试由 LayeredIndexerTests 覆盖。
}
