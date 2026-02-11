import Foundation
import Network

/// 网络连通性监控器
///
/// 使用 NWPathMonitor 监听网络状态变化，为管线 API 调用
/// 提供"等待网络恢复"机制，避免断线时反复重试浪费时间。
///
/// ```swift
/// let net = NetworkResilience()
/// await net.start()
/// // API 调用前:
/// try await net.waitForConnection(timeout: .seconds(60))
/// ```
public actor NetworkResilience {

    // MARK: - Types

    /// 网络连接状态
    public enum Status: Sendable {
        case connected
        case disconnected
        case unknown
    }

    // MARK: - State

    public private(set) var status: Status = .unknown

    /// 当前是否可联网（unknown 视为可用，避免阻塞首次启动）
    public var isConnected: Bool {
        status == .connected || status == .unknown
    }

    private var monitor: NWPathMonitor?
    private var monitorQueue: DispatchQueue?
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    // MARK: - Lifecycle

    public init() {}

    /// 启动网络监听
    public func start() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        let q = DispatchQueue(label: "com.findit.network-monitor", qos: .utility)
        monitor = m
        monitorQueue = q

        m.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task {
                await self.handlePathUpdate(path)
            }
        }
        m.start(queue: q)
    }

    /// 停止监听，取消所有等待者
    public func stop() {
        monitor?.cancel()
        monitor = nil
        monitorQueue = nil
        // 唤醒所有等待者并抛出 CancellationError
        let pending = waiters
        waiters.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: CancellationError())
        }
    }

    // MARK: - Wait for Connection

    /// 异步等待网络恢复
    ///
    /// 已连接时立即返回。断线时挂起直到网络恢复或超时。
    ///
    /// - Parameter timeout: 最大等待时间，默认 5 分钟
    /// - Throws: `NetworkResilienceError.timeout` 或 `CancellationError`
    public func waitForConnection(timeout: Duration = .seconds(300)) async throws {
        if isConnected { return }

        try await withThrowingTaskGroup(of: Void.self) { group in
            let id = UUID()

            // 等待网络恢复
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { await self.registerWaiter(id: id, continuation: continuation) }
                }
            }

            // 超时竞争
            group.addTask {
                try await Task.sleep(for: timeout)
                throw NetworkResilienceError.timeout
            }

            // 取第一个完成的
            do {
                try await group.next()
                group.cancelAll()
            } catch is NetworkResilienceError {
                // 超时：移除 waiter 后抛出
                self.removeWaiter(id: id)
                group.cancelAll()
                throw NetworkResilienceError.timeout
            } catch {
                self.removeWaiter(id: id)
                group.cancelAll()
                throw error
            }
        }
    }

    // MARK: - Testing

    /// 测试用：直接设置网络状态并唤醒等待者
    ///
    /// 生产代码不应调用此方法，仅供单元测试模拟断线/恢复。
    func forceStatus(_ newStatus: Status) {
        let wasDisconnected = !isConnected
        status = newStatus
        if wasDisconnected && isConnected {
            let pending = waiters
            waiters.removeAll()
            for (_, continuation) in pending {
                continuation.resume()
            }
        }
    }

    // MARK: - Private

    private func handlePathUpdate(_ path: NWPath) {
        let newStatus: Status = path.status == .satisfied ? .connected : .disconnected
        let wasDisconnected = !isConnected
        status = newStatus

        // 从断线恢复 → 唤醒所有等待者
        if wasDisconnected && isConnected {
            let pending = waiters
            waiters.removeAll()
            for (_, continuation) in pending {
                continuation.resume()
            }
        }
    }

    private func registerWaiter(id: UUID, continuation: CheckedContinuation<Void, any Error>) {
        // 在注册前再检查一次——可能在排队期间已恢复
        if isConnected {
            continuation.resume()
            return
        }
        waiters[id] = continuation
    }

    private func removeWaiter(id: UUID) {
        if let continuation = waiters.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        }
    }
}

// MARK: - Errors

/// NetworkResilience 错误类型
public enum NetworkResilienceError: Error, Sendable {
    /// 等待网络恢复超时
    case timeout
}
