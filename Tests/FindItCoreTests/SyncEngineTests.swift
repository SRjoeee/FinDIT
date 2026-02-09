import XCTest
import GRDB
@testable import FindItCore

final class SyncEngineTests: XCTestCase {

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

    /// 在文件夹库中插入测试数据
    private func seedFolderData(videoCount: Int = 1, clipsPerVideo: Int = 2) throws {
        try folderDB.write { db in
            var folder = WatchedFolder(folderPath: folderPath)
            try folder.insert(db)

            for v in 1...videoCount {
                var video = Video(
                    folderId: folder.folderId,
                    filePath: "\(folderPath)/video\(v).mp4",
                    fileName: "video\(v).mp4",
                    duration: Double(v * 60),
                    fileSize: Int64(v * 1_000_000)
                )
                try video.insert(db)

                for c in 0..<clipsPerVideo {
                    var clip = Clip(
                        videoId: video.videoId,
                        startTime: Double(c * 5),
                        endTime: Double((c + 1) * 5),
                        scene: "场景\(v)-\(c + 1)",
                        clipDescription: "视频\(v)的第\(c + 1)个片段"
                    )
                    clip.setTags(["标签\(v)", "片段\(c + 1)", "测试"])
                    try clip.insert(db)
                }
            }
        }
    }

    // MARK: - 首次同步

    func testFirstSyncVideos() throws {
        try seedFolderData(videoCount: 2, clipsPerVideo: 0)

        let result = try SyncEngine.sync(
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        XCTAssertEqual(result.syncedVideos, 2)

        let globalVideos = try globalDB.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM videos ORDER BY video_id")
        }
        XCTAssertEqual(globalVideos.count, 2)
        XCTAssertEqual(globalVideos[0]["source_folder"] as String, folderPath)
        XCTAssertEqual(globalVideos[0]["file_name"] as String, "video1.mp4")
    }

    func testFirstSyncClips() throws {
        try seedFolderData(videoCount: 1, clipsPerVideo: 3)

        let result = try SyncEngine.sync(
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        XCTAssertEqual(result.syncedClips, 3)

        let globalClips = try globalDB.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM clips ORDER BY clip_id")
        }
        XCTAssertEqual(globalClips.count, 3)
        XCTAssertEqual(globalClips[0]["source_folder"] as String, folderPath)
    }

    func testSyncClipHasGlobalVideoId() throws {
        try seedFolderData(videoCount: 1, clipsPerVideo: 1)

        _ = try SyncEngine.sync(
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        let globalClip = try globalDB.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM clips LIMIT 1")
        }!
        let globalVideoId: Int64 = globalClip["video_id"]
        XCTAssertTrue(globalVideoId > 0, "全局 clip 应关联全局 video_id")

        // 验证 video_id 指向正确的全局 video
        let globalVideo = try globalDB.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM videos WHERE video_id = ?", arguments: [globalVideoId])
        }
        XCTAssertNotNil(globalVideo)
    }

    // MARK: - Tags 转换

    func testSyncConvertsTags() throws {
        try seedFolderData(videoCount: 1, clipsPerVideo: 1)

        _ = try SyncEngine.sync(
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        let globalClip = try globalDB.read { db in
            try Row.fetchOne(db, sql: "SELECT tags FROM clips LIMIT 1")
        }!
        let tags: String = globalClip["tags"]
        // 应该是空格分隔，不是 JSON
        XCTAssertFalse(tags.contains("["), "同步后 tags 不应包含 JSON 括号")
        XCTAssertTrue(tags.contains(" "), "同步后 tags 应是空格分隔")
    }

    func testConvertTagsForFTS() {
        // JSON 数组 → 空格分隔
        let result = SyncEngine.convertTagsForFTS("[\"海滩\",\"户外\",\"全景\"]")
        XCTAssertEqual(result, "海滩 户外 全景")

        // nil → nil
        XCTAssertNil(SyncEngine.convertTagsForFTS(nil))

        // 非 JSON → 原样返回
        XCTAssertEqual(SyncEngine.convertTagsForFTS("already plain"), "already plain")
    }

    // MARK: - 增量同步

    func testIncrementalSync() throws {
        // 第一批数据
        try seedFolderData(videoCount: 1, clipsPerVideo: 2)
        let result1 = try SyncEngine.sync(
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )
        XCTAssertEqual(result1.syncedVideos, 1)
        XCTAssertEqual(result1.syncedClips, 2)

        // 添加第二批数据
        try folderDB.write { db in
            let folder = try WatchedFolder.fetchByPath(db, path: folderPath)!
            var video2 = Video(
                folderId: folder.folderId,
                filePath: "\(folderPath)/extra.mp4",
                fileName: "extra.mp4"
            )
            try video2.insert(db)

            var clip = Clip(videoId: video2.videoId, startTime: 0, endTime: 10, scene: "新增场景")
            clip.setTags(["新增", "测试"])
            try clip.insert(db)
        }

        // 第二次同步（增量）
        let result2 = try SyncEngine.sync(
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )
        XCTAssertEqual(result2.syncedVideos, 1, "应只同步新增的 1 个 video")
        XCTAssertEqual(result2.syncedClips, 1, "应只同步新增的 1 个 clip")

        // 全局库总数
        let totalVideos = try globalDB.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM videos") }
        let totalClips = try globalDB.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips") }
        XCTAssertEqual(totalVideos, 2)
        XCTAssertEqual(totalClips, 3)
    }

    func testNoNewDataSkipsSync() throws {
        try seedFolderData(videoCount: 1, clipsPerVideo: 1)

        _ = try SyncEngine.sync(folderPath: folderPath, folderDB: folderDB, globalDB: globalDB)

        // 再次同步，无新数据
        let result = try SyncEngine.sync(folderPath: folderPath, folderDB: folderDB, globalDB: globalDB)
        XCTAssertEqual(result.syncedVideos, 0)
        XCTAssertEqual(result.syncedClips, 0)
    }

    // MARK: - 强制同步

    func testForceSyncUpdatesExistingClips() throws {
        try seedFolderData(videoCount: 1, clipsPerVideo: 2)

        // 首次同步
        _ = try SyncEngine.sync(folderPath: folderPath, folderDB: folderDB, globalDB: globalDB)

        // 验证全局库 embedding 为空
        let beforeEmbedding = try globalDB.read { db in
            try Row.fetchOne(db, sql: "SELECT embedding FROM clips WHERE clip_id = 1")
        }
        XCTAssertTrue(beforeEmbedding?["embedding"] == nil || beforeEmbedding?["embedding"] is NSNull)

        // 在文件夹库中更新 clip 的 embedding（模拟 embed 命令）
        let fakeEmbedding = EmbeddingUtils.serializeEmbedding([0.1, 0.2, 0.3])
        try folderDB.write { db in
            try db.execute(
                sql: "UPDATE clips SET embedding = ?, embedding_model = ? WHERE clip_id = 1",
                arguments: [fakeEmbedding, "gemini"]
            )
        }

        // 普通增量同步检测不到更新（clip_id 未变）
        let normalResult = try SyncEngine.sync(
            folderPath: folderPath, folderDB: folderDB, globalDB: globalDB
        )
        XCTAssertEqual(normalResult.syncedClips, 0, "增量同步不感知已有记录的字段更新")

        // 全局库 embedding 仍然为空
        let stillEmpty = try globalDB.read { db in
            try Data.fetchOne(db, sql: "SELECT embedding FROM clips WHERE clip_id = 1")
        }
        XCTAssertNil(stillEmpty, "增量同步后全局库 embedding 应仍为空")

        // 强制同步可以同步更新
        let forceResult = try SyncEngine.sync(
            folderPath: folderPath, folderDB: folderDB, globalDB: globalDB, force: true
        )
        XCTAssertEqual(forceResult.syncedClips, 2, "force 应重新同步所有 clips")

        // 全局库 embedding 已更新
        let afterEmbedding = try globalDB.read { db in
            try Data.fetchOne(db, sql: "SELECT embedding FROM clips WHERE source_clip_id = 1 AND source_folder = ?",
                              arguments: [folderPath])
        }
        XCTAssertNotNil(afterEmbedding, "force 同步后全局库应有 embedding 数据")

        let afterModel = try globalDB.read { db in
            try String.fetchOne(db, sql: "SELECT embedding_model FROM clips WHERE source_clip_id = 1 AND source_folder = ?",
                                arguments: [folderPath])
        }
        XCTAssertEqual(afterModel, "gemini")
    }

    func testForceSyncDoesNotDuplicateRecords() throws {
        try seedFolderData(videoCount: 1, clipsPerVideo: 2)

        // 首次同步
        _ = try SyncEngine.sync(folderPath: folderPath, folderDB: folderDB, globalDB: globalDB)

        // 强制同步（重复 upsert）
        let forceResult = try SyncEngine.sync(
            folderPath: folderPath, folderDB: folderDB, globalDB: globalDB, force: true
        )
        XCTAssertEqual(forceResult.syncedClips, 2)

        // 全局库记录数不变（ON CONFLICT 更新而非插入）
        let totalClips = try globalDB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips")
        }
        XCTAssertEqual(totalClips, 2, "force 同步不应创建重复记录")
    }

    // MARK: - sync_meta

    func testSyncMetaUpdated() throws {
        try seedFolderData(videoCount: 1, clipsPerVideo: 2)

        _ = try SyncEngine.sync(folderPath: folderPath, folderDB: folderDB, globalDB: globalDB)

        let meta = try globalDB.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM sync_meta WHERE folder_path = ?", arguments: [folderPath])
        }!
        let lastVideoRowId: Int64 = meta["last_synced_video_rowid"]
        let lastClipRowId: Int64 = meta["last_synced_clip_rowid"]
        XCTAssertTrue(lastVideoRowId > 0)
        XCTAssertTrue(lastClipRowId > 0)
        XCTAssertNotNil(meta["last_synced_at"] as String?)
    }

    // MARK: - 同步后搜索

    func testSearchAfterSync() throws {
        try seedFolderData(videoCount: 1, clipsPerVideo: 2)

        _ = try SyncEngine.sync(folderPath: folderPath, folderDB: folderDB, globalDB: globalDB)

        // FTS5 应能搜索到同步的数据
        let results = try globalDB.read { db in
            try SearchEngine.search(db, query: "测试")
        }
        XCTAssertEqual(results.count, 2, "两个 clip 都有 '测试' tag")
    }

    func testSearchAfterIncrementalSync() throws {
        try seedFolderData(videoCount: 1, clipsPerVideo: 1)
        _ = try SyncEngine.sync(folderPath: folderPath, folderDB: folderDB, globalDB: globalDB)

        // 添加新 clip 到文件夹库
        try folderDB.write { db in
            let video = try Video.fetchByPath(db, path: "\(folderPath)/video1.mp4")!
            var clip = Clip(videoId: video.videoId, startTime: 10, endTime: 15, scene: "独特场景")
            clip.setTags(["独特", "新增"])
            try clip.insert(db)
        }

        _ = try SyncEngine.sync(folderPath: folderPath, folderDB: folderDB, globalDB: globalDB)

        let results = try globalDB.read { db in
            try SearchEngine.search(db, query: "独特")
        }
        XCTAssertEqual(results.count, 1)
    }

    // MARK: - 删除文件夹数据

    func testRemoveFolderData() throws {
        try seedFolderData(videoCount: 1, clipsPerVideo: 2)
        _ = try SyncEngine.sync(folderPath: folderPath, folderDB: folderDB, globalDB: globalDB)

        try SyncEngine.removeFolderData(folderPath: folderPath, from: globalDB)

        let videoCount = try globalDB.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM videos") }
        let clipCount = try globalDB.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips") }
        let metaCount = try globalDB.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_meta") }
        XCTAssertEqual(videoCount, 0)
        XCTAssertEqual(clipCount, 0)
        XCTAssertEqual(metaCount, 0)
    }

    // MARK: - 多文件夹同步

    func testMultipleFolderSync() throws {
        let folderPathB = "/Volumes/素材盘/项目B"

        // 文件夹 A
        try seedFolderData(videoCount: 1, clipsPerVideo: 1)

        // 文件夹 B（用同一个 folderDB 模拟，但不同 folderPath）
        let folderDBB = try DatabaseManager.makeFolderInMemoryDatabase()
        try folderDBB.write { db in
            var folder = WatchedFolder(folderPath: folderPathB)
            try folder.insert(db)
            var video = Video(folderId: folder.folderId, filePath: "\(folderPathB)/clip.mp4", fileName: "clip.mp4")
            try video.insert(db)
            var clip = Clip(videoId: video.videoId, startTime: 0, endTime: 5, scene: "项目B场景")
            clip.setTags(["项目B"])
            try clip.insert(db)
        }

        _ = try SyncEngine.sync(folderPath: folderPath, folderDB: folderDB, globalDB: globalDB)
        _ = try SyncEngine.sync(folderPath: folderPathB, folderDB: folderDBB, globalDB: globalDB)

        let totalClips = try globalDB.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips") }
        XCTAssertEqual(totalClips, 2, "两个文件夹各 1 个 clip")

        // 删除文件夹 A 数据不影响 B
        try SyncEngine.removeFolderData(folderPath: folderPath, from: globalDB)
        let remaining = try globalDB.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips") }
        XCTAssertEqual(remaining, 1)
    }

    // MARK: - Fix 2: 空文件夹同步

    func testSyncEmptyFolderWritesSyncMeta() throws {
        // 只创建 watched_folder，不插入任何 video/clip
        try folderDB.write { db in
            var folder = WatchedFolder(folderPath: folderPath)
            try folder.insert(db)
        }

        let result = try SyncEngine.sync(
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        XCTAssertEqual(result.syncedVideos, 0)
        XCTAssertEqual(result.syncedClips, 0)

        // sync_meta 应有记录（空文件夹也应存在）
        let metaCount = try globalDB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_meta WHERE folder_path = ?",
                             arguments: [folderPath])
        }
        XCTAssertEqual(metaCount, 1, "空文件夹 sync 后 sync_meta 应有记录")
    }

    func testSyncCountsOnlyActuallyUpsertedRows() throws {
        try seedFolderData(videoCount: 2, clipsPerVideo: 1)

        // 将第二个视频标记为 orphaned（其 clips 也应被跳过）
        try folderDB.write { db in
            try db.execute(
                sql: "UPDATE videos SET index_status = 'orphaned' WHERE file_name = 'video2.mp4'"
            )
        }

        let result = try SyncEngine.sync(
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        XCTAssertEqual(result.syncedVideos, 1, "应仅统计实际写入全局库的 video")
        XCTAssertEqual(result.syncedClips, 1, "应仅统计实际写入全局库的 clip")
    }
}
