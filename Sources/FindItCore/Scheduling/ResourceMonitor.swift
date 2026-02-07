import Foundation

/// 系统资源监控器
///
/// 周期性采样系统状态（热量、内存、CPU、电源），根据
/// `PerformanceMode` 和实时系统状态推荐视频并发数。
///
/// 核心逻辑:
/// - 基础并发数由 PerformanceMode 决定
/// - 热量降级: `.serious` → 半速, `.critical` → 单线程
/// - 内存压力: <1GB → 半速, <512MB → 单线程
/// - 低电量: 强制后台模式
///
/// 监控是持续的（每 5 秒采样），不是一次性快照。
/// IndexingScheduler 根据 `onChange` 回调动态调整信号量。
public actor ResourceMonitor {

    // MARK: - 系统快照

    /// 系统状态快照
    public struct SystemSnapshot: Sendable {
        /// 热量状态
        public let thermalState: ProcessInfo.ThermalState
        /// 可用内存 (MB)
        public let availableMemoryMB: Int
        /// 活跃处理器核心数
        public let processorCount: Int
        /// 是否启用低电量模式
        public let isLowPowerMode: Bool
        /// 采样时间
        public let timestamp: Date

        public init(
            thermalState: ProcessInfo.ThermalState,
            availableMemoryMB: Int,
            processorCount: Int,
            isLowPowerMode: Bool,
            timestamp: Date = Date()
        ) {
            self.thermalState = thermalState
            self.availableMemoryMB = availableMemoryMB
            self.processorCount = processorCount
            self.isLowPowerMode = isLowPowerMode
            self.timestamp = timestamp
        }
    }

    // MARK: - 状态

    private var performanceMode: PerformanceMode
    private var monitorTask: Task<Void, Never>?

    /// 最新系统快照
    public private(set) var latestSnapshot: SystemSnapshot

    // MARK: - 初始化

    public init(mode: PerformanceMode = .balanced) {
        self.performanceMode = mode
        self.latestSnapshot = Self.captureSnapshot()
    }

    // MARK: - 公开方法

    /// 当前性能模式
    public var currentMode: PerformanceMode { performanceMode }

    /// 基于最新快照的推荐并发数
    public var recommendedConcurrency: Int {
        Self.computeConcurrency(snapshot: latestSnapshot, mode: performanceMode)
    }

    /// 更新性能模式
    public func setMode(_ mode: PerformanceMode) {
        self.performanceMode = mode
    }

    /// 手动采样并返回推荐并发数
    @discardableResult
    public func sampleAndRecommend() -> Int {
        latestSnapshot = Self.captureSnapshot()
        return Self.computeConcurrency(snapshot: latestSnapshot, mode: performanceMode)
    }

    /// 启动持续监控
    ///
    /// 每隔 `interval` 采样系统状态，计算推荐并发数，
    /// 若与上次不同则调用 `onChange`。
    ///
    /// - Parameters:
    ///   - interval: 采样间隔（默认 5 秒）
    ///   - onChange: 推荐并发数变化时回调（参数: 新的推荐并发数）
    public func startMonitoring(
        interval: Duration = .seconds(5),
        onChange: @Sendable @escaping (Int) -> Void
    ) {
        stopMonitoring()
        var lastRecommended = recommendedConcurrency

        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                guard let self = self else { break }

                let recommended = await self.sampleAndRecommend()
                if recommended != lastRecommended {
                    lastRecommended = recommended
                    onChange(recommended)
                }
            }
        }
    }

    /// 停止监控
    public func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    // MARK: - 静态方法

    /// 根据模式计算初始并发数（不依赖运行时采样）
    ///
    /// 用于 IndexingScheduler 初始化时确定信号量初始值。
    public static func initialConcurrency(
        for mode: PerformanceMode,
        processorCount: Int? = nil
    ) -> Int {
        let cores = processorCount ?? ProcessInfo.processInfo.activeProcessorCount
        switch mode {
        case .fullSpeed: return max(2, cores - 2)
        case .balanced:  return max(1, cores / 2)
        case .background: return max(1, cores / 4)
        }
    }

    // MARK: - 内部方法

    /// 采集系统快照
    private static func captureSnapshot() -> SystemSnapshot {
        SystemSnapshot(
            thermalState: ProcessInfo.processInfo.thermalState,
            availableMemoryMB: availableMemoryMB(),
            processorCount: ProcessInfo.processInfo.activeProcessorCount,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    /// 获取可用内存 (MB)
    ///
    /// macOS 无 `os_proc_available_memory()`，通过 Mach `host_statistics64`
    /// 获取 free + inactive 页面数估算可用内存。
    private static func availableMemoryMB() -> Int {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            // 回退: 返回总物理内存的一半作为估算
            return Int(ProcessInfo.processInfo.physicalMemory / 2 / 1_048_576)
        }
        let pageSize = UInt64(vm_kernel_page_size)
        let free = UInt64(stats.free_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        return Int((free + inactive) / 1_048_576)
    }

    /// 根据快照和模式计算推荐并发数
    ///
    /// 算法: 基础并发(mode) → 热量降级 → 内存降级
    static func computeConcurrency(
        snapshot: SystemSnapshot,
        mode: PerformanceMode
    ) -> Int {
        let cores = snapshot.processorCount

        // 低电量强制后台模式
        let effectiveMode = snapshot.isLowPowerMode ? .background : mode

        // 基础并发数
        var concurrency: Int
        switch effectiveMode {
        case .fullSpeed:
            concurrency = max(2, cores - 2)
        case .balanced:
            concurrency = max(1, cores / 2)
        case .background:
            concurrency = max(1, cores / 4)
        }

        // 热量降级
        switch snapshot.thermalState {
        case .critical:
            concurrency = 1
        case .serious:
            concurrency = max(1, concurrency / 2)
        case .fair:
            concurrency = max(1, concurrency * 3 / 4)
        case .nominal:
            break
        @unknown default:
            break
        }

        // 内存压力降级
        if snapshot.availableMemoryMB < 512 {
            concurrency = 1
        } else if snapshot.availableMemoryMB < 1024 {
            concurrency = max(1, concurrency / 2)
        }

        return concurrency
    }
}
