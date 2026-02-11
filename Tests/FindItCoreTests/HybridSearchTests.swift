import XCTest
import GRDB
@testable import FindItCore

final class HybridSearchTests: XCTestCase {

    // MARK: - Helper

    /// 创建内存数据库并运行全局库迁移
    private func makeGlobalDB() throws -> DatabaseQueue {
        let db = try DatabaseQueue(path: ":memory:")
        let migrator = Migrations.globalMigrator()
        try migrator.migrate(db)
        return db
    }

    /// 创建内存数据库并运行文件夹库迁移
    private func makeFolderDB() throws -> DatabaseQueue {
        let db = try DatabaseQueue(path: ":memory:")
        let migrator = Migrations.folderMigrator()
        try migrator.migrate(db)
        return db
    }

    /// 向全局库插入测试 clip（含可选 embedding）
    private func insertGlobalClip(
        _ db: DatabaseQueue,
        clipId: Int64? = nil,
        sourceFolder: String = "/test",
        sourceClipId: Int64,
        videoId: Int64? = nil,
        startTime: Double = 0.0,
        endTime: Double = 10.0,
        scene: String? = nil,
        description: String? = nil,
        tags: String? = nil,
        transcript: String? = nil,
        embedding: Data? = nil,
        embeddingModel: String? = nil
    ) throws {
        try db.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO clips
                    (source_folder, source_clip_id, video_id, start_time, end_time,
                     scene, description, tags, transcript, embedding, embedding_model)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    sourceFolder, sourceClipId, videoId,
                    startTime, endTime,
                    scene, description, tags, transcript, embedding, embeddingModel
                ])
        }
    }

    // MARK: - v2 Migration

    func testV2MigrationFolderDB() throws {
        let db = try makeFolderDB()
        // 验证 embedding_model 列存在
        try db.write { dbConn in
            var clip = Clip(startTime: 0.0, endTime: 5.0, embeddingModel: "gemini")
            try clip.insert(dbConn)
            let fetched = try Clip.fetchOne(dbConn)
            XCTAssertEqual(fetched?.embeddingModel, "gemini")
        }
    }

    func testV2MigrationGlobalDB() throws {
        let db = try makeGlobalDB()
        // 验证 embedding_model 列存在
        try db.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, start_time, end_time, embedding_model)
                VALUES ('test', 1, 0.0, 5.0, 'nl-embedding')
                """)
            let model = try String.fetchOne(dbConn, sql: "SELECT embedding_model FROM clips WHERE source_clip_id = 1")
            XCTAssertEqual(model, "nl-embedding")
        }
    }

    // MARK: - SearchMode

    func testSearchModeRawValues() {
        XCTAssertEqual(SearchEngine.SearchMode.fts.rawValue, "fts")
        XCTAssertEqual(SearchEngine.SearchMode.vector.rawValue, "vector")
        XCTAssertEqual(SearchEngine.SearchMode.hybrid.rawValue, "hybrid")
        XCTAssertEqual(SearchEngine.SearchMode.auto.rawValue, "auto")
    }

    // MARK: - SearchWeights

    func testSearchWeightsDefault() {
        let w = SearchEngine.SearchWeights.default
        XCTAssertEqual(w.ftsWeight, 0.4, accuracy: 0.01)
        XCTAssertEqual(w.vectorWeight, 0.6, accuracy: 0.01)
    }

    func testSearchWeightsExactMatch() {
        let w = SearchEngine.SearchWeights.exactMatch
        XCTAssertEqual(w.ftsWeight, 0.9, accuracy: 0.01)
        XCTAssertEqual(w.vectorWeight, 0.1, accuracy: 0.01)
    }

    func testSearchWeightsSemantic() {
        let w = SearchEngine.SearchWeights.semantic
        XCTAssertEqual(w.ftsWeight, 0.2, accuracy: 0.01)
        XCTAssertEqual(w.vectorWeight, 0.8, accuracy: 0.01)
    }

    // MARK: - resolveWeights

    func testResolveWeightsFTSMode() {
        let w = SearchEngine.resolveWeights(query: "test", mode: .fts, hasEmbedding: true)
        XCTAssertEqual(w.ftsWeight, 1.0)
        XCTAssertEqual(w.vectorWeight, 0.0)
    }

    func testResolveWeightsVectorMode() {
        let w = SearchEngine.resolveWeights(query: "test", mode: .vector, hasEmbedding: true)
        XCTAssertEqual(w.ftsWeight, 0.0)
        XCTAssertEqual(w.vectorWeight, 1.0)
    }

    func testResolveWeightsAutoQuoted() {
        let w = SearchEngine.resolveWeights(query: "\"精确匹配\"", mode: .auto, hasEmbedding: true)
        XCTAssertEqual(w.ftsWeight, 0.9, accuracy: 0.01)
        XCTAssertEqual(w.vectorWeight, 0.1, accuracy: 0.01)
    }

    func testResolveWeightsAutoLongQuery() {
        let w = SearchEngine.resolveWeights(query: "一个女生在海边看日落的场景", mode: .auto, hasEmbedding: true)
        XCTAssertEqual(w.ftsWeight, 0.2, accuracy: 0.01)
        XCTAssertEqual(w.vectorWeight, 0.8, accuracy: 0.01)
    }

    func testResolveWeightsAutoShortQuery() {
        let w = SearchEngine.resolveWeights(query: "海边日落", mode: .auto, hasEmbedding: true)
        XCTAssertEqual(w.ftsWeight, 0.4, accuracy: 0.01)
        XCTAssertEqual(w.vectorWeight, 0.6, accuracy: 0.01)
    }

    func testResolveWeightsAutoNoEmbedding() {
        let w = SearchEngine.resolveWeights(query: "test", mode: .auto, hasEmbedding: false)
        XCTAssertEqual(w.ftsWeight, 1.0)
        XCTAssertEqual(w.vectorWeight, 0.0)
    }

    // MARK: - resolveWeights CJK 阈值

    func testResolveWeightsCJKMediumQuery() {
        // "艺术工作室绘画" = 7 字符, CJK 阈值 5, 7 > 5 → semantic
        let w = SearchEngine.resolveWeights(query: "艺术工作室绘画", mode: .auto, hasEmbedding: true)
        XCTAssertEqual(w.ftsWeight, 0.2, accuracy: 0.01)
        XCTAssertEqual(w.vectorWeight, 0.8, accuracy: 0.01)
    }

    func testResolveWeightsEnglishMediumQuery() {
        // "beach scene" = 11 字符, 非 CJK 阈值 10, 11 > 10 → semantic
        let w = SearchEngine.resolveWeights(query: "beach scene", mode: .auto, hasEmbedding: true)
        XCTAssertEqual(w.ftsWeight, 0.2, accuracy: 0.01)
        XCTAssertEqual(w.vectorWeight, 0.8, accuracy: 0.01)
    }

    func testResolveWeightsEnglishShortQuery() {
        // "beach sun" = 9 字符, 非 CJK 阈值 10, 9 <= 10 → default
        let w = SearchEngine.resolveWeights(query: "beach sun", mode: .auto, hasEmbedding: true)
        XCTAssertEqual(w.ftsWeight, 0.4, accuracy: 0.01)
        XCTAssertEqual(w.vectorWeight, 0.6, accuracy: 0.01)
    }

    // MARK: - v3 Migration (index_status 索引)

    func testV3MigrationFolderDB() throws {
        let db = try makeFolderDB()
        // 验证索引存在
        let indexExists = try db.read { dbConn in
            try Bool.fetchOne(dbConn, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master
                WHERE type = 'index' AND name = 'idx_videos_index_status'
                """)
        }
        XCTAssertEqual(indexExists, true, "idx_videos_index_status 索引应存在")
    }

    // MARK: - fusionSearch 归一化正确性

    func testFusionSearchNormalization() throws {
        let db = try makeGlobalDB()

        // 插入 3 个 clip，分别有不同的 FTS 相关度和向量相似度
        let vec1: [Float] = [1.0, 0.0, 0.0]  // 与 query 最相似
        let vec2: [Float] = [0.7, 0.7, 0.0]  // 中等
        let vec3: [Float] = [0.0, 0.0, 1.0]  // 最不相似

        try insertGlobalClip(db, sourceClipId: 1, description: "海边日落沙滩",
                             tags: "海滩 日落 沙滩", embedding: EmbeddingUtils.serializeEmbedding(vec1),
                             embeddingModel: "test")
        try insertGlobalClip(db, sourceClipId: 2, description: "海边散步",
                             tags: "海滩 散步", embedding: EmbeddingUtils.serializeEmbedding(vec2),
                             embeddingModel: "test")
        try insertGlobalClip(db, sourceClipId: 3, description: "森林漫步",
                             tags: "森林 散步", embedding: EmbeddingUtils.serializeEmbedding(vec3),
                             embeddingModel: "test")

        let queryVec: [Float] = [1.0, 0.0, 0.0]
        let results = try db.read { dbConn in
            try SearchEngine.hybridSearch(
                dbConn, query: "海滩",
                queryEmbedding: queryVec,
                embeddingModel: "test",
                mode: .hybrid
            )
        }

        // 应该有结果
        XCTAssertGreaterThan(results.count, 0)
        // 所有 finalScore 应在 [0, 1] 范围内
        for result in results {
            if let score = result.finalScore {
                XCTAssertGreaterThanOrEqual(score, 0.0, "finalScore 不应小于 0")
                XCTAssertLessThanOrEqual(score, 1.0, "finalScore 不应大于 1")
            }
        }
        // clip 1 和 clip 2 都应在结果中（都含"海滩"相关文本）
        // 注意：BM25 对短文档有加成，clip 2 的 FTS 分数可能高于 clip 1，
        // 因此不对具体排名做断言，只验证都在结果集中
        let resultClipIds = Set(results.map { $0.sourceClipId })
        XCTAssertTrue(resultClipIds.contains(1), "clip 1 应在结果中")
        XCTAssertTrue(resultClipIds.contains(2), "clip 2 应在结果中")
    }

    // MARK: - hybridSearch FTS fallback

    func testHybridSearchFTSFallback() throws {
        let db = try makeGlobalDB()
        try insertGlobalClip(db, sourceClipId: 1, scene: "海边", description: "海边日落", tags: "海滩 日落")

        let results = try db.read { dbConn in
            try SearchEngine.hybridSearch(dbConn, query: "海滩", queryEmbedding: nil, mode: .auto)
        }

        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results.first?.similarity)
    }

    // MARK: - vectorSearch

    func testVectorSearch() throws {
        let db = try makeGlobalDB()

        // 插入带 embedding 的 clip
        let vec1: [Float] = [1.0, 0.0, 0.0]
        let vec2: [Float] = [0.0, 1.0, 0.0]
        let data1 = EmbeddingUtils.serializeEmbedding(vec1)
        let data2 = EmbeddingUtils.serializeEmbedding(vec2)

        try insertGlobalClip(db, sourceClipId: 1, scene: "海滩",
                             embedding: data1, embeddingModel: "test")
        try insertGlobalClip(db, sourceClipId: 2, scene: "森林",
                             embedding: data2, embeddingModel: "test")

        // 搜索向量接近 vec1
        let queryVec: [Float] = [0.9, 0.1, 0.0]
        let results = try db.read { dbConn in
            try SearchEngine.vectorSearch(dbConn, queryEmbedding: queryVec, embeddingModel: "test")
        }

        XCTAssertEqual(results.count, 2)
        // 第一个应该是 vec1（更相似）
        XCTAssertEqual(results.first?.sourceClipId, 1)
        XCTAssertGreaterThan(results.first?.similarity ?? 0, results.last?.similarity ?? 1)
    }

    func testVectorSearchFiltersByModel() throws {
        let db = try makeGlobalDB()

        let vec: [Float] = [1.0, 0.0, 0.0]
        let data = EmbeddingUtils.serializeEmbedding(vec)

        try insertGlobalClip(db, sourceClipId: 1, embedding: data, embeddingModel: "gemini")
        try insertGlobalClip(db, sourceClipId: 2, embedding: data, embeddingModel: "nl-embedding")

        let results = try db.read { dbConn in
            try SearchEngine.vectorSearch(dbConn, queryEmbedding: vec, embeddingModel: "gemini")
        }

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.sourceClipId, 1)
    }

    // MARK: - SyncEngine embedding_model

    func testSyncEngineEmbeddingModel() throws {
        let folderDB = try makeFolderDB()
        let globalDB = try makeGlobalDB()

        // 设置文件夹库
        try folderDB.write { db in
            try db.execute(sql: "INSERT INTO watched_folders (folder_path) VALUES ('/test')")
            try db.execute(sql: """
                INSERT INTO videos (folder_id, file_path, file_name, index_status) VALUES (1, '/test/v.mp4', 'v.mp4', 'completed')
                """)
        }

        // 插入带 embedding_model 的 clip
        let vec: [Float] = [0.1, 0.2, 0.3]
        let data = EmbeddingUtils.serializeEmbedding(vec)
        try folderDB.write { db in
            var clip = Clip(
                videoId: 1, startTime: 0.0, endTime: 5.0,
                embedding: data, embeddingModel: "gemini"
            )
            try clip.insert(db)
        }

        // 同步
        let result = try SyncEngine.sync(folderPath: "/test", folderDB: folderDB, globalDB: globalDB)
        XCTAssertEqual(result.syncedClips, 1)

        // 验证全局库
        let model = try globalDB.read { db in
            try String.fetchOne(db, sql: "SELECT embedding_model FROM clips WHERE source_clip_id = 1")
        }
        XCTAssertEqual(model, "gemini")
    }

    // MARK: - SearchResult

    func testSearchResultSimilarityAndFinalScore() {
        let result = SearchEngine.SearchResult(
            clipId: 1, sourceFolder: "/test", sourceClipId: 1,
            videoId: nil, filePath: nil, fileName: nil,
            startTime: 0, endTime: 10,
            scene: nil, clipDescription: nil,
            subjects: nil, actions: nil, objects: nil,
            tags: nil, transcript: nil,
            thumbnailPath: nil, userTags: nil,
            rating: 0, colorLabel: nil,
            shotType: nil, mood: nil,
            lighting: nil, colors: nil,
            rank: -5.0, similarity: 0.85, finalScore: 0.72
        )
        XCTAssertEqual(result.similarity, 0.85)
        XCTAssertEqual(result.finalScore, 0.72)
    }
}
