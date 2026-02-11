import XCTest
import GRDB
@testable import FindItCore

// MARK: - Three-Way Fusion Tests

final class ThreeWayFusionTests: XCTestCase {

    // MARK: - Helper

    private func makeGlobalDB() throws -> DatabaseQueue {
        let db = try DatabaseQueue(path: ":memory:")
        let migrator = Migrations.globalMigrator()
        try migrator.migrate(db)
        return db
    }

    /// 插入测试 clip 到全局库
    private func insertClip(
        _ db: DatabaseQueue,
        sourceClipId: Int64,
        sourceFolder: String = "/test",
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
                    (source_folder, source_clip_id, start_time, end_time,
                     scene, description, tags, transcript, embedding, embedding_model)
                VALUES (?, ?, 0.0, 10.0, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    sourceFolder, sourceClipId,
                    scene, description, tags, transcript, embedding, embeddingModel
                ])
        }
    }

    // MARK: - threeWaySearch: CLIP only

    func testThreeWaySearchCLIPOnly() throws {
        let db = try makeGlobalDB()
        try insertClip(db, sourceClipId: 1, scene: "海滩", tags: "海滩 日落")
        try insertClip(db, sourceClipId: 2, scene: "森林", tags: "森林 散步")
        try insertClip(db, sourceClipId: 3, scene: "城市", tags: "城市 夜景")

        // 假设 CLIP 搜索返回 clip 1 和 clip 3
        let clipResults: [VectorSearchResult] = [
            VectorSearchResult(clipId: 1, similarity: 0.85),
            VectorSearchResult(clipId: 3, similarity: 0.62),
        ]

        let query = ParsedQuery(
            positiveText: "海滩日落",
            negativeTerms: [],
            hasQuotedPhrase: false,
            rawQuery: "海滩日落"
        )

        let results = try db.read { dbConn in
            try SearchEngine.threeWaySearch(
                dbConn,
                query: query,
                clipResults: clipResults,
                textEmbResults: nil,
                weights: .clipOnly
            )
        }

        XCTAssertEqual(results.count, 2)
        // clip 1 应排第一（similarity 更高）
        XCTAssertEqual(results[0].sourceClipId, 1)
        XCTAssertEqual(results[1].sourceClipId, 3)
        // finalScore 应有值
        XCTAssertNotNil(results[0].finalScore)
        XCTAssertGreaterThan(results[0].finalScore ?? 0, results[1].finalScore ?? 1)
    }

    // MARK: - threeWaySearch: FTS only

    func testThreeWaySearchFTSOnly() throws {
        let db = try makeGlobalDB()
        try insertClip(db, sourceClipId: 1, scene: "海滩日落", description: "海边日落", tags: "海滩 日落")
        try insertClip(db, sourceClipId: 2, scene: "森林", tags: "森林")

        let query = QueryParser.parse("海滩")

        let results = try db.read { dbConn in
            try SearchEngine.threeWaySearch(
                dbConn,
                query: query,
                clipResults: nil,
                textEmbResults: nil,
                weights: .ftsOnly
            )
        }

        XCTAssertGreaterThan(results.count, 0)
        // 应该包含含"海滩"的 clip
        XCTAssertTrue(results.contains { $0.sourceClipId == 1 })
    }

    // MARK: - threeWaySearch: TextEmb only

    func testThreeWaySearchTextEmbOnly() throws {
        let db = try makeGlobalDB()
        try insertClip(db, sourceClipId: 1, scene: "海滩")
        try insertClip(db, sourceClipId: 2, scene: "森林")

        let textEmbResults: [VectorSearchResult] = [
            VectorSearchResult(clipId: 2, similarity: 0.90),
            VectorSearchResult(clipId: 1, similarity: 0.50),
        ]

        let query = ParsedQuery(
            positiveText: "森林漫步",
            negativeTerms: [],
            hasQuotedPhrase: false,
            rawQuery: "森林漫步"
        )

        let results = try db.read { dbConn in
            try SearchEngine.threeWaySearch(
                dbConn,
                query: query,
                clipResults: nil,
                textEmbResults: textEmbResults,
                weights: .textEmbOnly
            )
        }

        XCTAssertEqual(results.count, 2)
        // clip 2 应排第一
        XCTAssertEqual(results[0].sourceClipId, 2)
    }

    // MARK: - threeWaySearch: Full three-way fusion

    func testThreeWaySearchFullFusion() throws {
        let db = try makeGlobalDB()
        // clip 1: 海滩相关（FTS 高分 + CLIP 高分）
        try insertClip(db, sourceClipId: 1, scene: "海滩日落", description: "海边日落美景", tags: "海滩 日落 沙滩")
        // clip 2: 语义相关但关键词不完全匹配
        try insertClip(db, sourceClipId: 2, scene: "海边", description: "海边散步", tags: "海滩 散步")
        // clip 3: 不相关
        try insertClip(db, sourceClipId: 3, scene: "办公室", description: "室内办公", tags: "办公室 电脑")

        let clipResults: [VectorSearchResult] = [
            VectorSearchResult(clipId: 1, similarity: 0.80),
            VectorSearchResult(clipId: 2, similarity: 0.65),
            VectorSearchResult(clipId: 3, similarity: 0.20),
        ]

        let textEmbResults: [VectorSearchResult] = [
            VectorSearchResult(clipId: 1, similarity: 0.75),
            VectorSearchResult(clipId: 2, similarity: 0.60),
        ]

        let query = QueryParser.parse("海滩 日落")

        let results = try db.read { dbConn in
            try SearchEngine.threeWaySearch(
                dbConn,
                query: query,
                clipResults: clipResults,
                textEmbResults: textEmbResults,
                weights: .default
            )
        }

        // 应该有结果
        XCTAssertGreaterThan(results.count, 0)
        // clip 1 应该排名最高（三路都有高分）
        XCTAssertEqual(results[0].sourceClipId, 1)
        // 所有 finalScore 在合理范围
        for result in results {
            if let score = result.finalScore {
                XCTAssertGreaterThanOrEqual(score, 0.0)
                XCTAssertLessThanOrEqual(score, 1.0)
            }
        }
    }

    // MARK: - threeWaySearch: Empty query

    func testThreeWaySearchEmptyQuery() throws {
        let db = try makeGlobalDB()
        try insertClip(db, sourceClipId: 1, scene: "海滩")

        let query = QueryParser.parse("")

        let results = try db.read { dbConn in
            try SearchEngine.threeWaySearch(
                dbConn,
                query: query,
                clipResults: nil,
                textEmbResults: nil,
                weights: .default
            )
        }

        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - threeWaySearch: Negative query via FTS

    func testThreeWaySearchWithNegativeQuery() throws {
        let db = try makeGlobalDB()
        try insertClip(db, sourceClipId: 1, scene: "海滩日落", tags: "海滩 日落")
        try insertClip(db, sourceClipId: 2, scene: "海滩雨天", tags: "海滩 雨天")

        // "-雨天" → positive: "海滩", negative: ["雨天"]
        // ftsQuery: "海滩 NOT 雨天"
        let query = QueryParser.parse("海滩 -雨天")

        let results = try db.read { dbConn in
            try SearchEngine.threeWaySearch(
                dbConn,
                query: query,
                clipResults: nil,
                textEmbResults: nil,
                weights: .ftsOnly
            )
        }

        // 只有 clip 1 应在结果中（clip 2 含"雨天"被排除）
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].sourceClipId, 1)
    }

    // MARK: - imageSearch

    func testImageSearch() throws {
        let db = try makeGlobalDB()
        try insertClip(db, sourceClipId: 1, scene: "海滩")
        try insertClip(db, sourceClipId: 2, scene: "森林")

        let clipResults: [VectorSearchResult] = [
            VectorSearchResult(clipId: 1, similarity: 0.90),
            VectorSearchResult(clipId: 2, similarity: 0.45),
        ]

        let results = try db.read { dbConn in
            try SearchEngine.imageSearch(dbConn, clipResults: clipResults)
        }

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].sourceClipId, 1)
        XCTAssertGreaterThan(results[0].similarity ?? 0, results[1].similarity ?? 1)
    }

    func testImageSearchEmpty() throws {
        let db = try makeGlobalDB()

        let results = try db.read { dbConn in
            try SearchEngine.imageSearch(dbConn, clipResults: [])
        }

        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - fetchMetadata

    func testFetchMetadata() throws {
        let db = try makeGlobalDB()
        try insertClip(db, sourceClipId: 1, scene: "海滩", description: "海边日落")
        try insertClip(db, sourceClipId: 2, scene: "森林", description: "森林漫步")

        let metadata = try db.read { dbConn in
            try SearchEngine.fetchMetadata(dbConn, clipIds: [1, 2])
        }

        XCTAssertEqual(metadata.count, 2)
        XCTAssertEqual(metadata[1]?.scene, "海滩")
        XCTAssertEqual(metadata[2]?.scene, "森林")
    }

    func testFetchMetadataEmptyIds() throws {
        let db = try makeGlobalDB()

        let metadata = try db.read { dbConn in
            try SearchEngine.fetchMetadata(dbConn, clipIds: [])
        }

        XCTAssertTrue(metadata.isEmpty)
    }

    // MARK: - normalizeScores

    func testNormalizeScoresRegular() {
        let scores: [Int64: Double] = [1: 0.2, 2: 0.5, 3: 0.8]
        let normalized = SearchEngine.normalizeScores(scores, isNegatedRank: false)

        // min=0.2, max=0.8, range=0.6
        XCTAssertEqual(normalized[1]!, 0.0, accuracy: 0.01)  // (0.2-0.2)/0.6 = 0
        XCTAssertEqual(normalized[2]!, 0.5, accuracy: 0.01)  // (0.5-0.2)/0.6 = 0.5
        XCTAssertEqual(normalized[3]!, 1.0, accuracy: 0.01)  // (0.8-0.2)/0.6 = 1.0
    }

    func testNormalizeScoresNegatedRank() {
        // FTS5 rank: 更负 = 更相关
        let scores: [Int64: Double] = [1: -10.0, 2: -5.0, 3: -1.0]
        let normalized = SearchEngine.normalizeScores(scores, isNegatedRank: true)

        // 取反: 10, 5, 1. min=1, max=10, range=9
        XCTAssertEqual(normalized[1]!, 1.0, accuracy: 0.01)   // (-(-10)-1)/9 = 9/9 = 1.0
        XCTAssertEqual(normalized[2]!, 0.444, accuracy: 0.01)  // (-(-5)-1)/9 = 4/9
        XCTAssertEqual(normalized[3]!, 0.0, accuracy: 0.01)    // (-(-1)-1)/9 = 0/9 = 0.0
    }

    func testNormalizeScoresEmpty() {
        let normalized = SearchEngine.normalizeScores([:], isNegatedRank: false)
        XCTAssertTrue(normalized.isEmpty)
    }

    func testNormalizeScoresSingleValue() {
        let scores: [Int64: Double] = [1: 0.5]
        let normalized = SearchEngine.normalizeScores(scores, isNegatedRank: false)
        // range=0 → 满分 1.0（单一命中不应被清零）
        XCTAssertEqual(normalized[1]!, 1.0, accuracy: 0.01)
    }
}

// MARK: - Three-Way Adaptive Weights Tests

final class ThreeWayWeightsTests: XCTestCase {

    // MARK: - Image query

    func testImageQueryWeights() {
        let w = SearchEngine.resolveThreeWayWeights(
            query: "", hasCLIP: true, hasTextEmb: true, isImageQuery: true
        )
        XCTAssertEqual(w, .clipOnly)
    }

    // MARK: - Explicit modes

    func testFTSModeWeights() {
        let w = SearchEngine.resolveThreeWayWeights(
            query: "海滩", mode: .fts, hasCLIP: true, hasTextEmb: true
        )
        XCTAssertEqual(w, .ftsOnly)
    }

    func testVectorModePrefersClip() {
        let w = SearchEngine.resolveThreeWayWeights(
            query: "海滩", mode: .vector, hasCLIP: true, hasTextEmb: true
        )
        XCTAssertEqual(w, .clipOnly)
    }

    func testVectorModeFallsBackToTextEmb() {
        let w = SearchEngine.resolveThreeWayWeights(
            query: "海滩", mode: .vector, hasCLIP: false, hasTextEmb: true
        )
        XCTAssertEqual(w, .textEmbOnly)
    }

    func testVectorModeFallsBackToFTS() {
        let w = SearchEngine.resolveThreeWayWeights(
            query: "海滩", mode: .vector, hasCLIP: false, hasTextEmb: false
        )
        XCTAssertEqual(w, .ftsOnly)
    }

    // MARK: - No layers

    func testNoVectorLayers() {
        let w = SearchEngine.resolveThreeWayWeights(
            query: "海滩", hasCLIP: false, hasTextEmb: false
        )
        XCTAssertEqual(w, .ftsOnly)
    }

    // MARK: - Three-way auto

    func testThreeWayDefaultWeights() {
        let w = SearchEngine.resolveThreeWayWeights(
            query: "海滩", hasCLIP: true, hasTextEmb: true
        )
        XCTAssertEqual(w, .default)
    }

    func testThreeWayQuotedWeights() {
        let w = SearchEngine.resolveThreeWayWeights(
            query: "\"海滩日落\"", hasCLIP: true, hasTextEmb: true
        )
        XCTAssertEqual(w, .exactMatch)
    }

    func testThreeWayLongQueryWeights() {
        let w = SearchEngine.resolveThreeWayWeights(
            query: "一个女生在海边看日落的场景", hasCLIP: true, hasTextEmb: true
        )
        XCTAssertEqual(w, .semantic)
    }

    func testCJKKeywordQueryNotLong() {
        // 3 个 CJK token（"日落", "金色", "海滩"）→ 关键词查询，应为 default 权重
        let w = SearchEngine.resolveThreeWayWeights(
            query: "日落 金色 海滩", hasCLIP: true, hasTextEmb: true
        )
        XCTAssertEqual(w, .default, "3-token CJK 查询不应被判为 long")
    }

    func testEnglishKeywordQueryNotLong() {
        // 4 个英文词 → 关键词查询（阈值 5+），应为 default 权重
        let w = SearchEngine.resolveThreeWayWeights(
            query: "beach sunset golden hour", hasCLIP: true, hasTextEmb: true
        )
        XCTAssertEqual(w, .default, "4-word 英文查询不应被判为 long")
    }

    func testEnglishLongQueryIsSemantic() {
        // 8 个英文词 → 描述性长查询，应为 semantic 权重
        let w = SearchEngine.resolveThreeWayWeights(
            query: "a girl watching a sunset on the beach", hasCLIP: true, hasTextEmb: true
        )
        XCTAssertEqual(w, .semantic, "8-word 英文查询应被判为 long")
    }

    // MARK: - Two-way fallbacks

    func testTwoWayNoClipDefault() {
        let w = SearchEngine.resolveThreeWayWeights(
            query: "海滩", hasCLIP: false, hasTextEmb: true
        )
        XCTAssertEqual(w, .twoWayNoClip)
        XCTAssertEqual(w.clipWeight, 0.0, accuracy: 0.01)
    }

    func testTwoWayNoClipQuoted() {
        let w = SearchEngine.resolveThreeWayWeights(
            query: "\"海滩\"", hasCLIP: false, hasTextEmb: true
        )
        XCTAssertEqual(w.clipWeight, 0.0, accuracy: 0.01)
        XCTAssertEqual(w.ftsWeight, 0.8, accuracy: 0.01)
        XCTAssertEqual(w.textEmbWeight, 0.2, accuracy: 0.01)
    }

    func testTwoWayNoTextEmbDefault() {
        let w = SearchEngine.resolveThreeWayWeights(
            query: "海滩", hasCLIP: true, hasTextEmb: false
        )
        XCTAssertEqual(w, .twoWayNoTextEmb)
        XCTAssertEqual(w.textEmbWeight, 0.0, accuracy: 0.01)
    }

    func testTwoWayNoTextEmbLongQuery() {
        let w = SearchEngine.resolveThreeWayWeights(
            query: "一个女生在海边看日落的场景", hasCLIP: true, hasTextEmb: false
        )
        XCTAssertEqual(w.clipWeight, 0.8, accuracy: 0.01)
        XCTAssertEqual(w.ftsWeight, 0.2, accuracy: 0.01)
        XCTAssertEqual(w.textEmbWeight, 0.0, accuracy: 0.01)
    }

    // MARK: - SearchWeights presets

    func testSearchWeightsEquatable() {
        XCTAssertEqual(SearchEngine.SearchWeights.clipOnly,
                       SearchEngine.SearchWeights(clipWeight: 1.0, ftsWeight: 0.0, textEmbWeight: 0.0))
        XCTAssertEqual(SearchEngine.SearchWeights.ftsOnly,
                       SearchEngine.SearchWeights(clipWeight: 0.0, ftsWeight: 1.0, textEmbWeight: 0.0))
        XCTAssertEqual(SearchEngine.SearchWeights.textEmbOnly,
                       SearchEngine.SearchWeights(clipWeight: 0.0, ftsWeight: 0.0, textEmbWeight: 1.0))
    }

    func testSearchWeightsTwoWayCompat() {
        // 二路构造器: clipWeight=0, textEmbWeight=vectorWeight
        let w = SearchEngine.SearchWeights(ftsWeight: 0.6, vectorWeight: 0.4)
        XCTAssertEqual(w.clipWeight, 0.0, accuracy: 0.01)
        XCTAssertEqual(w.ftsWeight, 0.6, accuracy: 0.01)
        XCTAssertEqual(w.textEmbWeight, 0.4, accuracy: 0.01)
        XCTAssertEqual(w.vectorWeight, 0.4, accuracy: 0.01) // alias
    }
}
