import XCTest
import GRDB
@testable import FindItCore

final class FilterEngineTests: XCTestCase {

    // MARK: - 辅助

    private func makeGlobalDB() throws -> DatabaseQueue {
        let db = try DatabaseQueue(path: ":memory:")
        let migrator = Migrations.globalMigrator()
        try migrator.migrate(db)
        return db
    }

    /// 创建测试用 SearchResult
    private func makeResult(
        clipId: Int64 = 1,
        startTime: Double = 0.0,
        endTime: Double = 10.0,
        rating: Int = 0,
        colorLabel: String? = nil,
        shotType: String? = nil,
        mood: String? = nil
    ) -> SearchEngine.SearchResult {
        SearchEngine.SearchResult(
            clipId: clipId, sourceFolder: "/test", sourceClipId: clipId,
            videoId: nil, filePath: nil, fileName: nil,
            startTime: startTime, endTime: endTime,
            scene: nil, clipDescription: nil, tags: nil, transcript: nil,
            thumbnailPath: nil, userTags: nil,
            rating: rating, colorLabel: colorLabel,
            shotType: shotType, mood: mood,
            rank: -1.0, similarity: nil, finalScore: nil
        )
    }

    // MARK: - SearchFilter

    func testSearchFilterIsEmpty() {
        let filter = FilterEngine.SearchFilter()
        XCTAssertTrue(filter.isEmpty)
    }

    func testSearchFilterIsNotEmptyWithRating() {
        let filter = FilterEngine.SearchFilter(minRating: 3)
        XCTAssertFalse(filter.isEmpty)
    }

    func testSearchFilterIsNotEmptyWithSort() {
        let filter = FilterEngine.SearchFilter(sortBy: .rating)
        XCTAssertFalse(filter.isEmpty)
    }

    func testSearchFilterActiveCount() {
        let filter = FilterEngine.SearchFilter(
            minRating: 2,
            colorLabels: [.red],
            shotTypes: ["close-up"]
        )
        XCTAssertEqual(filter.activeFilterCount, 3)
    }

    func testSearchFilterActiveCountExcludesSort() {
        let filter = FilterEngine.SearchFilter(sortBy: .rating)
        XCTAssertEqual(filter.activeFilterCount, 0)
    }

    // MARK: - applyFilter 评分

    func testApplyFilterMinRating() {
        let results = [
            makeResult(clipId: 1, rating: 1),
            makeResult(clipId: 2, rating: 3),
            makeResult(clipId: 3, rating: 5),
            makeResult(clipId: 4, rating: 0),
        ]
        let filter = FilterEngine.SearchFilter(minRating: 3)
        let filtered = FilterEngine.applyFilter(results, filter: filter)

        XCTAssertEqual(filtered.count, 2)
        XCTAssertEqual(Set(filtered.map(\.clipId)), [2, 3])
    }

    func testApplyFilterMinRatingZeroIsNoOp() {
        let results = [
            makeResult(clipId: 1, rating: 0),
            makeResult(clipId: 2, rating: 3),
        ]
        // minRating = 0 时 applyFilter 不过滤（guard minRating > 0）
        let filter = FilterEngine.SearchFilter(minRating: 0)
        let filtered = FilterEngine.applyFilter(results, filter: filter)
        XCTAssertEqual(filtered.count, 2)
    }

    // MARK: - applyFilter 颜色标签

    func testApplyFilterColorLabels() {
        let results = [
            makeResult(clipId: 1, colorLabel: "red"),
            makeResult(clipId: 2, colorLabel: "blue"),
            makeResult(clipId: 3, colorLabel: nil),
            makeResult(clipId: 4, colorLabel: "red"),
        ]
        let filter = FilterEngine.SearchFilter(colorLabels: [.red])
        let filtered = FilterEngine.applyFilter(results, filter: filter)

        XCTAssertEqual(filtered.count, 2)
        XCTAssertEqual(Set(filtered.map(\.clipId)), [1, 4])
    }

    func testApplyFilterMultipleColors() {
        let results = [
            makeResult(clipId: 1, colorLabel: "red"),
            makeResult(clipId: 2, colorLabel: "blue"),
            makeResult(clipId: 3, colorLabel: "green"),
        ]
        let filter = FilterEngine.SearchFilter(colorLabels: [.red, .blue])
        let filtered = FilterEngine.applyFilter(results, filter: filter)

        XCTAssertEqual(filtered.count, 2)
        XCTAssertEqual(Set(filtered.map(\.clipId)), [1, 2])
    }

    // MARK: - applyFilter 镜头类型

    func testApplyFilterShotTypes() {
        let results = [
            makeResult(clipId: 1, shotType: "close-up"),
            makeResult(clipId: 2, shotType: "wide shot"),
            makeResult(clipId: 3, shotType: nil),
        ]
        let filter = FilterEngine.SearchFilter(shotTypes: ["close-up"])
        let filtered = FilterEngine.applyFilter(results, filter: filter)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.clipId, 1)
    }

    // MARK: - applyFilter 情绪

    func testApplyFilterMoods() {
        let results = [
            makeResult(clipId: 1, mood: "cheerful"),
            makeResult(clipId: 2, mood: "somber"),
            makeResult(clipId: 3, mood: "cheerful"),
        ]
        let filter = FilterEngine.SearchFilter(moods: ["cheerful"])
        let filtered = FilterEngine.applyFilter(results, filter: filter)

        XCTAssertEqual(filtered.count, 2)
        XCTAssertEqual(Set(filtered.map(\.clipId)), [1, 3])
    }

    // MARK: - applyFilter 组合

    func testApplyFilterCombined() {
        let results = [
            makeResult(clipId: 1, rating: 4, colorLabel: "red", shotType: "close-up"),
            makeResult(clipId: 2, rating: 4, colorLabel: "blue", shotType: "close-up"),
            makeResult(clipId: 3, rating: 2, colorLabel: "red", shotType: "close-up"),
            makeResult(clipId: 4, rating: 4, colorLabel: "red", shotType: "wide shot"),
        ]
        let filter = FilterEngine.SearchFilter(
            minRating: 3,
            colorLabels: [.red],
            shotTypes: ["close-up"]
        )
        let filtered = FilterEngine.applyFilter(results, filter: filter)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.clipId, 1)
    }

    func testApplyFilterEmptyIsNoOp() {
        let results = [makeResult(clipId: 1), makeResult(clipId: 2)]
        let filter = FilterEngine.SearchFilter()
        let filtered = FilterEngine.applyFilter(results, filter: filter)
        XCTAssertEqual(filtered.count, 2)
    }

    // MARK: - applySortToResults

    func testSortByRatingDescending() {
        let results = [
            makeResult(clipId: 1, rating: 2),
            makeResult(clipId: 2, rating: 5),
            makeResult(clipId: 3, rating: 0),
        ]
        let sorted = FilterEngine.applySortToResults(results, sortBy: .rating, sortOrder: .descending)

        XCTAssertEqual(sorted.map(\.clipId), [2, 1, 3])
    }

    func testSortByRatingAscending() {
        let results = [
            makeResult(clipId: 1, rating: 2),
            makeResult(clipId: 2, rating: 5),
            makeResult(clipId: 3, rating: 0),
        ]
        let sorted = FilterEngine.applySortToResults(results, sortBy: .rating, sortOrder: .ascending)

        XCTAssertEqual(sorted.map(\.clipId), [3, 1, 2])
    }

    func testSortByDuration() {
        let results = [
            makeResult(clipId: 1, startTime: 0, endTime: 30),   // 30s
            makeResult(clipId: 2, startTime: 0, endTime: 5),    // 5s
            makeResult(clipId: 3, startTime: 10, endTime: 25),  // 15s
        ]
        let sorted = FilterEngine.applySortToResults(results, sortBy: .duration, sortOrder: .descending)

        XCTAssertEqual(sorted.map(\.clipId), [1, 3, 2])
    }

    func testSortByDate() {
        let results = [
            makeResult(clipId: 1, startTime: 100),
            makeResult(clipId: 2, startTime: 10),
            makeResult(clipId: 3, startTime: 50),
        ]
        let sorted = FilterEngine.applySortToResults(results, sortBy: .date, sortOrder: .ascending)

        XCTAssertEqual(sorted.map(\.clipId), [2, 3, 1])
    }

    func testSortByRelevanceIsNoOp() {
        let results = [
            makeResult(clipId: 1),
            makeResult(clipId: 2),
            makeResult(clipId: 3),
        ]
        let sorted = FilterEngine.applySortToResults(results, sortBy: .relevance, sortOrder: .descending)

        XCTAssertEqual(sorted.map(\.clipId), [1, 2, 3])
    }

    // MARK: - applyFilter 含排序

    func testApplyFilterWithSort() {
        let results = [
            makeResult(clipId: 1, rating: 3),
            makeResult(clipId: 2, rating: 5),
            makeResult(clipId: 3, rating: 1),
            makeResult(clipId: 4, rating: 4),
        ]
        let filter = FilterEngine.SearchFilter(minRating: 3, sortBy: .rating, sortOrder: .descending)
        let filtered = FilterEngine.applyFilter(results, filter: filter)

        XCTAssertEqual(filtered.map(\.clipId), [2, 4, 1])
    }

    // MARK: - SortField / SortOrder

    func testSortFieldDisplayName() {
        XCTAssertEqual(FilterEngine.SortField.relevance.displayName, "相关度")
        XCTAssertEqual(FilterEngine.SortField.date.displayName, "时间")
        XCTAssertEqual(FilterEngine.SortField.duration.displayName, "时长")
        XCTAssertEqual(FilterEngine.SortField.rating.displayName, "评分")
    }

    func testSortOrderDisplayName() {
        XCTAssertEqual(FilterEngine.SortOrder.ascending.displayName, "升序")
        XCTAssertEqual(FilterEngine.SortOrder.descending.displayName, "降序")
    }

    func testSortFieldAllCases() {
        XCTAssertEqual(FilterEngine.SortField.allCases.count, 4)
    }

    // MARK: - availableFacets

    func testAvailableFacetsEmpty() throws {
        let db = try makeGlobalDB()

        let facets = try db.read { dbConn in
            try FilterEngine.availableFacets(dbConn)
        }

        XCTAssertTrue(facets.shotTypes.isEmpty)
        XCTAssertTrue(facets.moods.isEmpty)
        XCTAssertTrue(facets.ratingCounts.isEmpty)
        XCTAssertTrue(facets.colorLabelCounts.isEmpty)
    }

    func testAvailableFacetsWithData() throws {
        let db = try makeGlobalDB()

        try db.write { conn in
            try conn.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, start_time, end_time,
                    shot_type, mood, rating, color_label)
                VALUES ('/test', 1, 0, 5, 'close-up', 'cheerful', 4, 'red')
                """)
            try conn.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, start_time, end_time,
                    shot_type, mood, rating, color_label)
                VALUES ('/test', 2, 5, 10, 'close-up', 'somber', 3, 'blue')
                """)
            try conn.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, start_time, end_time,
                    shot_type, mood, rating, color_label)
                VALUES ('/test', 3, 10, 15, 'wide shot', 'cheerful', 0, NULL)
                """)
        }

        let facets = try db.read { dbConn in
            try FilterEngine.availableFacets(dbConn)
        }

        // 镜头类型: close-up(2), wide shot(1)
        XCTAssertEqual(facets.shotTypes.count, 2)
        XCTAssertEqual(facets.shotTypes.first?.value, "close-up")
        XCTAssertEqual(facets.shotTypes.first?.count, 2)

        // 情绪: cheerful(2), somber(1)
        XCTAssertEqual(facets.moods.count, 2)
        XCTAssertEqual(facets.moods.first?.value, "cheerful")
        XCTAssertEqual(facets.moods.first?.count, 2)

        // 评分: 4(1), 3(1) — rating=0 不计
        XCTAssertEqual(facets.ratingCounts.count, 2)
        XCTAssertEqual(facets.ratingCounts[4], 1)
        XCTAssertEqual(facets.ratingCounts[3], 1)

        // 颜色: red(1), blue(1) — NULL 不计
        XCTAssertEqual(facets.colorLabelCounts.count, 2)
    }

    func testAvailableFacetsWithFolderFilter() throws {
        let db = try makeGlobalDB()

        try db.write { conn in
            try conn.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, start_time, end_time,
                    shot_type, rating)
                VALUES ('/folderA', 1, 0, 5, 'close-up', 5)
                """)
            try conn.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, start_time, end_time,
                    shot_type, rating)
                VALUES ('/folderB', 2, 0, 5, 'wide shot', 3)
                """)
        }

        let facets = try db.read { dbConn in
            try FilterEngine.availableFacets(dbConn, folderPaths: ["/folderA"])
        }

        XCTAssertEqual(facets.shotTypes.count, 1)
        XCTAssertEqual(facets.shotTypes.first?.value, "close-up")
        XCTAssertEqual(facets.ratingCounts.count, 1)
        XCTAssertEqual(facets.ratingCounts[5], 1)
    }

    // MARK: - ColorLabel

    func testColorLabelInSearchFilter() {
        let filter = FilterEngine.SearchFilter(colorLabels: [.red, .blue])
        XCTAssertEqual(filter.colorLabels?.count, 2)
        XCTAssertTrue(filter.colorLabels?.contains(.red) == true)
        XCTAssertTrue(filter.colorLabels?.contains(.blue) == true)
    }

    // MARK: - SearchResult shotType/mood

    func testSearchResultShotTypeAndMood() {
        let result = SearchEngine.SearchResult(
            clipId: 1, sourceFolder: "/test", sourceClipId: 1,
            videoId: nil, filePath: nil, fileName: nil,
            startTime: 0, endTime: 10,
            scene: nil, clipDescription: nil, tags: nil, transcript: nil,
            thumbnailPath: nil, userTags: nil,
            rating: 0, colorLabel: nil,
            shotType: "close-up", mood: "cheerful",
            rank: -1.0, similarity: nil, finalScore: nil
        )
        XCTAssertEqual(result.shotType, "close-up")
        XCTAssertEqual(result.mood, "cheerful")
    }
}
