import XCTest
@testable import FindItCore

final class RateLimiterTests: XCTestCase {

    // MARK: - Config

    func testDefaultConfig() {
        let config = GeminiRateLimiter.Config.default
        XCTAssertEqual(config.maxRequestsPerWindow, 9)
        XCTAssertEqual(config.windowDuration, 60.0)
        XCTAssertEqual(config.minRequestsPerWindow, 3)
    }

    func testCustomConfig() {
        let config = GeminiRateLimiter.Config(
            maxRequestsPerWindow: 5,
            windowDuration: 30.0,
            minRequestsPerWindow: 1
        )
        XCTAssertEqual(config.maxRequestsPerWindow, 5)
        XCTAssertEqual(config.windowDuration, 30.0)
        XCTAssertEqual(config.minRequestsPerWindow, 1)
    }

    // MARK: - 基本许可

    func testFirstRequestPassesImmediately() async throws {
        let limiter = GeminiRateLimiter(config: .init(maxRequestsPerWindow: 5, windowDuration: 60))
        let start = Date()
        try await limiter.waitForPermission()
        let elapsed = Date().timeIntervalSince(start)
        // 第一个请求应该几乎立即通过
        XCTAssertLessThan(elapsed, 1.0)
    }

    func testMultipleRequestsWithinLimitPassImmediately() async throws {
        let limiter = GeminiRateLimiter(config: .init(maxRequestsPerWindow: 5, windowDuration: 60))
        let start = Date()
        for _ in 0..<5 {
            try await limiter.waitForPermission()
        }
        let elapsed = Date().timeIntervalSince(start)
        // 5 个请求在窗口 (允许 5) 内应该快速通过
        XCTAssertLessThan(elapsed, 2.0)
    }

    func testWindowFullCausesWait() async throws {
        // 窗口 2 秒，最多 2 个请求
        let limiter = GeminiRateLimiter(config: .init(
            maxRequestsPerWindow: 2,
            windowDuration: 2.0,
            minRequestsPerWindow: 1
        ))

        // 前 2 个立即通过
        try await limiter.waitForPermission()
        try await limiter.waitForPermission()

        // 第 3 个应该等待约 2 秒（等第一个请求过期）
        let start = Date()
        try await limiter.waitForPermission()
        let elapsed = Date().timeIntervalSince(start)

        // 应该等待了 2-3 秒（2s 窗口 + 0.5s 缓冲）
        XCTAssertGreaterThan(elapsed, 1.5)
        XCTAssertLessThan(elapsed, 4.0)
    }

    // MARK: - 429 反馈

    func testReportRateLimitReducesMaxRequests() async throws {
        let limiter = GeminiRateLimiter(config: .init(maxRequestsPerWindow: 9))

        let initial = await limiter.effectiveMaxRequests
        XCTAssertEqual(initial, 9)

        await limiter.reportRateLimit()

        let reduced = await limiter.effectiveMaxRequests
        XCTAssertEqual(reduced, 7)  // 9 - 2
    }

    func testReportRateLimitRespectsMinimum() async throws {
        let limiter = GeminiRateLimiter(config: .init(
            maxRequestsPerWindow: 5,
            minRequestsPerWindow: 3
        ))

        // 连续 429 多次
        await limiter.reportRateLimit()  // 5 -> 3
        await limiter.reportRateLimit()  // 3 -> 3 (不会低于最小值)

        let result = await limiter.effectiveMaxRequests
        XCTAssertEqual(result, 3)
    }

    func testReportSuccessRecovery() async throws {
        let limiter = GeminiRateLimiter(config: .init(maxRequestsPerWindow: 9))

        // 先降速
        await limiter.reportRateLimit()  // 9 -> 7
        await limiter.reportRateLimit()  // 7 -> 5

        let reduced = await limiter.effectiveMaxRequests
        XCTAssertEqual(reduced, 5)

        // 成功恢复
        await limiter.reportSuccess()
        let recovered1 = await limiter.effectiveMaxRequests
        XCTAssertEqual(recovered1, 6)  // 5 + 1

        await limiter.reportSuccess()
        let recovered2 = await limiter.effectiveMaxRequests
        XCTAssertEqual(recovered2, 7)  // 6 + 1
    }

    func testReportSuccessDoesNotExceedMax() async throws {
        let limiter = GeminiRateLimiter(config: .init(maxRequestsPerWindow: 5))

        // 已经是最大值，成功不应该超过
        await limiter.reportSuccess()
        let result = await limiter.effectiveMaxRequests
        XCTAssertEqual(result, 5)
    }

    func testReportSuccessResetsConsecutiveCount() async throws {
        let limiter = GeminiRateLimiter(config: .init(maxRequestsPerWindow: 9))

        // 429 后 backoff
        await limiter.reportRateLimit()
        let inBackoff = await limiter.isInBackoff
        XCTAssertTrue(inBackoff)

        // 成功重置连续计数（但不清除 backoff 时间）
        await limiter.reportSuccess()
        // effectiveMaxRequests 恢复 1
        let recovered = await limiter.effectiveMaxRequests
        XCTAssertEqual(recovered, 8)  // 7 + 1
    }

    // MARK: - 退避期

    func testBackoffAfterRateLimit() async throws {
        let limiter = GeminiRateLimiter(config: .init(maxRequestsPerWindow: 9))

        await limiter.reportRateLimit()  // 退避 2^1 = 2 秒
        let inBackoff = await limiter.isInBackoff
        XCTAssertTrue(inBackoff)
    }

    func testExponentialBackoff() async throws {
        let limiter = GeminiRateLimiter(config: .init(maxRequestsPerWindow: 9))

        // 第 1 次 429: 退避 2 秒
        await limiter.reportRateLimit()
        // 第 2 次 429: 退避 4 秒
        await limiter.reportRateLimit()
        // 第 3 次 429: 退避 8 秒
        await limiter.reportRateLimit()

        let inBackoff = await limiter.isInBackoff
        XCTAssertTrue(inBackoff)

        // 应该被降到最小值 3
        let effective = await limiter.effectiveMaxRequests
        XCTAssertEqual(effective, 3)
    }

    // MARK: - 每日计数

    func testDailyRequestCount() async throws {
        let limiter = GeminiRateLimiter(config: .init(maxRequestsPerWindow: 100, windowDuration: 60))

        let before = await limiter.todayRequestCount
        XCTAssertEqual(before, 0)

        try await limiter.waitForPermission()
        try await limiter.waitForPermission()

        let after = await limiter.todayRequestCount
        XCTAssertEqual(after, 2)
    }

    // MARK: - 状态查询

    func testPendingRequestCount() async throws {
        let limiter = GeminiRateLimiter(config: .init(maxRequestsPerWindow: 10, windowDuration: 60))

        try await limiter.waitForPermission()
        try await limiter.waitForPermission()
        try await limiter.waitForPermission()

        let count = await limiter.pendingRequestCount
        XCTAssertEqual(count, 3)
    }

    func testIsInBackoffInitiallyFalse() async throws {
        let limiter = GeminiRateLimiter()
        let inBackoff = await limiter.isInBackoff
        XCTAssertFalse(inBackoff)
    }
}
