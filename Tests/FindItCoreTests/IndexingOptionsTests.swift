import XCTest
@testable import FindItCore

final class IndexingOptionsTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        IndexingOptions.resetToDefault()
    }

    // MARK: - 默认值

    func testDefaultValues() {
        let options = IndexingOptions.default
        XCTAssertFalse(options.skipStt)
        XCTAssertFalse(options.skipVision)
        XCTAssertFalse(options.skipEmbedding)
        XCTAssertEqual(options.performanceMode, .balanced)
    }

    // MARK: - 持久化

    func testSaveAndLoad() {
        var options = IndexingOptions.default
        options.skipStt = true
        options.skipVision = true
        options.performanceMode = .fullSpeed

        options.save()

        let loaded = IndexingOptions.load()
        XCTAssertTrue(loaded.skipStt)
        XCTAssertTrue(loaded.skipVision)
        XCTAssertFalse(loaded.skipEmbedding)
        XCTAssertEqual(loaded.performanceMode, .fullSpeed)
    }

    func testLoadWithoutSaveReturnsDefault() {
        IndexingOptions.resetToDefault()
        let loaded = IndexingOptions.load()
        XCTAssertEqual(loaded, IndexingOptions.default)
    }

    func testResetToDefault() {
        var options = IndexingOptions.default
        options.skipStt = true
        options.performanceMode = .background
        options.save()

        IndexingOptions.resetToDefault()
        let loaded = IndexingOptions.load()
        XCTAssertEqual(loaded, IndexingOptions.default)
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let original = IndexingOptions(
            skipStt: true,
            skipVision: false,
            skipEmbedding: true,
            performanceMode: .background
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IndexingOptions.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Equatable

    func testEquatable() {
        let a = IndexingOptions.default
        let b = IndexingOptions.default
        XCTAssertEqual(a, b)

        var c = IndexingOptions.default
        c.skipStt = true
        XCTAssertNotEqual(a, c)
    }

    // MARK: - 所有模式

    func testAllPerformanceModes() {
        for mode in PerformanceMode.allCases {
            var options = IndexingOptions.default
            options.performanceMode = mode
            options.save()

            let loaded = IndexingOptions.load()
            XCTAssertEqual(loaded.performanceMode, mode)
        }
    }
}
