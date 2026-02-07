import XCTest
@testable import FindItCore

final class AsyncSemaphoreTests: XCTestCase {

    // MARK: - 基本操作

    func testAcquireAndRelease() async {
        let sem = AsyncSemaphore(value: 2)

        // 初始 2 个许可
        let available = await sem.available
        XCTAssertEqual(available, 2)

        // 获取一个
        await sem.acquire()
        let after1 = await sem.available
        XCTAssertEqual(after1, 1)

        // 获取第二个
        await sem.acquire()
        let after2 = await sem.available
        XCTAssertEqual(after2, 0)

        // 释放一个
        await sem.release()
        let after3 = await sem.available
        XCTAssertEqual(after3, 1)

        // 释放第二个
        await sem.release()
        let after4 = await sem.available
        XCTAssertEqual(after4, 2)
    }

    func testReleaseDoesNotExceedMax() async {
        let sem = AsyncSemaphore(value: 1)

        // 释放时不应超过最大值
        await sem.release()
        let available = await sem.available
        XCTAssertEqual(available, 1, "release 不应使 permits 超过 maxPermits")

        await sem.release()
        let available2 = await sem.available
        XCTAssertEqual(available2, 1)
    }

    // MARK: - 阻塞与唤醒

    func testAcquireBlocksWhenNoPermits() async {
        let sem = AsyncSemaphore(value: 1)

        // 用完唯一的许可
        await sem.acquire()

        let acquired = UnsafeAtomicBool(false)

        // 启动一个 task 尝试获取，应该被阻塞
        let task = Task {
            await sem.acquire()
            acquired.store(true)
        }

        // 等一下，确认 task 被阻塞
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(acquired.load(), "第二个 acquire 应该被阻塞")

        // 释放，应唤醒等待者
        await sem.release()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(acquired.load(), "释放后等待者应被唤醒")

        // 清理
        await sem.release()
        task.cancel()
    }

    func testFIFOWakeupOrder() async {
        let sem = AsyncSemaphore(value: 1)
        await sem.acquire() // 用完许可

        var order: [Int] = []
        let lock = NSLock()

        // 启动 3 个等待者
        let t1 = Task {
            await sem.acquire()
            lock.lock()
            order.append(1)
            lock.unlock()
            await sem.release()
        }

        try? await Task.sleep(for: .milliseconds(20))

        let t2 = Task {
            await sem.acquire()
            lock.lock()
            order.append(2)
            lock.unlock()
            await sem.release()
        }

        try? await Task.sleep(for: .milliseconds(20))

        let t3 = Task {
            await sem.acquire()
            lock.lock()
            order.append(3)
            lock.unlock()
            await sem.release()
        }

        try? await Task.sleep(for: .milliseconds(50))

        // 确认有 3 个等待者
        let waiting = await sem.waitingCount
        XCTAssertEqual(waiting, 3)

        // 释放，应 FIFO 唤醒
        await sem.release()
        try? await Task.sleep(for: .milliseconds(50))
        await sem.release()
        try? await Task.sleep(for: .milliseconds(50))
        await sem.release()
        try? await Task.sleep(for: .milliseconds(50))

        _ = await [t1.value, t2.value, t3.value]

        lock.lock()
        XCTAssertEqual(order, [1, 2, 3], "应按 FIFO 顺序唤醒")
        lock.unlock()
    }

    // MARK: - 动态调整

    func testSetMaxPermitsIncrease() async {
        let sem = AsyncSemaphore(value: 1)
        await sem.acquire() // 用完

        let acquired = UnsafeAtomicBool(false)
        let task = Task {
            await sem.acquire()
            acquired.store(true)
        }

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(acquired.load())

        // 增加到 2，应唤醒等待者
        await sem.setMaxPermits(2)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(acquired.load(), "增加许可数应唤醒等待者")

        await sem.release()
        await sem.release()
        task.cancel()
    }

    func testSetMaxPermitsDecrease() async {
        let sem = AsyncSemaphore(value: 3)

        // 缩减到 1，当前 permits 应自然收紧
        await sem.setMaxPermits(1)
        let max = await sem.currentMax
        XCTAssertEqual(max, 1)

        // 已有的 permits 不会立即回收，但新的上限是 1
        // 获取后释放，permits 不超过 1
        await sem.acquire()
        await sem.acquire()
        await sem.acquire()
        // 此时 permits = 0
        await sem.release()
        let available = await sem.available
        XCTAssertEqual(available, 1, "释放后 permits 不应超过新的 maxPermits")
    }

    // MARK: - releaseAll

    func testReleaseAll() async {
        let sem = AsyncSemaphore(value: 1)
        await sem.acquire()

        var count = 0
        let lock = NSLock()

        let t1 = Task {
            await sem.acquire()
            lock.lock()
            count += 1
            lock.unlock()
        }
        let t2 = Task {
            await sem.acquire()
            lock.lock()
            count += 1
            lock.unlock()
        }

        try? await Task.sleep(for: .milliseconds(50))
        let waiting = await sem.waitingCount
        XCTAssertEqual(waiting, 2)

        // 唤醒所有
        await sem.releaseAll()
        try? await Task.sleep(for: .milliseconds(100))

        lock.lock()
        XCTAssertEqual(count, 2, "releaseAll 应唤醒所有等待者")
        lock.unlock()

        t1.cancel()
        t2.cancel()
    }

    // MARK: - 并发正确性

    func testConcurrentAcquireRelease() async {
        let sem = AsyncSemaphore(value: 3)
        let counter = AtomicCounter()

        // 启动 10 个并发任务，每个获取-工作-释放
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await sem.acquire()
                    counter.increment()
                    // 验证并发数不超过 3
                    let current = counter.value
                    XCTAssertLessThanOrEqual(current, 3,
                        "并发数不应超过信号量值")
                    try? await Task.sleep(for: .milliseconds(10))
                    counter.decrement()
                    await sem.release()
                }
            }
        }

        let finalAvailable = await sem.available
        XCTAssertEqual(finalAvailable, 3, "所有任务完成后应恢复全部许可")
    }
}

// MARK: - 测试辅助

/// 线程安全的原子布尔值
private final class UnsafeAtomicBool: @unchecked Sendable {
    private var _value: Bool
    private let lock = NSLock()

    init(_ value: Bool) { self._value = value }

    func store(_ value: Bool) {
        lock.lock()
        _value = value
        lock.unlock()
    }

    func load() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
}

/// 线程安全的原子计数器
private final class AtomicCounter: @unchecked Sendable {
    private var _value: Int = 0
    private let lock = NSLock()

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }

    func decrement() {
        lock.lock()
        _value -= 1
        lock.unlock()
    }
}
