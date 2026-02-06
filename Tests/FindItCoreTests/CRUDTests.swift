import XCTest
import GRDB
@testable import FindItCore

final class CRUDTests: XCTestCase {

    /// 每个测试方法共享的内存数据库
    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        db = try DatabaseManager.makeFolderInMemoryDatabase()
    }

    override func tearDownWithError() throws {
        db = nil
    }

    // MARK: - Helper

    /// 插入一个默认 folder 并返回
    @discardableResult
    private func insertFolder(path: String = "/test/素材") throws -> WatchedFolder {
        var folder = WatchedFolder(folderPath: path)
        try db.write { db in try folder.insert(db) }
        return folder
    }

    /// 插入一个默认 video 并返回
    @discardableResult
    private func insertVideo(
        folderId: Int64?,
        filePath: String = "/test/素材/beach.mp4",
        fileName: String = "beach.mp4"
    ) throws -> Video {
        var video = Video(folderId: folderId, filePath: filePath, fileName: fileName)
        try db.write { db in try video.insert(db) }
        return video
    }

    // MARK: - WatchedFolder CRUD

    func testFetchFolderByPath() throws {
        let folder = try insertFolder(path: "/Volumes/SSD/素材")

        let found = try db.read { db in
            try WatchedFolder.fetchByPath(db, path: "/Volumes/SSD/素材")
        }
        XCTAssertEqual(found?.folderId, folder.folderId)

        let notFound = try db.read { db in
            try WatchedFolder.fetchByPath(db, path: "/不存在的路径")
        }
        XCTAssertNil(notFound)
    }

    func testFetchAllFolders() throws {
        try insertFolder(path: "/a")
        try insertFolder(path: "/b")
        try insertFolder(path: "/c")

        let all = try db.read { db in
            try WatchedFolder.fetchAllFolders(db)
        }
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.map(\.folderPath), ["/a", "/b", "/c"])
    }

    func testUpdateFolderAvailability() throws {
        var folder = try insertFolder()

        try db.write { db in
            try folder.updateAvailability(db, isAvailable: false)
        }

        let fetched = try db.read { db in
            try WatchedFolder.fetchOne(db, key: folder.folderId)
        }
        XCTAssertEqual(fetched?.isAvailable, false)
    }

    func testUpdateFolderProgress() throws {
        var folder = try insertFolder()

        try db.write { db in
            try folder.updateProgress(db, totalFiles: 100, indexedFiles: 42)
        }

        let fetched = try db.read { db in
            try WatchedFolder.fetchOne(db, key: folder.folderId)
        }
        XCTAssertEqual(fetched?.totalFiles, 100)
        XCTAssertEqual(fetched?.indexedFiles, 42)
    }

    func testDeleteFolder() throws {
        let folder = try insertFolder()

        let deleted = try db.write { db in
            try WatchedFolder.deleteOne(db, key: folder.folderId)
        }
        XCTAssertTrue(deleted)

        let count = try db.read { db in
            try WatchedFolder.fetchCount(db)
        }
        XCTAssertEqual(count, 0)
    }

    // MARK: - Video CRUD

    func testFetchVideoByPath() throws {
        let folder = try insertFolder()
        try insertVideo(folderId: folder.folderId, filePath: "/test/v1.mp4", fileName: "v1.mp4")

        let found = try db.read { db in
            try Video.fetchByPath(db, path: "/test/v1.mp4")
        }
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.fileName, "v1.mp4")

        let notFound = try db.read { db in
            try Video.fetchByPath(db, path: "/nope.mp4")
        }
        XCTAssertNil(notFound)
    }

    func testFetchVideosForFolder() throws {
        let folderA = try insertFolder(path: "/a")
        let folderB = try insertFolder(path: "/b")

        try insertVideo(folderId: folderA.folderId, filePath: "/a/v1.mp4", fileName: "v1.mp4")
        try insertVideo(folderId: folderA.folderId, filePath: "/a/v2.mp4", fileName: "v2.mp4")
        try insertVideo(folderId: folderB.folderId, filePath: "/b/v3.mp4", fileName: "v3.mp4")

        let videosA = try db.read { db in
            try Video.fetchAll(forFolder: folderA.folderId!, in: db)
        }
        XCTAssertEqual(videosA.count, 2)

        let videosB = try db.read { db in
            try Video.fetchAll(forFolder: folderB.folderId!, in: db)
        }
        XCTAssertEqual(videosB.count, 1)
    }

    func testFetchVideoByStatus() throws {
        let folder = try insertFolder()
        try insertVideo(folderId: folder.folderId, filePath: "/v1.mp4", fileName: "v1.mp4")
        try insertVideo(folderId: folder.folderId, filePath: "/v2.mp4", fileName: "v2.mp4")

        // 两个都是 pending（默认值）
        let pending = try db.read { db in
            try Video.fetchByStatus(db, status: "pending")
        }
        XCTAssertEqual(pending.count, 2)

        // 把第一个改为 completed
        var first = pending[0]
        try db.write { db in
            try first.updateIndexStatus(db, status: "completed")
        }

        let stillPending = try db.read { db in
            try Video.fetchByStatus(db, status: "pending")
        }
        XCTAssertEqual(stillPending.count, 1)
    }

    func testFetchVideoByStatusWithLimit() throws {
        let folder = try insertFolder()
        for i in 1...5 {
            try insertVideo(folderId: folder.folderId, filePath: "/v\(i).mp4", fileName: "v\(i).mp4")
        }

        let limited = try db.read { db in
            try Video.fetchByStatus(db, status: "pending", limit: 2)
        }
        XCTAssertEqual(limited.count, 2)
    }

    func testVideoUpdateIndexStatus() throws {
        let folder = try insertFolder()
        var video = try insertVideo(folderId: folder.folderId)

        // 更新为 failed + error
        try db.write { db in
            try video.updateIndexStatus(db, status: "failed", error: "Gemini API 超时")
        }

        let fetched = try db.read { db in
            try Video.fetchOne(db, key: video.videoId)
        }!
        XCTAssertEqual(fetched.indexStatus, "failed")
        XCTAssertEqual(fetched.indexError, "Gemini API 超时")
        XCTAssertNil(fetched.indexedAt, "非 completed 不应设置 indexedAt")
    }

    func testVideoUpdateIndexStatusCompleted() throws {
        let folder = try insertFolder()
        var video = try insertVideo(folderId: folder.folderId)

        try db.write { db in
            try video.updateIndexStatus(db, status: "completed")
        }

        let fetched = try db.read { db in
            try Video.fetchOne(db, key: video.videoId)
        }!
        XCTAssertEqual(fetched.indexStatus, "completed")
        XCTAssertNotNil(fetched.indexedAt, "completed 应自动设置 indexedAt")
    }

    func testVideoFetchAfterRowId() throws {
        let folder = try insertFolder()
        var ids: [Int64] = []
        for i in 1...5 {
            let v = try insertVideo(folderId: folder.folderId, filePath: "/v\(i).mp4", fileName: "v\(i).mp4")
            ids.append(v.videoId!)
        }

        // 获取 rowId > ids[2] 的记录
        let after = try db.read { db in
            try Video.fetchAfterRowId(db, rowId: ids[2], limit: 10)
        }
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after[0].videoId, ids[3])
        XCTAssertEqual(after[1].videoId, ids[4])
    }

    func testVideoUpdate() throws {
        let folder = try insertFolder()
        var video = try insertVideo(folderId: folder.folderId)

        video.duration = 300.0
        video.fileSize = 2_000_000
        try db.write { db in
            try video.update(db)
        }

        let fetched = try db.read { db in
            try Video.fetchOne(db, key: video.videoId)
        }!
        XCTAssertEqual(fetched.duration, 300.0)
        XCTAssertEqual(fetched.fileSize, 2_000_000)
    }

    func testVideoDelete() throws {
        let folder = try insertFolder()
        let video = try insertVideo(folderId: folder.folderId)

        let deleted = try db.write { db in
            try Video.deleteOne(db, key: video.videoId)
        }
        XCTAssertTrue(deleted)

        let count = try db.read { db in try Video.fetchCount(db) }
        XCTAssertEqual(count, 0)
    }

    // MARK: - Clip CRUD

    func testFetchClipsForVideo() throws {
        let folder = try insertFolder()
        let video = try insertVideo(folderId: folder.folderId)

        // 插入 3 个 clips（不按时间顺序）
        for (start, end) in [(10.0, 15.0), (0.0, 5.0), (5.0, 10.0)] {
            var clip = Clip(videoId: video.videoId, startTime: start, endTime: end)
            try db.write { db in try clip.insert(db) }
        }

        let clips = try db.read { db in
            try Clip.fetchAll(forVideo: video.videoId!, in: db)
        }
        XCTAssertEqual(clips.count, 3)
        // 应按 start_time 排序
        XCTAssertEqual(clips.map(\.startTime), [0.0, 5.0, 10.0])
    }

    func testClipFetchAfterRowId() throws {
        let folder = try insertFolder()
        let video = try insertVideo(folderId: folder.folderId)

        var clipIds: [Int64] = []
        for i in 0..<4 {
            var clip = Clip(videoId: video.videoId, startTime: Double(i), endTime: Double(i + 1))
            try db.write { db in try clip.insert(db) }
            clipIds.append(clip.clipId!)
        }

        let after = try db.read { db in
            try Clip.fetchAfterRowId(db, rowId: clipIds[1], limit: 10)
        }
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after[0].clipId, clipIds[2])
    }

    func testClipUpdate() throws {
        let folder = try insertFolder()
        let video = try insertVideo(folderId: folder.folderId)

        var clip = Clip(videoId: video.videoId, startTime: 0, endTime: 5)
        try db.write { db in try clip.insert(db) }

        clip.scene = "城市夜景"
        clip.setTags(["城市", "夜景", "霓虹灯"])
        try db.write { db in try clip.update(db) }

        let fetched = try db.read { db in
            try Clip.fetchOne(db, key: clip.clipId)
        }!
        XCTAssertEqual(fetched.scene, "城市夜景")
        XCTAssertEqual(fetched.tagsArray, ["城市", "夜景", "霓虹灯"])
    }

    func testClipDelete() throws {
        let folder = try insertFolder()
        let video = try insertVideo(folderId: folder.folderId)

        var clip = Clip(videoId: video.videoId, startTime: 0, endTime: 1)
        try db.write { db in try clip.insert(db) }

        let deleted = try db.write { db in try clip.delete(db) }
        XCTAssertTrue(deleted)

        let count = try db.read { db in try Clip.fetchCount(db) }
        XCTAssertEqual(count, 0)
    }

    // MARK: - 批量操作

    func testDeleteAllClipsForVideo() throws {
        let folder = try insertFolder()
        let videoA = try insertVideo(folderId: folder.folderId, filePath: "/a.mp4", fileName: "a.mp4")
        let videoB = try insertVideo(folderId: folder.folderId, filePath: "/b.mp4", fileName: "b.mp4")

        for i in 0..<3 {
            var clip = Clip(videoId: videoA.videoId, startTime: Double(i), endTime: Double(i + 1))
            try db.write { db in try clip.insert(db) }
        }
        var clipB = Clip(videoId: videoB.videoId, startTime: 0, endTime: 1)
        try db.write { db in try clipB.insert(db) }

        // 删除 videoA 的所有 clips
        try db.write { db in
            _ = try Clip.filter(Column("video_id") == videoA.videoId).deleteAll(db)
        }

        let totalCount = try db.read { db in try Clip.fetchCount(db) }
        XCTAssertEqual(totalCount, 1, "应只剩 videoB 的 clip")
    }

    func testUniqueFilePathConstraint() throws {
        let folder = try insertFolder()
        try insertVideo(folderId: folder.folderId, filePath: "/dup.mp4", fileName: "dup.mp4")

        // 插入相同 file_path 应失败
        var dup = Video(folderId: folder.folderId, filePath: "/dup.mp4", fileName: "dup.mp4")
        XCTAssertThrowsError(try db.write { db in try dup.insert(db) })
    }
}
