import XCTest
import GRDB
@testable import FindItCore

final class OrphanRecoveryTests: XCTestCase {

    private var folderDB: DatabaseQueue!
    private var globalDB: DatabaseQueue!
    private let folderPath = "/Volumes/素材盘/项目A"

    override func setUpWithError() throws {
        folderDB = try DatabaseManager.makeFolderInMemoryDatabase()
        globalDB = try DatabaseManager.makeGlobalInMemoryDatabase()
    }

    override func tearDownWithError() throws {
        folderDB = nil
        globalDB = nil
    }

    // MARK: - Helper

    /// 在文件夹库中插入带 hash 的视频 + clips，同步到全局库
    private func seedVideo(
        path: String? = nil,
        hash: String = "abc123",
        status: String = "completed",
        clipCount: Int = 3
    ) throws -> Int64 {
        let videoPath = path ?? "\(folderPath)/video1.mp4"
        let fileName = (videoPath as NSString).lastPathComponent
        try folderDB.write { db in
            // 确保 watched_folder 存在
            if try WatchedFolder.fetchOne(db, sql: "SELECT * FROM watched_folders WHERE folder_path = ?", arguments: [folderPath]) == nil {
                var folder = WatchedFolder(folderPath: folderPath)
                try folder.insert(db)
            }
            let folderId = try Int64.fetchOne(db, sql: "SELECT folder_id FROM watched_folders WHERE folder_path = ?", arguments: [folderPath])
            var video = Video(
                folderId: folderId,
                filePath: videoPath,
                fileName: fileName,
                fileSize: 1_000_000,
                indexStatus: status
            )
            video.fileHash = hash
            try video.insert(db)

            for c in 0..<clipCount {
                var clip = Clip(
                    videoId: video.videoId,
                    startTime: Double(c * 5),
                    endTime: Double((c + 1) * 5),
                    scene: "场景\(c + 1)",
                    clipDescription: "片段\(c + 1)"
                )
                clip.setTags(["标签\(c + 1)"])
                try clip.insert(db)
            }
        }

        let videoId = try folderDB.read { db in
            try Int64.fetchOne(db, sql: "SELECT video_id FROM videos WHERE file_path = ?", arguments: [videoPath])
        }
        return videoId!
    }

    /// 同步到全局库
    private func syncToGlobal() throws {
        _ = try SyncEngine.sync(
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )
    }

    private func folderVideoCount(status: String? = nil) throws -> Int {
        try folderDB.read { db in
            if let status = status {
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM videos WHERE index_status = ?", arguments: [status]) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM videos") ?? 0
        }
    }

    private func folderClipCount(videoId: Int64? = nil) throws -> Int {
        try folderDB.read { db in
            if let videoId = videoId {
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips WHERE video_id = ?", arguments: [videoId]) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips") ?? 0
        }
    }

    private func globalVideoCount() throws -> Int {
        try globalDB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM videos") ?? 0
        }
    }

    private func globalClipCount() throws -> Int {
        try globalDB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips") ?? 0
        }
    }

    // MARK: - markOrphaned Tests

    func testMarkOrphaned_setsOrphanedStatus() throws {
        let videoId = try seedVideo()
        try syncToGlobal()

        let result = try OrphanRecovery.markOrphaned(
            videoPath: "\(folderPath)/video1.mp4",
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.markedCount, 1)

        let status = try folderDB.read { db in
            try String.fetchOne(db, sql: "SELECT index_status FROM videos WHERE video_id = ?", arguments: [videoId])
        }
        XCTAssertEqual(status, "orphaned")
    }

    func testMarkOrphaned_setsOrphanedAt() throws {
        let videoId = try seedVideo()

        _ = try OrphanRecovery.markOrphaned(
            videoPath: "\(folderPath)/video1.mp4",
            folderPath: folderPath,
            folderDB: folderDB
        )

        let orphanedAt = try folderDB.read { db in
            try String?.fetchOne(db, sql: "SELECT orphaned_at FROM videos WHERE video_id = ?", arguments: [videoId])
        }
        XCTAssertNotNil(orphanedAt as Any)
    }

    func testMarkOrphaned_deletesFromGlobalDB() throws {
        _ = try seedVideo()
        try syncToGlobal()

        XCTAssertEqual(try globalVideoCount(), 1)
        XCTAssertEqual(try globalClipCount(), 3)

        _ = try OrphanRecovery.markOrphaned(
            videoPath: "\(folderPath)/video1.mp4",
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        XCTAssertEqual(try globalVideoCount(), 0)
        XCTAssertEqual(try globalClipCount(), 0)
    }

    func testMarkOrphaned_preservesFolderDBClips() throws {
        let videoId = try seedVideo()
        try syncToGlobal()

        _ = try OrphanRecovery.markOrphaned(
            videoPath: "\(folderPath)/video1.mp4",
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        // 文件夹库的 clips 应保留
        XCTAssertEqual(try folderClipCount(videoId: videoId), 3)
    }

    func testMarkOrphaned_nonexistentPathReturnsNil() throws {
        _ = try seedVideo()

        let result = try OrphanRecovery.markOrphaned(
            videoPath: "\(folderPath)/nonexistent.mp4",
            folderPath: folderPath,
            folderDB: folderDB
        )

        XCTAssertNil(result)
    }

    func testMarkOrphanedBatch_marksMultiple() throws {
        _ = try seedVideo(path: "\(folderPath)/a.mp4", hash: "h1", clipCount: 2)
        _ = try seedVideo(path: "\(folderPath)/b.mp4", hash: "h2", clipCount: 1)
        try syncToGlobal()

        let result = try OrphanRecovery.markOrphanedBatch(
            videoPaths: ["\(folderPath)/a.mp4", "\(folderPath)/b.mp4"],
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        XCTAssertEqual(result.markedCount, 2)
        XCTAssertEqual(try folderVideoCount(status: "orphaned"), 2)
        XCTAssertEqual(try globalVideoCount(), 0)
    }

    // MARK: - attemptRecovery Tests

    func testRecovery_matchingHash_recoversRecord() throws {
        let orphanedId = try seedVideo(hash: "match_hash")
        // 标记为 orphaned
        _ = try OrphanRecovery.markOrphaned(
            videoPath: "\(folderPath)/video1.mp4",
            folderPath: folderPath,
            folderDB: folderDB
        )

        // 模拟新 pending 记录（路径不同，但 hash 相同）
        let pendingId = try seedVideo(
            path: "\(folderPath)/renamed.mp4",
            hash: "other_hash",
            status: "pending",
            clipCount: 0
        )

        let recovery = try OrphanRecovery.attemptRecovery(
            fileHash: "match_hash",
            newVideoPath: "\(folderPath)/renamed.mp4",
            pendingVideoId: pendingId,
            folderDB: folderDB
        )

        XCTAssertNotNil(recovery)
        XCTAssertEqual(recovery?.recoveredVideoId, orphanedId)
        XCTAssertEqual(recovery?.clipCount, 3)
    }

    func testRecovery_updatesFilePathAndName() throws {
        _ = try seedVideo(hash: "h1")
        _ = try OrphanRecovery.markOrphaned(
            videoPath: "\(folderPath)/video1.mp4",
            folderPath: folderPath,
            folderDB: folderDB
        )

        let pendingId = try seedVideo(
            path: "\(folderPath)/moved.mp4",
            hash: "x",
            status: "pending",
            clipCount: 0
        )

        let recovery = try OrphanRecovery.attemptRecovery(
            fileHash: "h1",
            newVideoPath: "\(folderPath)/moved.mp4",
            pendingVideoId: pendingId,
            folderDB: folderDB
        )

        XCTAssertNotNil(recovery)
        let path = try folderDB.read { db in
            try String.fetchOne(db, sql: "SELECT file_path FROM videos WHERE video_id = ?", arguments: [recovery!.recoveredVideoId])
        }
        XCTAssertEqual(path, "\(folderPath)/moved.mp4")
    }

    func testRecovery_restoresCompletedStatus() throws {
        let orphanedId = try seedVideo(hash: "h1")
        _ = try OrphanRecovery.markOrphaned(
            videoPath: "\(folderPath)/video1.mp4",
            folderPath: folderPath,
            folderDB: folderDB
        )

        let pendingId = try seedVideo(
            path: "\(folderPath)/new.mp4",
            hash: "x",
            status: "pending",
            clipCount: 0
        )

        _ = try OrphanRecovery.attemptRecovery(
            fileHash: "h1",
            newVideoPath: "\(folderPath)/new.mp4",
            pendingVideoId: pendingId,
            folderDB: folderDB
        )

        let status = try folderDB.read { db in
            try String.fetchOne(db, sql: "SELECT index_status FROM videos WHERE video_id = ?", arguments: [orphanedId])
        }
        XCTAssertEqual(status, "completed")
    }

    func testRecovery_clearsOrphanedAt() throws {
        let orphanedId = try seedVideo(hash: "h1")
        _ = try OrphanRecovery.markOrphaned(
            videoPath: "\(folderPath)/video1.mp4",
            folderPath: folderPath,
            folderDB: folderDB
        )

        let pendingId = try seedVideo(
            path: "\(folderPath)/new.mp4",
            hash: "x",
            status: "pending",
            clipCount: 0
        )

        _ = try OrphanRecovery.attemptRecovery(
            fileHash: "h1",
            newVideoPath: "\(folderPath)/new.mp4",
            pendingVideoId: pendingId,
            folderDB: folderDB
        )

        let orphanedAt: String? = try folderDB.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT orphaned_at FROM videos WHERE video_id = ?", arguments: [orphanedId])
            return row?["orphaned_at"]
        }
        XCTAssertNil(orphanedAt)
    }

    func testRecovery_deletesPendingDuplicate() throws {
        _ = try seedVideo(hash: "h1")
        _ = try OrphanRecovery.markOrphaned(
            videoPath: "\(folderPath)/video1.mp4",
            folderPath: folderPath,
            folderDB: folderDB
        )

        let pendingId = try seedVideo(
            path: "\(folderPath)/new.mp4",
            hash: "x",
            status: "pending",
            clipCount: 0
        )

        _ = try OrphanRecovery.attemptRecovery(
            fileHash: "h1",
            newVideoPath: "\(folderPath)/new.mp4",
            pendingVideoId: pendingId,
            folderDB: folderDB
        )

        // pending 记录应被删除
        let pendingExists = try folderDB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM videos WHERE video_id = ?", arguments: [pendingId]) ?? 0
        }
        XCTAssertEqual(pendingExists, 0)
    }

    func testRecovery_preservesClips() throws {
        let orphanedId = try seedVideo(hash: "h1", clipCount: 5)
        _ = try OrphanRecovery.markOrphaned(
            videoPath: "\(folderPath)/video1.mp4",
            folderPath: folderPath,
            folderDB: folderDB
        )

        let pendingId = try seedVideo(
            path: "\(folderPath)/new.mp4",
            hash: "x",
            status: "pending",
            clipCount: 0
        )

        let recovery = try OrphanRecovery.attemptRecovery(
            fileHash: "h1",
            newVideoPath: "\(folderPath)/new.mp4",
            pendingVideoId: pendingId,
            folderDB: folderDB
        )

        XCTAssertEqual(recovery?.clipCount, 5)
        XCTAssertEqual(try folderClipCount(videoId: orphanedId), 5)
    }

    func testRecovery_noMatch_returnsNil() throws {
        _ = try seedVideo(hash: "h1")
        _ = try OrphanRecovery.markOrphaned(
            videoPath: "\(folderPath)/video1.mp4",
            folderPath: folderPath,
            folderDB: folderDB
        )

        let pendingId = try seedVideo(
            path: "\(folderPath)/new.mp4",
            hash: "different",
            status: "pending",
            clipCount: 0
        )

        let recovery = try OrphanRecovery.attemptRecovery(
            fileHash: "no_match",
            newVideoPath: "\(folderPath)/new.mp4",
            pendingVideoId: pendingId,
            folderDB: folderDB
        )

        XCTAssertNil(recovery)
    }

    func testRecovery_multipleOrphans_takesNewest() throws {
        // 插入两个 orphaned 记录，同 hash 不同路径
        let oldId = try seedVideo(path: "\(folderPath)/old.mp4", hash: "shared", clipCount: 1)
        _ = try OrphanRecovery.markOrphaned(
            videoPath: "\(folderPath)/old.mp4",
            folderPath: folderPath,
            folderDB: folderDB
        )

        // 手动设置更早的 orphaned_at
        try folderDB.write { db in
            try db.execute(sql: "UPDATE videos SET orphaned_at = '2020-01-01 00:00:00' WHERE video_id = ?", arguments: [oldId])
        }

        let newId = try seedVideo(path: "\(folderPath)/new.mp4", hash: "shared", clipCount: 2)
        _ = try OrphanRecovery.markOrphaned(
            videoPath: "\(folderPath)/new.mp4",
            folderPath: folderPath,
            folderDB: folderDB
        )

        let pendingId = try seedVideo(
            path: "\(folderPath)/recovered.mp4",
            hash: "x",
            status: "pending",
            clipCount: 0
        )

        let recovery = try OrphanRecovery.attemptRecovery(
            fileHash: "shared",
            newVideoPath: "\(folderPath)/recovered.mp4",
            pendingVideoId: pendingId,
            folderDB: folderDB
        )

        // 应恢复较新的（newId）
        XCTAssertNotNil(recovery)
        XCTAssertEqual(recovery?.recoveredVideoId, newId)
        XCTAssertEqual(recovery?.clipCount, 2)
    }

    // MARK: - cleanupExpired Tests

    func testCleanup_removesOldRecords() throws {
        let videoId = try seedVideo(hash: "h1", clipCount: 2)
        _ = try OrphanRecovery.markOrphaned(
            videoPath: "\(folderPath)/video1.mp4",
            folderPath: folderPath,
            folderDB: folderDB
        )
        // 设置 orphaned_at 为 60 天前
        try folderDB.write { db in
            try db.execute(sql: "UPDATE videos SET orphaned_at = datetime('now', '-60 days') WHERE video_id = ?", arguments: [videoId])
        }

        let result = try OrphanRecovery.cleanupExpired(
            retentionDays: 30,
            folderPath: folderPath,
            folderDB: folderDB
        )

        XCTAssertEqual(result.removedCount, 1)
        XCTAssertEqual(try folderVideoCount(), 0)
        XCTAssertEqual(try folderClipCount(), 0)
    }

    func testCleanup_keepsRecentRecords() throws {
        let videoId = try seedVideo(hash: "h1")
        _ = try OrphanRecovery.markOrphaned(
            videoPath: "\(folderPath)/video1.mp4",
            folderPath: folderPath,
            folderDB: folderDB
        )
        // orphaned_at 就是刚才设置的（远未过期）

        let result = try OrphanRecovery.cleanupExpired(
            retentionDays: 30,
            folderPath: folderPath,
            folderDB: folderDB
        )

        XCTAssertEqual(result.removedCount, 0)
        XCTAssertEqual(try folderVideoCount(), 1)
        XCTAssertEqual(try folderClipCount(videoId: videoId), 3)
    }

    func testCleanup_cascadeDeletesClips() throws {
        let videoId = try seedVideo(hash: "h1", clipCount: 5)
        _ = try OrphanRecovery.markOrphaned(
            videoPath: "\(folderPath)/video1.mp4",
            folderPath: folderPath,
            folderDB: folderDB
        )
        try folderDB.write { db in
            try db.execute(sql: "UPDATE videos SET orphaned_at = datetime('now', '-60 days') WHERE video_id = ?", arguments: [videoId])
        }

        _ = try OrphanRecovery.cleanupExpired(
            retentionDays: 30,
            folderPath: folderPath,
            folderDB: folderDB
        )

        XCTAssertEqual(try folderClipCount(), 0)
    }

    func testCleanup_noOrphans_returnsZero() throws {
        _ = try seedVideo(hash: "h1")  // completed, not orphaned

        let result = try OrphanRecovery.cleanupExpired(
            retentionDays: 30,
            folderPath: folderPath,
            folderDB: folderDB
        )

        XCTAssertEqual(result.removedCount, 0)
    }

    // MARK: - SyncEngine Integration Tests

    func testSync_skipsOrphanedVideos() throws {
        _ = try seedVideo(path: "\(folderPath)/active.mp4", hash: "h1", clipCount: 2)
        _ = try seedVideo(path: "\(folderPath)/orphan.mp4", hash: "h2", clipCount: 1)

        // 标记第二个为 orphaned
        _ = try OrphanRecovery.markOrphaned(
            videoPath: "\(folderPath)/orphan.mp4",
            folderPath: folderPath,
            folderDB: folderDB
        )

        // 同步
        _ = try SyncEngine.sync(
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        // 全局库应只有 active 的视频
        XCTAssertEqual(try globalVideoCount(), 1)
        let globalPath = try globalDB.read { db in
            try String.fetchOne(db, sql: "SELECT file_path FROM videos")
        }
        XCTAssertEqual(globalPath, "\(folderPath)/active.mp4")
    }

    func testSync_skipsOrphanedVideoClips() throws {
        _ = try seedVideo(path: "\(folderPath)/active.mp4", hash: "h1", clipCount: 2)
        _ = try seedVideo(path: "\(folderPath)/orphan.mp4", hash: "h2", clipCount: 3)

        _ = try OrphanRecovery.markOrphaned(
            videoPath: "\(folderPath)/orphan.mp4",
            folderPath: folderPath,
            folderDB: folderDB
        )

        _ = try SyncEngine.sync(
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        // 全局库应只有 active 的 2 个 clips
        XCTAssertEqual(try globalClipCount(), 2)
    }
}
