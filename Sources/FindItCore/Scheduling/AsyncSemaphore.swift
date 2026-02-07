import Foundation

/// 异步信号量 — 控制并发任务数量
///
/// 基于 Swift actor 的异步信号量实现，用于资源池模型中的
/// 并发控制。支持动态调整最大许可数（配合 ResourceMonitor 使用）。
///
/// ```swift
/// let sem = AsyncSemaphore(value: 3)
/// await sem.acquire()  // 获取许可（可能挂起）
/// defer { Task { await sem.release() } }
/// // ... 执行需要受控并发的工作 ...
/// ```
public actor AsyncSemaphore {

    /// 当前可用许可数
    private var permits: Int

    /// 最大许可数上限
    private var maxPermits: Int

    /// 排队等待的 continuation 列表（FIFO）
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// 创建信号量
    ///
    /// - Parameter value: 初始许可数（同时也是最大许可数）
    public init(value: Int) {
        precondition(value >= 1, "AsyncSemaphore value must be >= 1")
        self.permits = value
        self.maxPermits = value
    }

    // MARK: - 核心操作

    /// 获取一个许可
    ///
    /// 如果有可用许可，立即返回并消耗一个许可。
    /// 否则挂起当前任务，直到有许可可用。
    ///
    /// 调用方应在获取后检查 `Task.isCancelled` 以支持协作式取消。
    public func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// 释放一个许可
    ///
    /// 如果有等待者，唤醒最早排队的一个（FIFO）。
    /// 否则归还许可（不超过 maxPermits）。
    public func release() {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume()
        } else {
            permits = min(permits + 1, maxPermits)
        }
    }

    // MARK: - 状态查询

    /// 当前可用许可数
    public var available: Int { permits }

    /// 当前等待者数量
    public var waitingCount: Int { waiters.count }

    /// 当前最大许可数
    public var currentMax: Int { maxPermits }

    // MARK: - 动态调整

    /// 动态调整最大许可数
    ///
    /// - 增加: 立即释放额外许可（唤醒等待者或增加可用数）
    /// - 减少: 不回收已发出的许可，通过后续 `release()` 自然收紧
    ///
    /// - Parameter newMax: 新的最大许可数（下限 1）
    public func setMaxPermits(_ newMax: Int) {
        let clamped = max(1, newMax)
        let oldMax = maxPermits
        maxPermits = clamped

        if clamped > oldMax {
            let extra = clamped - oldMax
            for _ in 0..<extra {
                if !waiters.isEmpty {
                    let waiter = waiters.removeFirst()
                    waiter.resume()
                } else {
                    permits = min(permits + 1, maxPermits)
                }
            }
        }
        // 减少: 不立即回收，后续 release 通过 min(permits + 1, maxPermits) 自然收紧
    }

    /// 唤醒所有等待者
    ///
    /// 用于取消或关闭调度器。等待者被唤醒后应检查 `Task.isCancelled`。
    public func releaseAll() {
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume()
        }
    }
}
