import XCTest
import GRDB
@testable import FindItCore

final class FTS5SearchTests: XCTestCase {

    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        db = try DatabaseManager.makeGlobalInMemoryDatabase()
        try seedTestData()
    }

    override func tearDownWithError() throws {
        db = nil
    }

    // MARK: - 测试数据

    /// 插入中英混合测试数据到全局库
    private func seedTestData() throws {
        try db.write { db in
            // 插入 video
            try db.execute(sql: """
                INSERT INTO videos (source_folder, source_video_id, file_path, file_name, duration)
                VALUES ('/素材/A', 1, '/素材/A/beach.mp4', 'beach.mp4', 120.0)
                """)
            let videoId = db.lastInsertedRowID

            // Clip 1: 海滩日落
            try db.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, video_id, start_time, end_time,
                    scene, description, tags, transcript)
                VALUES ('/素材/A', 1, ?, 0.0, 5.5,
                    '海滩日落', '金色夕阳下的沙滩，海浪轻拍岸边',
                    '海滩 日落 户外 暖色调 全景', '今天的日落真美')
                """, arguments: [videoId])

            // Clip 2: 城市夜景
            try db.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, video_id, start_time, end_time,
                    scene, description, tags, transcript)
                VALUES ('/素材/A', 2, ?, 5.5, 12.0,
                    '城市夜景', '霓虹灯闪烁的都市街道，车流穿梭',
                    '城市 夜景 霓虹灯 冷色调', NULL)
                """, arguments: [videoId])

            // Clip 3: 海滩 + 人物（英文描述）
            try db.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, video_id, start_time, end_time,
                    scene, description, tags, transcript)
                VALUES ('/素材/A', 3, ?, 12.0, 18.0,
                    'beach portrait', 'A young woman walking along the shoreline at golden hour',
                    '海滩 人像 黄金时刻 中景', 'the waves are so peaceful')
                """, arguments: [videoId])

            // Clip 4: 无对白纯画面
            try db.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, video_id, start_time, end_time,
                    scene, description, tags, transcript)
                VALUES ('/素材/A', 4, ?, 18.0, 25.0,
                    '森林晨雾', '清晨薄雾笼罩的森林，阳光穿透树叶',
                    '森林 晨雾 自然 绿色', NULL)
                """, arguments: [videoId])
        }
    }

    // MARK: - FTS5 触发器

    func testFTS5TriggerOnInsert() throws {
        // seedTestData 已通过 INSERT 触发 FTS5 索引
        let ftsCount = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips_fts")
        }
        XCTAssertEqual(ftsCount, 4, "4 条 clip 应全部索引到 FTS5")
    }

    func testFTS5TriggerOnDelete() throws {
        // 删除 clip_id=1
        try db.write { db in
            try db.execute(sql: "DELETE FROM clips WHERE clip_id = 1")
        }

        let ftsCount = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips_fts")
        }
        XCTAssertEqual(ftsCount, 3, "删除后 FTS5 应只剩 3 条")
    }

    func testFTS5TriggerOnUpdate() throws {
        // 更新 clip_id=1 的 tags
        try db.write { db in
            try db.execute(sql: """
                UPDATE clips SET tags = '海滩 日落 冲浪' WHERE clip_id = 1
                """)
        }

        // 搜索"冲浪"应能找到
        let results = try db.read { db in
            try SearchEngine.search(db, query: "冲浪")
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].clipId, 1)
    }

    // MARK: - 关键词搜索

    func testSearchByTag() throws {
        let results = try db.read { db in
            try SearchEngine.search(db, query: "海滩")
        }
        // Clip 1 和 Clip 3 都有 "海滩" tag
        XCTAssertEqual(results.count, 2)
    }

    func testSearchByDescription() throws {
        let results = try db.read { db in
            try SearchEngine.search(db, query: "霓虹灯")
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].scene, "城市夜景")
    }

    func testSearchByTranscript() throws {
        let results = try db.read { db in
            try SearchEngine.search(db, query: "日落")
        }
        // Clip 1: tags 有 "日落", transcript 有 "日落"
        XCTAssertTrue(results.count >= 1)
        XCTAssertTrue(results.contains(where: { $0.clipId == 1 }))
    }

    func testSearchEnglish() throws {
        let results = try db.read { db in
            try SearchEngine.search(db, query: "peaceful")
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].sourceClipId, 3)
    }

    func testSearchNoResults() throws {
        let results = try db.read { db in
            try SearchEngine.search(db, query: "完全不存在的内容xyz")
        }
        XCTAssertEqual(results.count, 0)
    }

    func testSearchEmptyQuery() throws {
        let results = try db.read { db in
            try SearchEngine.search(db, query: "   ")
        }
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - 搜索结果包含视频信息

    func testSearchResultIncludesVideoInfo() throws {
        let results = try db.read { db in
            try SearchEngine.search(db, query: "森林")
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].filePath, "/素材/A/beach.mp4")
        XCTAssertEqual(results[0].fileName, "beach.mp4")
    }

    // MARK: - 搜索结果排序

    func testSearchResultsHaveRank() throws {
        let results = try db.read { db in
            try SearchEngine.search(db, query: "海滩")
        }
        XCTAssertTrue(results.count >= 2)
        // FTS5 rank 是负 BM25 值，越小越相关
        for result in results {
            XCTAssertTrue(result.rank < 0, "FTS5 rank 应为负值")
        }
    }

    func testSearchWithLimit() throws {
        let results = try db.read { db in
            try SearchEngine.search(db, query: "海滩", limit: 1)
        }
        XCTAssertEqual(results.count, 1)
    }

    // MARK: - FTS5 高级语法

    func testSearchExactPhrase() throws {
        // 英文短语精确匹配（unicode61 对英文按单词切分，短语查询可靠）
        let results = try db.read { db in
            try SearchEngine.search(db, query: "\"waves are so peaceful\"")
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].sourceClipId, 3)
    }

    func testSearchWithNOT() throws {
        // 搜索有"海滩"但没有"人像"的
        let results = try db.read { db in
            try SearchEngine.search(db, query: "海滩 NOT 人像")
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].clipId, 1)
    }

    func testSearchWithOR() throws {
        // 搜索"森林"或"城市"
        let results = try db.read { db in
            try SearchEngine.search(db, query: "森林 OR 城市")
        }
        XCTAssertEqual(results.count, 2)
    }

    func testSearchColumnFilter() throws {
        // 只在 tags 列搜索
        let results = try db.read { db in
            try SearchEngine.search(db, query: "tags:森林")
        }
        XCTAssertEqual(results.count, 1)
    }

    // MARK: - 搜索历史

    func testRecordAndFetchSearchHistory() throws {
        try db.write { db in
            try SearchEngine.recordSearch(db, query: "海滩", resultCount: 2)
            try SearchEngine.recordSearch(db, query: "城市", resultCount: 1)
        }

        let history = try db.read { db in
            try SearchEngine.recentSearches(db, limit: 10)
        }
        XCTAssertEqual(history.count, 2)
        // 最新的在前
        XCTAssertEqual(history[0].query, "城市")
        XCTAssertEqual(history[0].resultCount, 1)
        XCTAssertEqual(history[1].query, "海滩")
    }

    func testSearchHistoryLimit() throws {
        try db.write { db in
            for i in 1...5 {
                try SearchEngine.recordSearch(db, query: "query\(i)", resultCount: i)
            }
        }

        let history = try db.read { db in
            try SearchEngine.recentSearches(db, limit: 3)
        }
        XCTAssertEqual(history.count, 3)
    }
}
