import Foundation

/// Gemini API 限速器
///
/// 使用滑动窗口算法控制请求速率 (默认 9 RPM)，
/// 并通过 429 反馈动态降速 + 成功反馈缓慢恢复。
///
/// 用法：
/// ```swift
/// let limiter = GeminiRateLimiter()
/// try await limiter.waitForPermission()
/// // ... 发送请求 ...
/// await limiter.reportSuccess()
/// // 或遇到 429:
/// await limiter.reportRateLimit()
/// ```
public actor GeminiRateLimiter {

    /// 限速器配置
    public struct Config: Equatable, Sendable {
        /// 滑动窗口内允许的最大请求数（初始值）
        public var maxRequestsPerWindow: Int
        /// 滑动窗口时长（秒）
        public var windowDuration: TimeInterval
        /// 429 退避后降速的最小 RPM
        public var minRequestsPerWindow: Int

        public static let `default` = Config(
            maxRequestsPerWindow: 9,   // Gemini 10 RPM - 1 安全余量
            windowDuration: 60.0,
            minRequestsPerWindow: 3
        )

        public init(
            maxRequestsPerWindow: Int = 9,
            windowDuration: TimeInterval = 60.0,
            minRequestsPerWindow: Int = 3
        ) {
            self.maxRequestsPerWindow = maxRequestsPerWindow
            self.windowDuration = windowDuration
            self.minRequestsPerWindow = minRequestsPerWindow
        }
    }

    private let config: Config

    /// 当前滑动窗口允许的最大请求数（可被 429 反馈降低）
    private var currentMaxRequests: Int

    /// 窗口内的请求时间戳
    private var timestamps: [Date] = []

    /// 429 退避截止时间
    private var backoffUntil: Date = .distantPast

    /// 连续 429 次数（用于指数退避）
    private var consecutiveRateLimits: Int = 0

    /// 每日请求计数
    private var dailyCount: Int = 0

    /// 每日计数器重置日期 (YYYY-MM-DD)
    private var dailyCountDate: String = ""

    public init(config: Config = .default) {
        self.config = config
        self.currentMaxRequests = config.maxRequestsPerWindow
    }

    // MARK: - 公开接口

    /// 等待获得发送许可
    ///
    /// 检查滑动窗口和 429 退避状态。如果窗口已满或在退避期内，
    /// 异步等待直到可以发送。支持 Task 取消。
    public func waitForPermission() async throws {
        // 1. 检查 429 退避期
        let now = Date()
        if now < backoffUntil {
            let waitNanos = UInt64(backoffUntil.timeIntervalSince(now) * 1_000_000_000)
            try await Task.sleep(nanoseconds: waitNanos)
        }

        // 2. 清理过期时间戳
        pruneExpiredTimestamps()

        // 3. 如果窗口已满，等待最早请求过期
        if timestamps.count >= currentMaxRequests {
            let oldest = timestamps[0]
            let elapsed = Date().timeIntervalSince(oldest)
            let waitTime = config.windowDuration - elapsed + 0.5  // 0.5s 安全缓冲
            if waitTime > 0 {
                try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            }
            // 重新清理
            pruneExpiredTimestamps()
        }

        // 4. 记录本次请求
        timestamps.append(Date())
        incrementDailyCount()
    }

    /// 报告请求成功 — 缓慢恢复允许的 RPM
    public func reportSuccess() {
        consecutiveRateLimits = 0
        if currentMaxRequests < config.maxRequestsPerWindow {
            currentMaxRequests = min(currentMaxRequests + 1, config.maxRequestsPerWindow)
        }
    }

    /// 报告收到 429 — 动态降速 + 设置退避期
    public func reportRateLimit() {
        consecutiveRateLimits += 1

        // 降低允许的 RPM
        currentMaxRequests = max(
            config.minRequestsPerWindow,
            currentMaxRequests - 2
        )

        // 指数退避：2^n 秒，最大 60 秒
        let backoffSeconds = min(pow(2.0, Double(consecutiveRateLimits)), 60.0)
        backoffUntil = Date().addingTimeInterval(backoffSeconds)
    }

    // MARK: - 状态查询

    /// 当前滑动窗口内的请求数
    public var pendingRequestCount: Int {
        let now = Date()
        return timestamps.filter { now.timeIntervalSince($0) < config.windowDuration }.count
    }

    /// 当前允许的每分钟请求数
    public var effectiveMaxRequests: Int {
        currentMaxRequests
    }

    /// 今日已发送的请求数
    public var todayRequestCount: Int {
        let today = Self.todayString()
        return dailyCountDate == today ? dailyCount : 0
    }

    /// 是否处于 429 退避期
    public var isInBackoff: Bool {
        Date() < backoffUntil
    }

    // MARK: - 内部方法

    /// 清理滑动窗口外的时间戳
    private func pruneExpiredTimestamps() {
        let cutoff = Date().addingTimeInterval(-config.windowDuration)
        timestamps.removeAll { $0 < cutoff }
    }

    /// 增加每日计数
    private func incrementDailyCount() {
        let today = Self.todayString()
        if dailyCountDate != today {
            dailyCount = 0
            dailyCountDate = today
        }
        dailyCount += 1
    }

    /// 获取今日日期字符串 (YYYY-MM-DD)
    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }
}
