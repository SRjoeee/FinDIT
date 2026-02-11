import XCTest
@testable import FindItCore

final class NetworkResilienceTests: XCTestCase {

    // MARK: - 初始状态

    func testInitialStatusIsUnknown() async {
        let net = NetworkResilience()
        let status = await net.status
        XCTAssertEqual(status, .unknown)
    }

    func testIsConnectedTrueWhenUnknown() async {
        let net = NetworkResilience()
        let connected = await net.isConnected
        XCTAssertTrue(connected, "unknown 状态应视为已连接")
    }

    // MARK: - start / stop

    func testStartSetsMonitor() async throws {
        let net = NetworkResilience()
        await net.start()
        // 等待 NWPathMonitor 触发首次更新
        try await Task.sleep(for: .milliseconds(200))
        let status = await net.status
        // 在 CI/本机上通常是 connected
        XCTAssertNotEqual(status, .unknown, "start 后应有实际状态")
        await net.stop()
    }

    func testDoubleStartIsIdempotent() async {
        let net = NetworkResilience()
        await net.start()
        await net.start() // 第二次不应崩溃
        await net.stop()
    }

    func testStopCancelsWaiters() async throws {
        let net = NetworkResilience()
        // 手动设为 disconnected 再注册 waiter
        await net.forceStatus(.disconnected)

        let expectation = XCTestExpectation(description: "waiter cancelled")
        let task = Task {
            do {
                try await net.waitForConnection(timeout: .seconds(10))
                XCTFail("应抛出 CancellationError")
            } catch is CancellationError {
                expectation.fulfill()
            } catch {
                XCTFail("意外错误: \(error)")
            }
        }

        // 等 waiter 注册
        try await Task.sleep(for: .milliseconds(50))
        await net.stop()
        await fulfillment(of: [expectation], timeout: 2)
        task.cancel()
    }

    // MARK: - waitForConnection

    func testWaitReturnsImmediatelyWhenConnected() async throws {
        let net = NetworkResilience()
        await net.forceStatus(.connected)
        // 不应挂起
        try await net.waitForConnection(timeout: .seconds(1))
    }

    func testWaitReturnsImmediatelyWhenUnknown() async throws {
        let net = NetworkResilience()
        // unknown 视为已连接
        try await net.waitForConnection(timeout: .seconds(1))
    }

    func testWaitTimesOut() async throws {
        let net = NetworkResilience()
        await net.forceStatus(.disconnected)

        do {
            try await net.waitForConnection(timeout: .milliseconds(100))
            XCTFail("应抛出 timeout")
        } catch let error as NetworkResilienceError {
            XCTAssertEqual(error, .timeout)
        }
    }

    func testWaitResumesOnReconnect() async throws {
        let net = NetworkResilience()
        await net.forceStatus(.disconnected)

        let expectation = XCTestExpectation(description: "resumed")
        let task = Task {
            try await net.waitForConnection(timeout: .seconds(5))
            expectation.fulfill()
        }

        // 等 waiter 注册
        try await Task.sleep(for: .milliseconds(50))
        // 模拟网络恢复
        await net.forceStatus(.connected)

        await fulfillment(of: [expectation], timeout: 2)
        task.cancel()
    }

    func testMultipleWaitersAllResumed() async throws {
        let net = NetworkResilience()
        await net.forceStatus(.disconnected)

        let count = 5
        let expectations = (0..<count).map {
            XCTestExpectation(description: "waiter \($0)")
        }

        var tasks: [Task<Void, Never>] = []
        for i in 0..<count {
            let exp = expectations[i]
            let t = Task {
                do {
                    try await net.waitForConnection(timeout: .seconds(5))
                    exp.fulfill()
                } catch {
                    XCTFail("waiter \(i) 出错: \(error)")
                }
            }
            tasks.append(t)
        }

        // 等所有 waiter 注册
        try await Task.sleep(for: .milliseconds(100))
        // 恢复网络
        await net.forceStatus(.connected)

        await fulfillment(of: expectations, timeout: 2)
        tasks.forEach { $0.cancel() }
    }
}

// MARK: - NetworkResilienceError: Equatable

extension NetworkResilienceError: Equatable {}
