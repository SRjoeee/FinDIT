import XCTest
import GRDB
@testable import FindItCore

final class SearchEngineFilterTests: XCTestCase {

    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        db = try DatabaseManager.makeGlobalInMemoryDatabase()
        try seedMultiFolderData()
    }

    override func tearDownWithError() throws {
        db = nil
    }

    // MARK: - 测试数据

    /// 在两个不同的 source_folder 中插入测试数据
    private func seedMultiFolderData() throws {
        try db.write { db in
            // 文件夹 A: 2 个视频, 3 个 clips
            try db.execute(sql: """
                INSERT INTO videos (source_folder, source_video_id, file_path, file_name, duration)
                VALUES ('/素材/FolderA', 1, '/素材/FolderA/beach.mp4', 'beach.mp4', 60.0)
                """)
            let videoA = db.lastInsertedRowID

            try db.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, video_id, start_time, end_time,
                    scene, description, tags, transcript)
                VALUES ('/素材/FolderA', 1, ?, 0.0, 5.0,
                    '海滩日落', '沙滩上的日落', '海滩 日落 户外', '今天真美')
                """, arguments: [videoA])

            try db.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, video_id, start_time, end_time,
                    scene, description, tags, transcript)
                VALUES ('/素材/FolderA', 2, ?, 5.0, 10.0,
                    '海滩人像', '沙滩上的人', '海滩 人像', NULL)
                """, arguments: [videoA])

            try db.execute(sql: """
                INSERT INTO videos (source_folder, source_video_id, file_path, file_name, duration)
                VALUES ('/素材/FolderA', 2, '/素材/FolderA/city.mp4', 'city.mp4', 90.0)
                """)
            let videoA2 = db.lastInsertedRowID

            try db.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, video_id, start_time, end_time,
                    scene, description, tags, transcript)
                VALUES ('/素材/FolderA', 3, ?, 0.0, 8.0,
                    '城市街道', '繁忙的城市街道', '城市 街道', NULL)
                """, arguments: [videoA2])

            // 文件夹 B: 1 个视频, 2 个 clips
            try db.execute(sql: """
                INSERT INTO videos (source_folder, source_video_id, file_path, file_name, duration)
                VALUES ('/素材/FolderB', 1, '/素材/FolderB/nature.mp4', 'nature.mp4', 45.0)
                """)
            let videoB = db.lastInsertedRowID

            try db.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, video_id, start_time, end_time,
                    scene, description, tags, transcript)
                VALUES ('/素材/FolderB', 1, ?, 0.0, 6.0,
                    '森林小径', '阳光穿过树林', '森林 户外 日落', '多么宁静')
                """, arguments: [videoB])

            try db.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, video_id, start_time, end_time,
                    scene, description, tags, transcript)
                VALUES ('/素材/FolderB', 2, ?, 6.0, 12.0,
                    '海滩冲浪', '海浪中的冲浪者', '海滩 冲浪 运动', NULL)
                """, arguments: [videoB])
        }
    }

    // MARK: - FTS5 搜索 + 文件夹过滤

    func testSearchWithoutFilter_returnsAllFolders() throws {
        let results = try db.read { db in
            try SearchEngine.search(db, query: "海滩")
        }
        // 海滩相关 clips: FolderA 的 clip1,2 + FolderB 的 clip2 = 3 个
        XCTAssertEqual(results.count, 3)
        let folders = Set(results.map(\.sourceFolder))
        XCTAssertEqual(folders, ["/素材/FolderA", "/素材/FolderB"])
    }

    func testSearchWithFolderFilter_returnsSingleFolder() throws {
        let results = try db.read { db in
            try SearchEngine.search(db, query: "海滩", folderPaths: ["/素材/FolderA"])
        }
        // 只返回 FolderA 的海滩 clips
        XCTAssertTrue(results.allSatisfy { $0.sourceFolder == "/素材/FolderA" })
        XCTAssertGreaterThanOrEqual(results.count, 1)
    }

    func testSearchWithFolderFilter_otherFolderOnly() throws {
        let results = try db.read { db in
            try SearchEngine.search(db, query: "海滩", folderPaths: ["/素材/FolderB"])
        }
        // 只返回 FolderB 的海滩 clips
        XCTAssertTrue(results.allSatisfy { $0.sourceFolder == "/素材/FolderB" })
    }

    func testSearchWithMultipleFolderPaths() throws {
        let results = try db.read { db in
            try SearchEngine.search(db, query: "海滩", folderPaths: ["/素材/FolderA", "/素材/FolderB"])
        }
        // 两个文件夹的海滩 clips 都应返回
        XCTAssertEqual(results.count, 3)
    }

    func testSearchWithEmptyFolderSet_returnsEmpty() throws {
        let results = try db.read { db in
            try SearchEngine.search(db, query: "海滩", folderPaths: [])
        }
        // 空集 = 无文件夹匹配
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchWithNonexistentFolder_returnsEmpty() throws {
        let results = try db.read { db in
            try SearchEngine.search(db, query: "海滩", folderPaths: ["/不存在的路径"])
        }
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - folderPaths = nil 行为不变

    func testSearchNilFilter_equivalentToNoFilter() throws {
        let allResults = try db.read { db in
            try SearchEngine.search(db, query: "日落")
        }
        let nilResults = try db.read { db in
            try SearchEngine.search(db, query: "日落", folderPaths: nil)
        }
        XCTAssertEqual(allResults.count, nilResults.count)
        XCTAssertEqual(
            Set(allResults.map(\.clipId)),
            Set(nilResults.map(\.clipId))
        )
    }

    // MARK: - FolderStats 与过滤一致性

    func testFolderFilterConsistentWithFolderStats() throws {
        let stats = try db.read { db in
            try SearchEngine.folderStats(db, folderPath: "/素材/FolderA")
        }
        XCTAssertEqual(stats.videoCount, 2)
        XCTAssertEqual(stats.clipCount, 3)

        let statsB = try db.read { db in
            try SearchEngine.folderStats(db, folderPath: "/素材/FolderB")
        }
        XCTAssertEqual(statsB.videoCount, 1)
        XCTAssertEqual(statsB.clipCount, 2)
    }
}
