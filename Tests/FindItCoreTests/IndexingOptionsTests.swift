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
        XCTAssertEqual(options.cloudMode, .local)
        XCTAssertFalse(options.skipStt)
        XCTAssertFalse(options.useLocalVLM)
        XCTAssertEqual(options.performanceMode, .balanced)
        XCTAssertEqual(options.sttEngine, .auto)
        XCTAssertTrue(options.hideSrtFiles)
        XCTAssertEqual(options.orphanedRetentionDays, 30)
        // 向后兼容计算属性
        XCTAssertTrue(options.skipVision)    // local → skipVision=true
        XCTAssertTrue(options.skipEmbedding) // local + !useLocalVLM → skipEmbedding=true
    }

    // MARK: - CloudMode 映射

    func testCloudModeComputedProperties() {
        // cloud 模式
        var cloud = IndexingOptions(cloudMode: .cloud)
        XCTAssertFalse(cloud.skipVision)
        XCTAssertFalse(cloud.skipEmbedding)

        // local 模式（无 VLM）
        let localNoVLM = IndexingOptions(cloudMode: .local, useLocalVLM: false)
        XCTAssertTrue(localNoVLM.skipVision)
        XCTAssertTrue(localNoVLM.skipEmbedding)

        // local 模式（有 VLM）
        let localWithVLM = IndexingOptions(cloudMode: .local, useLocalVLM: true)
        XCTAssertTrue(localWithVLM.skipVision)
        XCTAssertFalse(localWithVLM.skipEmbedding) // VLM 需要 embedding

        // skipVision setter → cloudMode
        cloud.skipVision = true
        XCTAssertEqual(cloud.cloudMode, .local)
        cloud.skipVision = false
        XCTAssertEqual(cloud.cloudMode, .cloud)
    }

    // MARK: - 持久化

    func testSaveAndLoad() {
        var options = IndexingOptions.default
        options.skipStt = true
        options.cloudMode = .cloud
        options.performanceMode = .fullSpeed

        options.save()

        let loaded = IndexingOptions.load()
        XCTAssertTrue(loaded.skipStt)
        XCTAssertEqual(loaded.cloudMode, .cloud)
        XCTAssertFalse(loaded.skipVision)
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
            cloudMode: .cloud,
            skipStt: true,
            useLocalVLM: false,
            performanceMode: .background
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IndexingOptions.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCodableRoundTripLocalVLM() throws {
        let original = IndexingOptions(
            cloudMode: .local,
            useLocalVLM: true,
            performanceMode: .fullSpeed,
            sttEngine: .whisperKitOnly,
            sttLanguageHint: "zh"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IndexingOptions.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.useLocalVLM)
        XCTAssertEqual(decoded.sttEngine, .whisperKitOnly)
        XCTAssertEqual(decoded.sttLanguageHint, "zh")
    }

    // MARK: - 向后兼容（旧版 JSON 迁移）

    func testDecodeOldFormatSkipVisionFalse() throws {
        // 旧版 JSON: skipVision=false → cloudMode=.cloud
        let json = """
        {
            "skipStt": false,
            "skipVision": false,
            "skipEmbedding": false,
            "performanceMode": "balanced",
            "sttEngine": "auto",
            "hideSrtFiles": true,
            "orphanedRetentionDays": 30
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(IndexingOptions.self, from: json)
        XCTAssertEqual(decoded.cloudMode, .cloud)
        XCTAssertFalse(decoded.skipVision)
    }

    func testDecodeOldFormatSkipVisionTrue() throws {
        // 旧版 JSON: skipVision=true → cloudMode=.local
        let json = """
        {
            "skipStt": true,
            "skipVision": true,
            "skipEmbedding": true,
            "performanceMode": "background",
            "sttEngine": "whisperkit",
            "hideSrtFiles": false,
            "orphanedRetentionDays": 7
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(IndexingOptions.self, from: json)
        XCTAssertEqual(decoded.cloudMode, .local)
        XCTAssertTrue(decoded.skipStt)
        XCTAssertEqual(decoded.performanceMode, .background)
        XCTAssertEqual(decoded.sttEngine, .whisperKitOnly)
        XCTAssertFalse(decoded.hideSrtFiles)
        XCTAssertEqual(decoded.orphanedRetentionDays, 7)
    }

    func testDecodeNewFormatPreferred() throws {
        // 新版 JSON: 同时有 cloudMode 和 skipVision → cloudMode 优先
        let json = """
        {
            "cloudMode": "cloud",
            "skipStt": false,
            "skipVision": true,
            "useLocalVLM": false,
            "performanceMode": "balanced",
            "sttEngine": "auto",
            "hideSrtFiles": true,
            "orphanedRetentionDays": 30
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(IndexingOptions.self, from: json)
        // cloudMode 优先于 skipVision
        XCTAssertEqual(decoded.cloudMode, .cloud)
    }

    // MARK: - Equatable

    func testEquatable() {
        let a = IndexingOptions.default
        let b = IndexingOptions.default
        XCTAssertEqual(a, b)

        var c = IndexingOptions.default
        c.skipStt = true
        XCTAssertNotEqual(a, c)

        var d = IndexingOptions.default
        d.cloudMode = .cloud
        XCTAssertNotEqual(a, d)

        var e = IndexingOptions.default
        e.useLocalVLM = true
        XCTAssertNotEqual(a, e)
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

    func testAllCloudModes() {
        for mode in CloudMode.allCases {
            var options = IndexingOptions.default
            options.cloudMode = mode
            options.save()

            let loaded = IndexingOptions.load()
            XCTAssertEqual(loaded.cloudMode, mode)
        }
    }
}
