import XCTest
import GRDB
@testable import FindItCore

final class VectorStoreTests: XCTestCase {

    // MARK: - Helper

    /// 创建一个指定维度的随机单位向量
    private func randomVector(dimensions: Int) -> [Float] {
        var v = (0..<dimensions).map { _ in Float.random(in: -1...1) }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return v }
        v = v.map { $0 / norm }
        return v
    }

    /// 序列化 Float 数组为 Data（与 EmbeddingUtils.serializeEmbedding 一致）
    private func serialize(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    // MARK: - Init

    func testInitSetsProperties() async {
        let store = VectorStore(dimensions: 768, embeddingModel: "gemini")
        let count = await store.count
        let isEmpty = await store.isEmpty
        XCTAssertEqual(count, 0)
        XCTAssertTrue(isEmpty)
    }

    // MARK: - Load

    func testLoadBatchEntries() async {
        let store = VectorStore(dimensions: 4, embeddingModel: "test")
        let v1: [Float] = [1, 0, 0, 0]
        let v2: [Float] = [0, 1, 0, 0]
        let v3: [Float] = [0, 0, 1, 0]

        await store.load(entries: [
            (clipId: 1, embeddingData: serialize(v1)),
            (clipId: 2, embeddingData: serialize(v2)),
            (clipId: 3, embeddingData: serialize(v3)),
        ])

        let count = await store.count
        XCTAssertEqual(count, 3)
    }

    func testLoadSkipsWrongDimensions() async {
        let store = VectorStore(dimensions: 4, embeddingModel: "test")
        let wrongDim: [Float] = [1, 0, 0] // 3 维，期望 4 维

        await store.load(entries: [
            (clipId: 1, embeddingData: serialize(wrongDim)),
        ])

        let count = await store.count
        XCTAssertEqual(count, 0)
    }

    func testLoadSkipsZeroVector() async {
        let store = VectorStore(dimensions: 4, embeddingModel: "test")
        let zero: [Float] = [0, 0, 0, 0]

        await store.load(entries: [
            (clipId: 1, embeddingData: serialize(zero)),
        ])

        let count = await store.count
        XCTAssertEqual(count, 0)
    }

    func testLoadReplacesExistingData() async {
        let store = VectorStore(dimensions: 4, embeddingModel: "test")
        let v1: [Float] = [1, 0, 0, 0]
        let v2: [Float] = [0, 1, 0, 0]

        await store.load(entries: [(clipId: 1, embeddingData: serialize(v1))])
        let count1 = await store.count
        XCTAssertEqual(count1, 1)

        // 重新 load 应替换全部数据
        await store.load(entries: [
            (clipId: 10, embeddingData: serialize(v1)),
            (clipId: 20, embeddingData: serialize(v2)),
        ])
        let count2 = await store.count
        XCTAssertEqual(count2, 2)
    }

    // MARK: - Append / Remove

    func testAppendNewVector() async {
        let store = VectorStore(dimensions: 4, embeddingModel: "test")
        let v: [Float] = [1, 0, 0, 0]

        await store.append(clipId: 42, embedding: v)
        let count = await store.count
        XCTAssertEqual(count, 1)
    }

    func testAppendReplacesExisting() async {
        let store = VectorStore(dimensions: 4, embeddingModel: "test")
        let v1: [Float] = [1, 0, 0, 0]
        let v2: [Float] = [0, 1, 0, 0]

        await store.append(clipId: 1, embedding: v1)
        await store.append(clipId: 1, embedding: v2)

        let count = await store.count
        XCTAssertEqual(count, 1)

        // 搜索验证 v2 生效（v2 与自身相似度为 1）
        let results = await store.search(query: v2, limit: 1)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].clipId, 1)
        XCTAssertEqual(results[0].similarity, 1.0, accuracy: 0.001)
    }

    func testRemoveVector() async {
        let store = VectorStore(dimensions: 4, embeddingModel: "test")
        await store.append(clipId: 1, embedding: [1, 0, 0, 0])
        await store.append(clipId: 2, embedding: [0, 1, 0, 0])

        await store.remove(clipId: 1)
        let count = await store.count
        XCTAssertEqual(count, 1)

        // 剩余的是 clipId=2
        let results = await store.search(query: [0, 1, 0, 0], limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].clipId, 2)
    }

    func testRemoveNonExistentDoesNothing() async {
        let store = VectorStore(dimensions: 4, embeddingModel: "test")
        await store.append(clipId: 1, embedding: [1, 0, 0, 0])
        await store.remove(clipId: 999)
        let count = await store.count
        XCTAssertEqual(count, 1)
    }

    // MARK: - Search

    func testSearchExactMatch() async {
        let store = VectorStore(dimensions: 4, embeddingModel: "test")
        await store.load(entries: [
            (clipId: 1, embeddingData: serialize([1, 0, 0, 0])),
            (clipId: 2, embeddingData: serialize([0, 1, 0, 0])),
            (clipId: 3, embeddingData: serialize([0, 0, 1, 0])),
        ])

        let results = await store.search(query: [1, 0, 0, 0], limit: 3)
        XCTAssertEqual(results.count, 3)
        // 最相似的应该是 clipId=1（余弦相似度=1.0）
        XCTAssertEqual(results[0].clipId, 1)
        XCTAssertEqual(results[0].similarity, 1.0, accuracy: 0.001)
        // 正交向量应该相似度为 0
        XCTAssertEqual(results[1].similarity, 0.0, accuracy: 0.001)
    }

    func testSearchReturnsTopK() async {
        let store = VectorStore(dimensions: 4, embeddingModel: "test")
        // 构造已知相似度的向量
        await store.load(entries: [
            (clipId: 1, embeddingData: serialize([1, 0, 0, 0])),
            (clipId: 2, embeddingData: serialize([0.9, 0.1, 0, 0])),
            (clipId: 3, embeddingData: serialize([0.5, 0.5, 0, 0])),
            (clipId: 4, embeddingData: serialize([0, 1, 0, 0])),
            (clipId: 5, embeddingData: serialize([0, 0, 0, 1])),
        ])

        let results = await store.search(query: [1, 0, 0, 0], limit: 2)
        XCTAssertEqual(results.count, 2)
        // Top-2 应该是 clipId=1 和 clipId=2
        XCTAssertEqual(results[0].clipId, 1)
        XCTAssertEqual(results[1].clipId, 2)
    }

    func testSearchEmptyStoreReturnsEmpty() async {
        let store = VectorStore(dimensions: 4, embeddingModel: "test")
        let results = await store.search(query: [1, 0, 0, 0], limit: 10)
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchWrongDimensionReturnsEmpty() async {
        let store = VectorStore(dimensions: 4, embeddingModel: "test")
        await store.append(clipId: 1, embedding: [1, 0, 0, 0])
        // 查询维度不匹配
        let results = await store.search(query: [1, 0, 0], limit: 10)
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchZeroQueryReturnsEmpty() async {
        let store = VectorStore(dimensions: 4, embeddingModel: "test")
        await store.append(clipId: 1, embedding: [1, 0, 0, 0])
        let results = await store.search(query: [0, 0, 0, 0], limit: 10)
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchDescendingOrder() async {
        let store = VectorStore(dimensions: 4, embeddingModel: "test")
        await store.load(entries: [
            (clipId: 1, embeddingData: serialize([0, 0, 0, 1])),
            (clipId: 2, embeddingData: serialize([0.7, 0.7, 0, 0])),
            (clipId: 3, embeddingData: serialize([1, 0, 0, 0])),
        ])

        let results = await store.search(query: [1, 0, 0, 0], limit: 10)
        // 验证降序排列
        for i in 0..<(results.count - 1) {
            XCTAssertGreaterThanOrEqual(results[i].similarity, results[i + 1].similarity)
        }
    }

    func testSearchWithAllowedClipIDsFiltersCandidates() async {
        let store = VectorStore(dimensions: 4, embeddingModel: "test")
        await store.load(entries: [
            (clipId: 1, embeddingData: serialize([1, 0, 0, 0])),
            (clipId: 2, embeddingData: serialize([0.9, 0.1, 0, 0])),
            (clipId: 3, embeddingData: serialize([0, 1, 0, 0])),
        ])

        let results = await store.search(
            query: [1, 0, 0, 0],
            limit: 10,
            allowedClipIDs: Set([3])
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].clipId, 3)
    }

    func testSearchWithAllowedClipIDsNoMatchReturnsEmpty() async {
        let store = VectorStore(dimensions: 4, embeddingModel: "test")
        await store.append(clipId: 1, embedding: [1, 0, 0, 0])

        let results = await store.search(
            query: [1, 0, 0, 0],
            limit: 10,
            allowedClipIDs: Set([999])
        )

        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - 集成：搜索与增量操作

    func testSearchAfterAppendFindsNewVector() async {
        let store = VectorStore(dimensions: 4, embeddingModel: "test")
        await store.load(entries: [
            (clipId: 1, embeddingData: serialize([1, 0, 0, 0])),
        ])

        // 初始搜索
        let results1 = await store.search(query: [0, 1, 0, 0], limit: 10)
        XCTAssertEqual(results1.count, 1)
        XCTAssertEqual(results1[0].similarity, 0.0, accuracy: 0.001)

        // 增量添加精确匹配的向量
        await store.append(clipId: 2, embedding: [0, 1, 0, 0])

        let results2 = await store.search(query: [0, 1, 0, 0], limit: 10)
        XCTAssertEqual(results2.count, 2)
        XCTAssertEqual(results2[0].clipId, 2)
        XCTAssertEqual(results2[0].similarity, 1.0, accuracy: 0.001)
    }

    func testSearchAfterRemoveExcludesVector() async {
        let store = VectorStore(dimensions: 4, embeddingModel: "test")
        await store.load(entries: [
            (clipId: 1, embeddingData: serialize([1, 0, 0, 0])),
            (clipId: 2, embeddingData: serialize([0, 1, 0, 0])),
        ])

        await store.remove(clipId: 1)

        let results = await store.search(query: [1, 0, 0, 0], limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].clipId, 2)
    }

    // MARK: - SearchEngine.vectorSearchFromStore 集成

    func testVectorSearchFromStoreBuildsResults() throws {
        let db = try DatabaseQueue(path: ":memory:")
        let migrator = Migrations.globalMigrator()
        try migrator.migrate(db)

        // 插入测试数据
        try db.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO clips
                    (source_folder, source_clip_id, start_time, end_time, tags, description)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: ["/videos", 1, 0.0, 10.0, "[\"海滩\"]", "beach scene"])
        }

        let clipId = try db.read { try Int64.fetchOne($0, sql: "SELECT clip_id FROM clips LIMIT 1")! }

        let storeResults: [(clipId: Int64, similarity: Float)] = [
            (clipId: clipId, similarity: 0.95)
        ]

        let results = try db.read { dbConn in
            try SearchEngine.vectorSearchFromStore(dbConn, storeResults: storeResults, limit: 10)
        }

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].clipId, clipId)
        XCTAssertEqual(results[0].similarity ?? 0, 0.95, accuracy: 0.001)
        XCTAssertEqual(results[0].clipDescription, "beach scene")
    }

    func testVectorSearchFromStoreEmptyInput() throws {
        let db = try DatabaseQueue(path: ":memory:")
        let migrator = Migrations.globalMigrator()
        try migrator.migrate(db)

        let results = try db.read { dbConn in
            try SearchEngine.vectorSearchFromStore(dbConn, storeResults: [], limit: 10)
        }
        XCTAssertTrue(results.isEmpty)
    }

    func testVectorSearchFromStoreFiltersBeforeApplyingLimit() throws {
        let db = try DatabaseQueue(path: ":memory:")
        try Migrations.globalMigrator().migrate(db)

        try db.write { dbConn in
            try dbConn.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, start_time, end_time, description)
                VALUES ('/A', 1, 0, 5, 'A clip')
                """)
            try dbConn.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, start_time, end_time, description)
                VALUES ('/B', 2, 0, 5, 'B clip')
                """)
        }

        let clipA = try db.read { dbConn in
            try Int64.fetchOne(dbConn, sql: "SELECT clip_id FROM clips WHERE source_folder = '/A'")!
        }
        let clipB = try db.read { dbConn in
            try Int64.fetchOne(dbConn, sql: "SELECT clip_id FROM clips WHERE source_folder = '/B'")!
        }

        // 相似度最高的是 A，但过滤条件只允许 B
        let storeResults: [(clipId: Int64, similarity: Float)] = [
            (clipId: clipA, similarity: 0.99),
            (clipId: clipB, similarity: 0.80),
        ]

        let results = try db.read { dbConn in
            try SearchEngine.vectorSearchFromStore(
                dbConn,
                storeResults: storeResults,
                folderPaths: Set(["/B"]),
                limit: 1
            )
        }

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].sourceFolder, "/B")
        XCTAssertEqual(results[0].clipId, clipB)
    }

}
