import XCTest
@testable import FindItCore
import GRDB

// MARK: - USearchVectorIndex Tests

final class USearchVectorIndexTests: XCTestCase {

    // MARK: - Basic Operations

    func testCreateEmptyIndex() throws {
        let index = try USearchVectorIndex(config: .clip768)
        let count = try index.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(index.dimensions, 768)
    }

    func testCreateCustomConfig() throws {
        let config = USearchVectorIndex.Config(
            dimensions: 512,
            connectivity: 32,
            quantization: .f32
        )
        let index = try USearchVectorIndex(config: config)
        XCTAssertEqual(index.dimensions, 512)
    }

    func testAddAndCount() throws {
        let index = try USearchVectorIndex(config: .clip768)
        let vector = makeRandomVector(dimensions: 768)

        try index.add(key: 1, vector: vector)
        XCTAssertEqual(try index.count, 1)

        try index.add(key: 2, vector: makeRandomVector(dimensions: 768))
        XCTAssertEqual(try index.count, 2)
    }

    func testAddBatch() throws {
        let index = try USearchVectorIndex(config: .clip768)
        let keys: [UInt64] = [10, 20, 30]
        let vectors = keys.map { _ in makeRandomVector(dimensions: 768) }

        try index.addBatch(keys: keys, vectors: vectors)
        XCTAssertEqual(try index.count, 3)
    }

    func testContains() throws {
        let index = try USearchVectorIndex(config: .clip768)
        try index.add(key: 42, vector: makeRandomVector(dimensions: 768))

        XCTAssertTrue(try index.contains(key: 42))
        XCTAssertFalse(try index.contains(key: 99))
    }

    func testRemove() throws {
        let index = try USearchVectorIndex(config: .clip768)
        try index.add(key: 1, vector: makeRandomVector(dimensions: 768))
        try index.add(key: 2, vector: makeRandomVector(dimensions: 768))
        XCTAssertEqual(try index.count, 2)

        try index.remove(key: 1)
        // USearch remove 是懒删除，count 可能仍为 2
        // 但 contains 应返回 false
        XCTAssertFalse(try index.contains(key: 1))
        XCTAssertTrue(try index.contains(key: 2))
    }

    func testClear() throws {
        let index = try USearchVectorIndex(config: .clip768)
        try index.add(key: 1, vector: makeRandomVector(dimensions: 768))
        try index.add(key: 2, vector: makeRandomVector(dimensions: 768))

        try index.clear()
        XCTAssertEqual(try index.count, 0)
    }

    // MARK: - Search

    func testSearchFindsNearestNeighbor() throws {
        let dims = 768
        let index = try USearchVectorIndex(config: .clip768)

        // 创建一个"目标"向量和一些随机向量
        let target = makeNormalizedVector(dimensions: dims, seed: 42)
        let similar = makeSimilarVector(to: target, noise: 0.1) // 与 target 相似
        let random1 = makeRandomVector(dimensions: dims)
        let random2 = makeRandomVector(dimensions: dims)

        try index.add(key: 1, vector: target)
        try index.add(key: 2, vector: similar)
        try index.add(key: 3, vector: random1)
        try index.add(key: 4, vector: random2)

        // 搜索与 target 最相似的
        let results = try index.search(query: target, count: 4)
        XCTAssertFalse(results.isEmpty)

        // 第一个结果应该是 target 本身 (距离 ≈ 0)
        XCTAssertEqual(results[0].key, 1)
        XCTAssertEqual(results[0].distance, 0, accuracy: 0.01)

        // 第二个应该是 similar (距离最小)
        XCTAssertEqual(results[1].key, 2)
    }

    func testSearchSimilarity() throws {
        let dims = 768
        let index = try USearchVectorIndex(config: .clip768)

        let target = makeNormalizedVector(dimensions: dims, seed: 42)
        let similar = makeSimilarVector(to: target, noise: 0.1)

        try index.add(key: 1, vector: target)
        try index.add(key: 2, vector: similar)
        try index.add(key: 3, vector: makeRandomVector(dimensions: dims))

        let results = try index.searchSimilarity(query: target, count: 3)
        XCTAssertFalse(results.isEmpty)

        // 第一个结果: similarity ≈ 1.0
        XCTAssertEqual(results[0].clipId, 1)
        XCTAssertEqual(results[0].similarity, 1.0, accuracy: 0.01)

        // 第二个: similar 向量应有较高相似度
        XCTAssertEqual(results[1].clipId, 2)
        XCTAssertGreaterThan(results[1].similarity, 0.3,
            "noise=0.1 在 768d 下 cosine_sim 通常 0.4-0.6")
    }

    func testSearchWithFilter() throws {
        let dims = 768
        let index = try USearchVectorIndex(config: .clip768)

        let target = makeNormalizedVector(dimensions: dims, seed: 42)
        try index.add(key: 1, vector: target)
        try index.add(key: 2, vector: makeSimilarVector(to: target, noise: 0.1))
        try index.add(key: 3, vector: makeRandomVector(dimensions: dims))

        // 只允许 key=2 和 key=3
        let allowed: Set<Int64> = [2, 3]
        let results = try index.searchSimilarity(query: target, count: 3, allowedClipIDs: allowed)

        // 不应包含 key=1
        XCTAssertTrue(results.allSatisfy { allowed.contains($0.clipId) })
        // 第一个结果应该是 similar (key=2)
        if !results.isEmpty {
            XCTAssertEqual(results[0].clipId, 2)
        }
    }

    func testSearchEmptyIndex() throws {
        let index = try USearchVectorIndex(config: .clip768)
        let query = makeRandomVector(dimensions: 768)
        let results = try index.search(query: query, count: 10)
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchCountLargerThanIndex() throws {
        let index = try USearchVectorIndex(config: .clip768)
        try index.add(key: 1, vector: makeRandomVector(dimensions: 768))
        try index.add(key: 2, vector: makeRandomVector(dimensions: 768))

        // 请求 100 个，但只有 2 个向量
        let results = try index.search(query: makeRandomVector(dimensions: 768), count: 100)
        XCTAssertEqual(results.count, 2)
    }

    // MARK: - Persistence

    func testSaveAndLoad() throws {
        let tmpDir = NSTemporaryDirectory()
        let path = (tmpDir as NSString).appendingPathComponent("test_index_\(UUID().uuidString).usearch")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let dims = 768
        let vector1 = makeNormalizedVector(dimensions: dims, seed: 1)
        let vector2 = makeNormalizedVector(dimensions: dims, seed: 2)

        // 创建并保存
        let index1 = try USearchVectorIndex(config: .clip768)
        try index1.add(key: 100, vector: vector1)
        try index1.add(key: 200, vector: vector2)
        try index1.save(to: path)

        // 重新加载
        let index2 = try USearchVectorIndex(config: .clip768)
        try index2.load(from: path)
        XCTAssertEqual(try index2.count, 2)
        XCTAssertTrue(try index2.contains(key: 100))
        XCTAssertTrue(try index2.contains(key: 200))

        // 搜索验证
        let results = try index2.search(query: vector1, count: 2)
        XCTAssertEqual(results[0].key, 100)
    }

    func testViewMmap() throws {
        let tmpDir = NSTemporaryDirectory()
        let path = (tmpDir as NSString).appendingPathComponent("test_mmap_\(UUID().uuidString).usearch")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let dims = 768
        let vector = makeNormalizedVector(dimensions: dims, seed: 42)

        // 创建并保存
        let index1 = try USearchVectorIndex(config: .clip768)
        try index1.add(key: 1, vector: vector)
        try index1.save(to: path)

        // mmap 查看
        let index2 = try USearchVectorIndex(config: .clip768)
        try index2.view(from: path)
        XCTAssertEqual(try index2.count, 1)

        // 搜索应正常工作
        let results = try index2.search(query: vector, count: 1)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].key, 1)
    }

    func testLoadOrCreate() throws {
        let tmpDir = NSTemporaryDirectory()
        let path = (tmpDir as NSString).appendingPathComponent("test_loc_\(UUID().uuidString).usearch")
        defer { try? FileManager.default.removeItem(atPath: path) }

        // 文件不存在 → 创建空索引
        let index1 = try USearchVectorIndex.loadOrCreate(at: path)
        XCTAssertEqual(try index1.count, 0)

        // 添加数据并保存
        try index1.add(key: 1, vector: makeRandomVector(dimensions: 768))
        try index1.save(to: path)

        // 文件存在 → 加载
        let index2 = try USearchVectorIndex.loadOrCreate(at: path)
        XCTAssertEqual(try index2.count, 1)
    }

    func testIndexFileExists() throws {
        let tmpDir = NSTemporaryDirectory()
        let path = (tmpDir as NSString).appendingPathComponent("test_exists_\(UUID().uuidString).usearch")
        XCTAssertFalse(USearchVectorIndex.indexFileExists(at: path))

        let index = try USearchVectorIndex(config: .clip768)
        try index.add(key: 1, vector: makeRandomVector(dimensions: 768))
        try index.save(to: path)
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertTrue(USearchVectorIndex.indexFileExists(at: path))
    }

    // MARK: - Key Conversion

    func testClipIdToKeyConversion() {
        // 正数
        let key1 = USearchVectorIndex.clipIdToKey(42)
        XCTAssertEqual(USearchVectorIndex.keyToClipId(key1), 42)

        // 零
        let key0 = USearchVectorIndex.clipIdToKey(0)
        XCTAssertEqual(USearchVectorIndex.keyToClipId(key0), 0)

        // 大正数
        let keyLarge = USearchVectorIndex.clipIdToKey(Int64.max)
        XCTAssertEqual(USearchVectorIndex.keyToClipId(keyLarge), Int64.max)
    }

    // MARK: - Dual Index Independence

    func testDualIndexesAreIndependent() throws {
        let tmpDir = NSTemporaryDirectory()
        let clipPath = (tmpDir as NSString).appendingPathComponent("clip_\(UUID().uuidString).usearch")
        let textPath = (tmpDir as NSString).appendingPathComponent("text_\(UUID().uuidString).usearch")
        defer {
            try? FileManager.default.removeItem(atPath: clipPath)
            try? FileManager.default.removeItem(atPath: textPath)
        }

        // 两个独立索引，都是 768 维
        let clipIndex = try USearchVectorIndex(config: .clip768)
        let textIndex = try USearchVectorIndex(config: .textEmb768)

        // 相同 key 添加不同向量
        let clipVector = makeNormalizedVector(dimensions: 768, seed: 1)
        let textVector = makeNormalizedVector(dimensions: 768, seed: 2)

        try clipIndex.add(key: 1, vector: clipVector)
        try textIndex.add(key: 1, vector: textVector)

        // 各自独立搜索
        let clipResults = try clipIndex.search(query: clipVector, count: 1)
        let textResults = try textIndex.search(query: textVector, count: 1)

        XCTAssertEqual(clipResults[0].key, 1)
        XCTAssertEqual(textResults[0].key, 1)
        // 距离应该接近 0（自身匹配）
        XCTAssertEqual(clipResults[0].distance, 0, accuracy: 0.01)
        XCTAssertEqual(textResults[0].distance, 0, accuracy: 0.01)

        // 跨索引搜索不应混淆
        // 用 textVector 在 clipIndex 中搜索 → 距离应大于 0
        let crossResults = try clipIndex.search(query: textVector, count: 1)
        XCTAssertGreaterThan(crossResults[0].distance, 0.01,
            "不同空间的向量在同一索引中的距离应明显大于 0")

        // 保存/加载后仍然独立
        try clipIndex.save(to: clipPath)
        try textIndex.save(to: textPath)

        let clipIndex2 = try USearchVectorIndex.loadOrCreate(at: clipPath)
        let textIndex2 = try USearchVectorIndex.loadOrCreate(at: textPath)

        XCTAssertEqual(try clipIndex2.count, 1)
        XCTAssertEqual(try textIndex2.count, 1)
    }

    // MARK: - Reserve

    func testReserveCapacity() throws {
        let index = try USearchVectorIndex(config: .clip768)
        try index.reserve(10000)
        XCTAssertEqual(try index.count, 0) // 预分配不改变 count
    }

    // MARK: - Config

    func testConfigDefaults() {
        let clip = USearchVectorIndex.Config.clip768
        XCTAssertEqual(clip.dimensions, 768)
        XCTAssertEqual(clip.connectivity, 16)

        let text = USearchVectorIndex.Config.textEmb768
        XCTAssertEqual(text.dimensions, 768)
        XCTAssertEqual(text.connectivity, 16)
    }

    func testIndexPaths() {
        let clipPath = USearchVectorIndex.IndexPath.clipIndex
        XCTAssertTrue(clipPath.hasSuffix("FindIt/clip.usearch"))

        let textPath = USearchVectorIndex.IndexPath.textIndex
        XCTAssertTrue(textPath.hasSuffix("FindIt/text.usearch"))

        // 两个路径不同
        XCTAssertNotEqual(clipPath, textPath)
    }

    // MARK: - Helpers

    private func makeRandomVector(dimensions: Int) -> [Float] {
        (0..<dimensions).map { _ in Float.random(in: -1...1) }
    }

    private func makeNormalizedVector(dimensions: Int, seed: UInt64) -> [Float] {
        srand48(Int(seed))
        var vector = (0..<dimensions).map { _ in Float(drand48() * 2 - 1) }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            vector = vector.map { $0 / norm }
        }
        return vector
    }

    private func makeSimilarVector(to base: [Float], noise: Float) -> [Float] {
        var result = base.map { $0 + Float.random(in: -noise...noise) }
        let norm = sqrt(result.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            result = result.map { $0 / norm }
        }
        return result
    }
}

// MARK: - VectorIndexEngine Protocol Tests

final class VectorIndexEngineProtocolTests: XCTestCase {

    func testConformsToProtocol() throws {
        let index: any VectorIndexEngine = try USearchVectorIndex(config: .clip768)
        XCTAssertEqual(index.dimensions, 768)
        XCTAssertEqual(try index.count, 0)
    }

    func testProtocolAddAndSearch() throws {
        let index: any VectorIndexEngine = try USearchVectorIndex(config: .clip768)
        let vector = (0..<768).map { _ in Float.random(in: -1...1) }
        try index.add(key: 1, vector: vector)
        XCTAssertEqual(try index.count, 1)

        let results = try index.search(query: vector, count: 1)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].key, 1)
    }
}

// MARK: - VectorSearchResult Tests

final class VectorSearchResultTests: XCTestCase {

    func testInit() {
        let result = VectorSearchResult(clipId: 42, similarity: 0.95)
        XCTAssertEqual(result.clipId, 42)
        XCTAssertEqual(result.similarity, 0.95)
    }
}

// MARK: - Schema Migration Tests

final class ClipVectorsMigrationTests: XCTestCase {

    func testFolderMigrationCreatesClipVectorsTable() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = Migrations.folderMigrator()
        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("clip_vectors"))

            // 验证列
            let columns = try db.columns(in: "clip_vectors")
            let columnNames = columns.map { $0.name }
            XCTAssertTrue(columnNames.contains("vector_id"))
            XCTAssertTrue(columnNames.contains("clip_id"))
            XCTAssertTrue(columnNames.contains("model_name"))
            XCTAssertTrue(columnNames.contains("dimensions"))
            XCTAssertTrue(columnNames.contains("vector"))
            XCTAssertTrue(columnNames.contains("created_at"))
        }
    }

    func testGlobalMigrationCreatesClipVectorsTable() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = Migrations.globalMigrator()
        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("clip_vectors"))

            let columns = try db.columns(in: "clip_vectors")
            let columnNames = columns.map { $0.name }
            XCTAssertTrue(columnNames.contains("vector_id"))
            XCTAssertTrue(columnNames.contains("clip_id"))
            XCTAssertTrue(columnNames.contains("source_folder"))
            XCTAssertTrue(columnNames.contains("source_vector_id"))
            XCTAssertTrue(columnNames.contains("model_name"))
            XCTAssertTrue(columnNames.contains("dimensions"))
            XCTAssertTrue(columnNames.contains("vector"))
        }
    }

    func testFolderClipVectorsUniqueConstraint() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = Migrations.folderMigrator()
        try migrator.migrate(dbQueue)

        // 插入一个 clip
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO watched_folders (folder_path) VALUES ('/test')
                """)
            try db.execute(sql: """
                INSERT INTO videos (folder_id, file_path, file_name, created_at)
                VALUES (1, '/test/video.mp4', 'video.mp4', datetime('now'))
                """)
            try db.execute(sql: """
                INSERT INTO clips (video_id, start_time, end_time)
                VALUES (1, 0.0, 5.0)
                """)
        }

        // 插入向量
        let vectorData = Data(repeating: 0, count: 768 * 4)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO clip_vectors (clip_id, model_name, dimensions, vector)
                VALUES (1, 'siglip2-base', 768, ?)
                """, arguments: [vectorData])
        }

        // 重复插入应失败 (UNIQUE constraint)
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO clip_vectors (clip_id, model_name, dimensions, vector)
                VALUES (1, 'siglip2-base', 768, ?)
                """, arguments: [vectorData])
        })
    }

    func testClipVectorsCascadeDelete() throws {
        let dbQueue = try DatabaseQueue()
        // 启用外键约束
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let migrator = Migrations.folderMigrator()
        try migrator.migrate(dbQueue)

        // 创建 clip + vector
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO watched_folders (folder_path) VALUES ('/test')
                """)
            try db.execute(sql: """
                INSERT INTO videos (folder_id, file_path, file_name, created_at)
                VALUES (1, '/test/video.mp4', 'video.mp4', datetime('now'))
                """)
            try db.execute(sql: """
                INSERT INTO clips (video_id, start_time, end_time)
                VALUES (1, 0.0, 5.0)
                """)
            try db.execute(sql: """
                INSERT INTO clip_vectors (clip_id, model_name, dimensions, vector)
                VALUES (1, 'siglip2-base', 768, ?)
                """, arguments: [Data(repeating: 0, count: 768 * 4)])
        }

        // 验证 vector 存在
        let countBefore = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip_vectors") ?? 0
        }
        XCTAssertEqual(countBefore, 1)

        // 删除 clip → vector 应级联删除
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM clips WHERE clip_id = 1")
        }

        let countAfter = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip_vectors") ?? 0
        }
        XCTAssertEqual(countAfter, 0)
    }
}

// MARK: - VectorIndexRebuilder Tests

final class VectorIndexRebuilderTests: XCTestCase {

    func testRebuildFromEmptyDB() throws {
        let tmpDir = NSTemporaryDirectory()
        let indexPath = (tmpDir as NSString).appendingPathComponent("rebuild_empty_\(UUID().uuidString).usearch")
        defer { try? FileManager.default.removeItem(atPath: indexPath) }

        let dbQueue = try DatabaseQueue()
        let migrator = Migrations.globalMigrator()
        try migrator.migrate(dbQueue)

        let result = try VectorIndexRebuilder.rebuild(
            from: dbQueue,
            modelName: "siglip2-base",
            savePath: indexPath
        )

        XCTAssertEqual(result.vectorCount, 0)
        XCTAssertTrue(USearchVectorIndex.indexFileExists(at: indexPath))
    }

    func testRebuildWithVectors() throws {
        let tmpDir = NSTemporaryDirectory()
        let indexPath = (tmpDir as NSString).appendingPathComponent("rebuild_\(UUID().uuidString).usearch")
        defer { try? FileManager.default.removeItem(atPath: indexPath) }

        let dbQueue = try DatabaseQueue()
        let migrator = Migrations.globalMigrator()
        try migrator.migrate(dbQueue)

        // 插入测试数据
        let dims = 768
        let vectorCount = 50
        try dbQueue.write { db in
            // 全局库 videos
            try db.execute(sql: """
                INSERT INTO videos (source_folder, source_video_id, file_path, file_name)
                VALUES ('/test', 1, '/test/video.mp4', 'video.mp4')
                """)

            for i in 1...vectorCount {
                // 全局库 clips
                try db.execute(sql: """
                    INSERT INTO clips (source_folder, source_clip_id, video_id, start_time, end_time)
                    VALUES ('/test', ?, 1, ?, ?)
                    """, arguments: [i, Double(i - 1) * 5.0, Double(i) * 5.0])

                // clip_vectors
                var vector = [Float](repeating: 0, count: dims)
                for j in 0..<dims { vector[j] = Float.random(in: -1...1) }
                let data = EmbeddingUtils.serializeEmbedding(vector)
                try db.execute(sql: """
                    INSERT INTO clip_vectors (clip_id, source_folder, source_vector_id, model_name, dimensions, vector)
                    VALUES (?, '/test', ?, 'siglip2-base', ?, ?)
                    """, arguments: [i, i, dims, data])
            }
        }

        let result = try VectorIndexRebuilder.rebuild(
            from: dbQueue,
            modelName: "siglip2-base",
            savePath: indexPath
        )

        XCTAssertEqual(result.vectorCount, vectorCount)
        XCTAssertGreaterThan(result.duration, 0)

        // 验证索引可加载和搜索
        let index = try USearchVectorIndex.loadOrCreate(at: indexPath)
        XCTAssertEqual(try index.count, vectorCount)

        let query = [Float](repeating: 0.5, count: dims)
        let searchResults = try index.search(query: query, count: 5)
        XCTAssertEqual(searchResults.count, 5)
    }

    func testNeedsRebuildWhenFileNotExists() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = Migrations.globalMigrator()
        try migrator.migrate(dbQueue)

        let needs = try VectorIndexRebuilder.needsRebuild(
            indexPath: "/nonexistent/path.usearch",
            db: dbQueue,
            modelName: "siglip2-base"
        )
        XCTAssertTrue(needs)
    }

    func testNeedsRebuildWhenEmptyDB() throws {
        let tmpDir = NSTemporaryDirectory()
        let indexPath = (tmpDir as NSString).appendingPathComponent("needs_rebuild_\(UUID().uuidString).usearch")
        defer { try? FileManager.default.removeItem(atPath: indexPath) }

        let dbQueue = try DatabaseQueue()
        let migrator = Migrations.globalMigrator()
        try migrator.migrate(dbQueue)

        // 创建空索引文件
        let index = try USearchVectorIndex(config: .clip768)
        try index.save(to: indexPath)

        let needs = try VectorIndexRebuilder.needsRebuild(
            indexPath: indexPath,
            db: dbQueue,
            modelName: "siglip2-base"
        )
        XCTAssertFalse(needs, "空数据库不需要重建")
    }
}

// MARK: - SyncEngine clip_vectors Tests

final class SyncEngineClipVectorsTests: XCTestCase {

    func testSyncClipVectors() throws {
        // 文件夹库
        let folderDB = try DatabaseQueue()
        let folderMigrator = Migrations.folderMigrator()
        try folderMigrator.migrate(folderDB)

        // 全局库
        let globalDB = try DatabaseQueue()
        let globalMigrator = Migrations.globalMigrator()
        try globalMigrator.migrate(globalDB)

        // 在文件夹库中创建测试数据
        try folderDB.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: """
                INSERT INTO watched_folders (folder_path) VALUES ('/test/videos')
                """)
            try db.execute(sql: """
                INSERT INTO videos (folder_id, file_path, file_name, created_at, index_status)
                VALUES (1, '/test/videos/beach.mp4', 'beach.mp4', datetime('now'), 'completed')
                """)
            try db.execute(sql: """
                INSERT INTO clips (video_id, start_time, end_time)
                VALUES (1, 0.0, 5.0)
                """)
            try db.execute(sql: """
                INSERT INTO clips (video_id, start_time, end_time)
                VALUES (1, 5.0, 10.0)
                """)

            // 添加 CLIP 向量
            let vector1 = EmbeddingUtils.serializeEmbedding([Float](repeating: 0.1, count: 768))
            let vector2 = EmbeddingUtils.serializeEmbedding([Float](repeating: 0.2, count: 768))
            try db.execute(sql: """
                INSERT INTO clip_vectors (clip_id, model_name, dimensions, vector)
                VALUES (1, 'siglip2-base', 768, ?)
                """, arguments: [vector1])
            try db.execute(sql: """
                INSERT INTO clip_vectors (clip_id, model_name, dimensions, vector)
                VALUES (2, 'siglip2-base', 768, ?)
                """, arguments: [vector2])
        }

        // 同步
        let result = try SyncEngine.sync(
            folderPath: "/test/videos",
            folderDB: folderDB,
            globalDB: globalDB,
            force: true
        )

        XCTAssertEqual(result.syncedVideos, 1)
        XCTAssertEqual(result.syncedClips, 2)
        XCTAssertEqual(result.syncedVectors, 2)

        // 验证全局库中 clip_vectors 数据
        let globalVectors = try globalDB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip_vectors") ?? 0
        }
        XCTAssertEqual(globalVectors, 2)

        // 验证 source_folder 正确
        let folders = try globalDB.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT source_folder FROM clip_vectors")
        }
        XCTAssertEqual(folders, ["/test/videos"])
    }

    func testRemoveFolderDataCleansClipVectors() throws {
        let globalDB = try DatabaseQueue()
        let globalMigrator = Migrations.globalMigrator()
        try globalMigrator.migrate(globalDB)

        // 直接在全局库插入测试数据
        try globalDB.write { db in
            try db.execute(sql: """
                INSERT INTO videos (source_folder, source_video_id, file_path, file_name)
                VALUES ('/test', 1, '/test/video.mp4', 'video.mp4')
                """)
            try db.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, video_id, start_time, end_time)
                VALUES ('/test', 1, 1, 0.0, 5.0)
                """)
            try db.execute(sql: """
                INSERT INTO clip_vectors (clip_id, source_folder, source_vector_id, model_name, dimensions, vector)
                VALUES (1, '/test', 1, 'siglip2-base', 768, ?)
                """, arguments: [Data(repeating: 0, count: 768 * 4)])
        }

        // 删除文件夹数据
        try SyncEngine.removeFolderData(folderPath: "/test", from: globalDB)

        let vectorCount = try globalDB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip_vectors") ?? 0
        }
        XCTAssertEqual(vectorCount, 0)
    }
}
