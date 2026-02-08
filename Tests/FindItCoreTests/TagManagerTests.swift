import XCTest
import GRDB
@testable import FindItCore

final class TagManagerTests: XCTestCase {

    // MARK: - 辅助

    /// 创建一个带测试数据的内存数据库，返回 (db, clipId)
    private func makeDBWithClip(
        tags: String? = nil,
        userTags: String? = nil
    ) throws -> (DatabaseQueue, Int64) {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()
        var clipId: Int64 = 0

        try db.write { conn in
            // 先创建 watched_folder
            try conn.execute(sql: """
                INSERT INTO watched_folders (folder_path) VALUES ('/test')
                """)
            // 创建 video
            try conn.execute(sql: """
                INSERT INTO videos (folder_id, file_path, file_name, index_status)
                VALUES (1, '/test/v.mp4', 'v.mp4', 'completed')
                """)
            // 创建 clip
            try conn.execute(sql: """
                INSERT INTO clips (video_id, start_time, end_time, tags, user_tags, created_at)
                VALUES (1, 0.0, 5.0, ?, ?, datetime('now'))
                """, arguments: [tags, userTags])
            clipId = conn.lastInsertedRowID
        }

        return (db, clipId)
    }

    // MARK: - addTags

    func testAddTagsToEmpty() throws {
        let (db, clipId) = try makeDBWithClip()

        try db.write { conn in
            try TagManager.addTags(conn, clipId: clipId, tags: ["精选", "B-roll"])
        }

        let result = try db.read { conn in
            try TagManager.fetchUserTags(conn, clipId: clipId)
        }
        XCTAssertEqual(result, ["精选", "B-roll"])
    }

    func testAddTagsMergeDedup() throws {
        let (db, clipId) = try makeDBWithClip(userTags: "[\"精选\"]")

        try db.write { conn in
            try TagManager.addTags(conn, clipId: clipId, tags: ["精选", "待审", "B-roll"])
        }

        let result = try db.read { conn in
            try TagManager.fetchUserTags(conn, clipId: clipId)
        }
        XCTAssertEqual(result, ["精选", "待审", "B-roll"], "已有的 '精选' 不重复添加")
    }

    func testAddTagsDoesNotAffectAutoTags() throws {
        let (db, clipId) = try makeDBWithClip(tags: "[\"海滩\",\"日落\"]")

        try db.write { conn in
            try TagManager.addTags(conn, clipId: clipId, tags: ["精选"])
        }

        // auto tags 不受影响
        let clip = try db.read { conn in
            try Clip.fetchOne(conn, sql: "SELECT * FROM clips WHERE clip_id = ?", arguments: [clipId])
        }
        XCTAssertEqual(clip?.tagsArray, ["海滩", "日落"])
        XCTAssertEqual(clip?.userTagsArray, ["精选"])
    }

    func testAddEmptyTagsIsNoOp() throws {
        let (db, clipId) = try makeDBWithClip(userTags: "[\"精选\"]")

        try db.write { conn in
            try TagManager.addTags(conn, clipId: clipId, tags: [])
        }

        let result = try db.read { conn in
            try TagManager.fetchUserTags(conn, clipId: clipId)
        }
        XCTAssertEqual(result, ["精选"])
    }

    func testAddTagsTrimsWhitespace() throws {
        let (db, clipId) = try makeDBWithClip()

        try db.write { conn in
            try TagManager.addTags(conn, clipId: clipId, tags: ["  精选  ", " ", "B-roll"])
        }

        let result = try db.read { conn in
            try TagManager.fetchUserTags(conn, clipId: clipId)
        }
        XCTAssertEqual(result, ["精选", "B-roll"], "空白字符应被过滤和修剪")
    }

    // MARK: - removeTags

    func testRemoveExistingTag() throws {
        let (db, clipId) = try makeDBWithClip(userTags: "[\"精选\",\"B-roll\",\"待审\"]")

        try db.write { conn in
            try TagManager.removeTags(conn, clipId: clipId, tags: ["B-roll"])
        }

        let result = try db.read { conn in
            try TagManager.fetchUserTags(conn, clipId: clipId)
        }
        XCTAssertEqual(result, ["精选", "待审"])
    }

    func testRemoveNonExistentTagIsNoOp() throws {
        let (db, clipId) = try makeDBWithClip(userTags: "[\"精选\"]")

        try db.write { conn in
            try TagManager.removeTags(conn, clipId: clipId, tags: ["不存在的标签"])
        }

        let result = try db.read { conn in
            try TagManager.fetchUserTags(conn, clipId: clipId)
        }
        XCTAssertEqual(result, ["精选"])
    }

    func testRemoveAllTags() throws {
        let (db, clipId) = try makeDBWithClip(userTags: "[\"精选\",\"B-roll\"]")

        try db.write { conn in
            try TagManager.removeTags(conn, clipId: clipId, tags: ["精选", "B-roll"])
        }

        let result = try db.read { conn in
            try TagManager.fetchUserTags(conn, clipId: clipId)
        }
        XCTAssertEqual(result, [])

        // 数据库中应为 NULL
        let raw = try db.read { conn in
            try Row.fetchOne(conn, sql: "SELECT user_tags FROM clips WHERE clip_id = ?", arguments: [clipId])
        }
        XCTAssertNil(raw?["user_tags"] as String?, "全部移除后应为 NULL")
    }

    // MARK: - replaceTags

    func testReplaceTagsFromEmpty() throws {
        let (db, clipId) = try makeDBWithClip()

        try db.write { conn in
            try TagManager.replaceTags(conn, clipId: clipId, tags: ["A", "B", "C"])
        }

        let result = try db.read { conn in
            try TagManager.fetchUserTags(conn, clipId: clipId)
        }
        XCTAssertEqual(result, ["A", "B", "C"])
    }

    func testReplaceTagsOverwriteExisting() throws {
        let (db, clipId) = try makeDBWithClip(userTags: "[\"old1\",\"old2\"]")

        try db.write { conn in
            try TagManager.replaceTags(conn, clipId: clipId, tags: ["new1"])
        }

        let result = try db.read { conn in
            try TagManager.fetchUserTags(conn, clipId: clipId)
        }
        XCTAssertEqual(result, ["new1"])
    }

    func testReplaceTagsWithEmpty() throws {
        let (db, clipId) = try makeDBWithClip(userTags: "[\"精选\"]")

        try db.write { conn in
            try TagManager.replaceTags(conn, clipId: clipId, tags: [])
        }

        let result = try db.read { conn in
            try TagManager.fetchUserTags(conn, clipId: clipId)
        }
        XCTAssertEqual(result, [])
    }

    // MARK: - popularTags

    func testPopularTagsAggregation() throws {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()

        try db.write { conn in
            try conn.execute(sql: "INSERT INTO watched_folders (folder_path) VALUES ('/test')")
            try conn.execute(sql: """
                INSERT INTO videos (folder_id, file_path, file_name, index_status)
                VALUES (1, '/test/v.mp4', 'v.mp4', 'completed')
                """)

            // clip 1: auto=海滩,日落  user=精选
            try conn.execute(sql: """
                INSERT INTO clips (video_id, start_time, end_time, tags, user_tags, created_at)
                VALUES (1, 0, 5, '["海滩","日落"]', '["精选"]', datetime('now'))
                """)
            // clip 2: auto=海滩  user=精选,B-roll
            try conn.execute(sql: """
                INSERT INTO clips (video_id, start_time, end_time, tags, user_tags, created_at)
                VALUES (1, 5, 10, '["海滩"]', '["精选","B-roll"]', datetime('now'))
                """)
            // clip 3: auto=户外  user=null
            try conn.execute(sql: """
                INSERT INTO clips (video_id, start_time, end_time, tags, user_tags, created_at)
                VALUES (1, 10, 15, '["户外"]', NULL, datetime('now'))
                """)
        }

        let popular = try db.read { conn in
            try TagManager.popularTags(conn, limit: 10)
        }

        // 海滩=2, 精选=2, 日落=1, B-roll=1, 户外=1
        XCTAssertGreaterThanOrEqual(popular.count, 5)

        let tagCounts = Dictionary(uniqueKeysWithValues: popular.map { ($0.tag, $0.count) })
        XCTAssertEqual(tagCounts["海滩"], 2)
        XCTAssertEqual(tagCounts["精选"], 2)
        XCTAssertEqual(tagCounts["日落"], 1)
        XCTAssertEqual(tagCounts["B-roll"], 1)
        XCTAssertEqual(tagCounts["户外"], 1)

        // 结果按 count 降序
        XCTAssertTrue(popular[0].count >= popular[1].count)
    }

    func testPopularTagsLimit() throws {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()

        try db.write { conn in
            try conn.execute(sql: "INSERT INTO watched_folders (folder_path) VALUES ('/test')")
            try conn.execute(sql: """
                INSERT INTO videos (folder_id, file_path, file_name, index_status)
                VALUES (1, '/test/v.mp4', 'v.mp4', 'completed')
                """)
            try conn.execute(sql: """
                INSERT INTO clips (video_id, start_time, end_time, tags, created_at)
                VALUES (1, 0, 5, '["a","b","c","d","e"]', datetime('now'))
                """)
        }

        let popular = try db.read { conn in
            try TagManager.popularTags(conn, limit: 3)
        }

        XCTAssertEqual(popular.count, 3, "应限制返回数量")
    }

    func testPopularTagsDedupsWithinClip() throws {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()

        try db.write { conn in
            try conn.execute(sql: "INSERT INTO watched_folders (folder_path) VALUES ('/test')")
            try conn.execute(sql: """
                INSERT INTO videos (folder_id, file_path, file_name, index_status)
                VALUES (1, '/test/v.mp4', 'v.mp4', 'completed')
                """)
            // auto 和 user 都有 "精选" → 同一个 clip 只贡献 1 次
            try conn.execute(sql: """
                INSERT INTO clips (video_id, start_time, end_time, tags, user_tags, created_at)
                VALUES (1, 0, 5, '["精选","海滩"]', '["精选"]', datetime('now'))
                """)
        }

        let popular = try db.read { conn in
            try TagManager.popularTags(conn, limit: 10)
        }

        let tagCounts = Dictionary(uniqueKeysWithValues: popular.map { ($0.tag, $0.count) })
        XCTAssertEqual(tagCounts["精选"], 1, "同一 clip 内 auto+user 重复标签只算一次")
    }

    // MARK: - Clip allTagsArray

    func testAllTagsArrayMergesAndDedupes() {
        var clip = Clip(startTime: 0, endTime: 5)
        clip.setTags(["海滩", "日落", "户外"])
        clip.setUserTags(["日落", "精选"])

        XCTAssertEqual(clip.allTagsArray, ["海滩", "日落", "户外", "精选"],
                       "合并应去重，保留顺序（auto 优先）")
    }

    func testAllTagsArrayWithEmptyUserTags() {
        var clip = Clip(startTime: 0, endTime: 5)
        clip.setTags(["海滩"])

        XCTAssertEqual(clip.allTagsArray, ["海滩"])
    }

    // MARK: - 迁移测试

    func testFolderMigrationV7UserTags() throws {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()

        let columns = try db.read { conn in
            try Row.fetchAll(conn, sql: "PRAGMA table_info(clips)")
        }.map { $0["name"] as String }

        XCTAssertTrue(columns.contains("user_tags"), "文件夹库 clips 应有 user_tags 列")
    }

    func testGlobalMigrationV6UserTagsAndFTS() throws {
        let db = try DatabaseManager.makeGlobalInMemoryDatabase()

        // 验证 user_tags 列
        let columns = try db.read { conn in
            try Row.fetchAll(conn, sql: "PRAGMA table_info(clips)")
        }.map { $0["name"] as String }
        XCTAssertTrue(columns.contains("user_tags"), "全局库 clips 应有 user_tags 列")

        // 验证 FTS5 包含 user_tags
        // 插入一个 clip 并检查 FTS5 是否能搜索到 user_tags 内容
        try db.write { conn in
            try conn.execute(sql: """
                INSERT INTO videos (source_folder, source_video_id, file_path, file_name)
                VALUES ('/test', 1, '/test/v.mp4', 'v.mp4')
                """)
            try conn.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, video_id,
                    start_time, end_time, user_tags)
                VALUES ('/test', 1, 1, 0, 5, '精选素材')
                """)
        }

        let ftsResults = try db.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT * FROM clips_fts WHERE clips_fts MATCH '精选素材'
                """)
        }
        XCTAssertEqual(ftsResults.count, 1, "FTS5 应能搜索 user_tags 内容")
    }

    // MARK: - SyncEngine user_tags

    func testSyncEngineCarriesUserTags() throws {
        let folderDB = try DatabaseManager.makeFolderInMemoryDatabase()
        let globalDB = try DatabaseManager.makeGlobalInMemoryDatabase()

        try folderDB.write { db in
            try db.execute(sql: "INSERT INTO watched_folders (folder_path) VALUES ('/test')")
            try db.execute(sql: """
                INSERT INTO videos (folder_id, file_path, file_name, index_status)
                VALUES (1, '/test/v.mp4', 'v.mp4', 'completed')
                """)
            try db.execute(sql: """
                INSERT INTO clips (video_id, start_time, end_time, tags, user_tags, created_at)
                VALUES (1, 0, 5, '["海滩"]', '["精选","B-roll"]', datetime('now'))
                """)
        }

        _ = try SyncEngine.sync(
            folderPath: "/test",
            folderDB: folderDB,
            globalDB: globalDB
        )

        let globalUserTags = try globalDB.read { db in
            try Row.fetchOne(db, sql: "SELECT user_tags FROM clips WHERE source_clip_id = 1")
        }
        // SyncEngine 将 JSON 数组转为空格分隔文本
        XCTAssertEqual(globalUserTags?["user_tags"] as? String, "精选 B-roll",
                       "user_tags 应同步到全局库（FTS 格式）")
    }
}
