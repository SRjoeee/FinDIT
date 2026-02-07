import XCTest
@testable import FindItCore

final class IndexingSchedulerTests: XCTestCase {

    // MARK: - 初始化

    func testDefaultInit() async {
        let scheduler = IndexingScheduler(mode: .balanced)
        let info = await scheduler.concurrencyInfo()
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let expected = max(1, cores / 2)
        XCTAssertEqual(info.max, expected)
        XCTAssertEqual(info.available, expected)
        XCTAssertEqual(info.waiting, 0)
    }

    func testCustomConcurrencyInit() async {
        let scheduler = IndexingScheduler(concurrency: 3)
        let info = await scheduler.concurrencyInfo()
        XCTAssertEqual(info.max, 3)
        XCTAssertEqual(info.available, 3)
    }

    func testMinimumConcurrency() async {
        let scheduler = IndexingScheduler(concurrency: 0)
        let info = await scheduler.concurrencyInfo()
        XCTAssertEqual(info.max, 1, "最小并发数应为 1")
    }

    // MARK: - 模式切换

    func testUpdateMode() async {
        let scheduler = IndexingScheduler(mode: .balanced)
        let infoBefore = await scheduler.concurrencyInfo()

        await scheduler.updateMode(.background)
        let infoAfter = await scheduler.concurrencyInfo()

        // 后台模式并发数应 <= 平衡模式
        XCTAssertLessThanOrEqual(infoAfter.max, infoBefore.max,
            "后台模式并发数应不高于平衡模式")
        XCTAssertGreaterThanOrEqual(infoAfter.max, 1,
            "并发数最小为 1")
    }

    // MARK: - 空视频列表

    func testProcessEmptyVideoList() async {
        let scheduler = IndexingScheduler(concurrency: 2)
        var progressCalled = false
        var completeCalled = false

        await scheduler.processVideos(
            [],
            folderPath: "/tmp/test",
            folderDB: try! DatabaseManager.openFolderDatabase(at: NSTemporaryDirectory()),
            onProgress: { _ in progressCalled = true },
            onComplete: { _ in completeCalled = true }
        )

        XCTAssertFalse(progressCalled, "空列表不应触发回调")
        XCTAssertFalse(completeCalled, "空列表不应触发回调")
    }

    // MARK: - PerformanceMode

    func testPerformanceModeProperties() {
        XCTAssertEqual(PerformanceMode.fullSpeed.rawValue, "full_speed")
        XCTAssertEqual(PerformanceMode.balanced.rawValue, "balanced")
        XCTAssertEqual(PerformanceMode.background.rawValue, "background")

        XCTAssertEqual(PerformanceMode.fullSpeed.displayName, "全速")
        XCTAssertEqual(PerformanceMode.balanced.displayName, "平衡")
        XCTAssertEqual(PerformanceMode.background.displayName, "后台")

        XCTAssertEqual(PerformanceMode.fullSpeed.taskPriority, .high)
        XCTAssertEqual(PerformanceMode.balanced.taskPriority, .medium)
        XCTAssertEqual(PerformanceMode.background.taskPriority, .low)
    }

    func testPerformanceModeCodable() throws {
        let encoded = try JSONEncoder().encode(PerformanceMode.balanced)
        let decoded = try JSONDecoder().decode(PerformanceMode.self, from: encoded)
        XCTAssertEqual(decoded, .balanced)
    }

    func testPerformanceModeAllCases() {
        XCTAssertEqual(PerformanceMode.allCases.count, 3)
    }

    // MARK: - VideoOutcome

    func testVideoOutcomeSuccess() {
        let outcome = IndexingScheduler.VideoOutcome.success(
            videoPath: "/test.mp4",
            clipsCreated: 5,
            clipsAnalyzed: 3,
            clipsEmbedded: 5
        )
        XCTAssertTrue(outcome.success)
        XCTAssertNil(outcome.errorMessage)
        XCTAssertEqual(outcome.clipsCreated, 5)
    }

    func testVideoOutcomeFailure() {
        let outcome = IndexingScheduler.VideoOutcome.failure(
            videoPath: "/test.mp4",
            error: "测试错误"
        )
        XCTAssertFalse(outcome.success)
        XCTAssertEqual(outcome.errorMessage, "测试错误")
        XCTAssertEqual(outcome.clipsCreated, 0)
    }

    func testVideoOutcomeSkipped() {
        let outcome = IndexingScheduler.VideoOutcome.skipped(videoPath: "/test.mp4")
        XCTAssertFalse(outcome.success)
        XCTAssertEqual(outcome.errorMessage, "cancelled")
    }
}
