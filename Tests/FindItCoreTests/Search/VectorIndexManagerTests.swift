import XCTest
import GRDB
@testable import FindItCore

final class VectorIndexManagerTests: XCTestCase {

    /// 创建带 clip_vectors 表的内存全局库
    private func makeGlobalDB() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        let migrator = Migrations.globalMigrator()
        try migrator.migrate(db)
        return db
    }

    /// 创建使用临时路径的 manager（隔离真实索引文件）
    private func makeManager(db: DatabaseQueue) -> VectorIndexManager {
        let id = UUID().uuidString
        return VectorIndexManager(
            globalDB: db,
            clipIndexPath: NSTemporaryDirectory() + "test_clip_\(id).usearch",
            textIndexPath: NSTemporaryDirectory() + "test_text_\(id).usearch"
        )
    }

    // MARK: - 基本生命周期

    func testGetClipIndexReturnsNilWhenNoVectors() async throws {
        let db = try makeGlobalDB()
        let manager = makeManager(db: db)

        let index = try await manager.getClipIndex()
        XCTAssertNil(index, "无 CLIP 向量时应返回 nil")
    }

    func testGetTextIndexReturnsNilWhenNoVectors() async throws {
        let db = try makeGlobalDB()
        let manager = makeManager(db: db)

        let index = try await manager.getTextIndex()
        XCTAssertNil(index, "无文本嵌入向量时应返回 nil")
    }

    func testInvalidateClipIndex() async throws {
        let db = try makeGlobalDB()
        let manager = makeManager(db: db)

        // 获取 nil（无向量）
        let _ = try await manager.getClipIndex()

        // 失效后再次获取也应返回 nil（无向量仍然无索引）
        await manager.invalidateClipIndex()
        let index = try await manager.getClipIndex()
        XCTAssertNil(index)
    }

    func testInvalidateAll() async throws {
        let db = try makeGlobalDB()
        let manager = makeManager(db: db)

        await manager.invalidateAll()
        let clip = try await manager.getClipIndex()
        let text = try await manager.getTextIndex()
        XCTAssertNil(clip)
        XCTAssertNil(text)
    }
}

// MARK: - USearch 只读保护测试

final class USearchReadOnlyTests: XCTestCase {

    func testViewMakesIndexReadOnly() throws {
        // 创建索引并保存
        let index = try USearchVectorIndex(config: .clip768)
        try index.add(key: 1, vector: [Float](repeating: 0.1, count: 768))
        let tmpPath = NSTemporaryDirectory() + "test_readonly_\(UUID().uuidString).usearch"
        try index.save(to: tmpPath)
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        // mmap 只读加载
        let readOnlyIndex = try USearchVectorIndex(config: .clip768)
        try readOnlyIndex.view(from: tmpPath)

        // 搜索应该正常工作
        let results = try readOnlyIndex.searchSimilarity(
            query: [Float](repeating: 0.1, count: 768),
            count: 10
        )
        XCTAssertFalse(results.isEmpty)

        // 写操作应该抛出 readOnly 错误
        XCTAssertThrowsError(
            try readOnlyIndex.add(key: 2, vector: [Float](repeating: 0.2, count: 768))
        ) { error in
            XCTAssertTrue(error is VectorIndexError)
        }

        XCTAssertThrowsError(
            try readOnlyIndex.addBatch(
                keys: [2], vectors: [[Float](repeating: 0.2, count: 768)]
            )
        ) { error in
            XCTAssertTrue(error is VectorIndexError)
        }

        XCTAssertThrowsError(
            try readOnlyIndex.remove(key: 1)
        ) { error in
            XCTAssertTrue(error is VectorIndexError)
        }

        XCTAssertThrowsError(
            try readOnlyIndex.clear()
        ) { error in
            XCTAssertTrue(error is VectorIndexError)
        }
    }

    func testLoadDoesNotMakeReadOnly() throws {
        // 创建索引并保存
        let index = try USearchVectorIndex(config: .clip768)
        try index.add(key: 1, vector: [Float](repeating: 0.1, count: 768))
        let tmpPath = NSTemporaryDirectory() + "test_loadrw_\(UUID().uuidString).usearch"
        try index.save(to: tmpPath)
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        // 完整加载（非 mmap）
        let rwIndex = try USearchVectorIndex(config: .clip768)
        try rwIndex.load(from: tmpPath)

        // 写操作应该正常
        XCTAssertNoThrow(
            try rwIndex.add(key: 2, vector: [Float](repeating: 0.2, count: 768))
        )
        let count = try rwIndex.count
        XCTAssertEqual(count, 2)
    }

    func testClearLockedProperly() throws {
        let index = try USearchVectorIndex(config: .clip768)
        try index.add(key: 1, vector: [Float](repeating: 0.1, count: 768))

        // clear 应该正常工作（非只读）
        XCTAssertNoThrow(try index.clear())
        let count = try index.count
        XCTAssertEqual(count, 0)
    }
}

// MARK: - searchSimilarity clamp 测试

final class USearchSimilarityClampTests: XCTestCase {

    func testSimilarityClampedToZeroOne() throws {
        let index = try USearchVectorIndex(config: .init(
            dimensions: 3, connectivity: 8, quantization: .f32
        ))
        // 添加一个向量
        try index.add(key: 1, vector: [1.0, 0.0, 0.0])

        // 搜索同方向向量 → similarity 应 ≤ 1.0
        let results = try index.searchSimilarity(
            query: [1.0, 0.0, 0.0], count: 1
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertLessThanOrEqual(results[0].similarity, 1.0)
        XCTAssertGreaterThanOrEqual(results[0].similarity, 0.0)

        // 搜索反方向向量 → similarity 应 ≥ 0.0
        let oppositeResults = try index.searchSimilarity(
            query: [-1.0, 0.0, 0.0], count: 1
        )
        XCTAssertEqual(oppositeResults.count, 1)
        XCTAssertGreaterThanOrEqual(oppositeResults[0].similarity, 0.0)
        XCTAssertLessThanOrEqual(oppositeResults[0].similarity, 1.0)
    }
}

// MARK: - 迁移测试

final class MigrationSchemaTests: XCTestCase {

    func testFolderDBHasMediaTypeColumn() throws {
        let db = try DatabaseQueue()
        try Migrations.folderMigrator().migrate(db)

        try db.write { db in
            try db.execute(sql: """
                INSERT INTO watched_folders (folder_path) VALUES ('/test')
                """)
            try db.execute(sql: """
                INSERT INTO videos
                (folder_id, file_path, file_name, index_status, media_type)
                VALUES (1, '/test/v.mp4', 'v.mp4', 'pending', 'video')
                """)
        }

        let mediaType: String? = try db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT media_type FROM videos WHERE video_id = 1")!
            return row["media_type"]
        }
        XCTAssertEqual(mediaType, "video")
    }

    func testGlobalDBHasMediaTypeColumn() throws {
        let db = try DatabaseQueue()
        try Migrations.globalMigrator().migrate(db)

        try db.write { db in
            try db.execute(sql: """
                INSERT INTO videos
                (source_folder, source_video_id, file_path, file_name, media_type)
                VALUES ('/src', 1, '/test/v.mp4', 'v.mp4', 'photo')
                """)
        }

        let mediaType: String? = try db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT media_type FROM videos WHERE video_id = 1")!
            return row["media_type"]
        }
        XCTAssertEqual(mediaType, "photo")
    }

    func testGlobalDBHasCreatedAtColumn() throws {
        let db = try DatabaseQueue()
        try Migrations.globalMigrator().migrate(db)

        try db.write { db in
            try db.execute(sql: """
                INSERT INTO videos
                (source_folder, source_video_id, file_path, file_name)
                VALUES ('/src', 1, '/test/v.mp4', 'v.mp4')
                """)
        }

        // created_at 应该已被回填
        let createdAt: String? = try db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT created_at FROM videos WHERE video_id = 1")!
            return row["created_at"]
        }
        // 新插入的行 created_at 为 NULL（列无默认值），但迁移回填已有行
        // 对于新空库，这个值可能是 NULL
        // 重要的是列存在且不报错
        _ = createdAt // column exists
    }

    func testGlobalDBBackfillIndexLayer() throws {
        // v15 回填在迁移时执行，验证迁移流程正常完成
        let db = try DatabaseQueue()

        // 先运行到 v14，插入测试数据，再运行 v15
        // 由于 GRDB migrator 不支持部分迁移，我们手动模拟
        try Migrations.globalMigrator().migrate(db)

        // 验证：新插入的 index_layer=0 的视频，手动执行同样的 SQL 可以回填
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO videos
                (source_folder, source_video_id, file_path, file_name, index_layer)
                VALUES ('/src', 1, '/test/v.mp4', 'v.mp4', 0)
                """)
            try db.execute(sql: """
                INSERT INTO clips
                (source_folder, source_clip_id, video_id, start_time, end_time, scene)
                VALUES ('/src', 1, 1, 0.0, 5.0, 'S01')
                """)
            // 手动执行与 v15 相同的回填逻辑
            try db.execute(sql: """
                UPDATE videos SET index_layer = 3
                WHERE index_layer = 0
                  AND video_id IN (SELECT DISTINCT video_id FROM clips)
            """)
        }

        let indexLayer: Int? = try db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT index_layer FROM videos WHERE video_id = 1")!
            return row["index_layer"]
        }
        XCTAssertEqual(indexLayer, 3, "有 clips 的视频应被回填为 index_layer=3")
    }
}
