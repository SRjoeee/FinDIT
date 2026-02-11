import XCTest
@testable import FindItCore

final class ResourceMonitorTests: XCTestCase {

    // MARK: - 初始并发数计算

    func testInitialConcurrencyFullSpeed() {
        // 8 核 → max(2, 8-2) = 6
        let c = ResourceMonitor.initialConcurrency(for: .fullSpeed, processorCount: 8)
        XCTAssertEqual(c, 6)

        // 4 核 → max(2, 4-2) = 2
        let c2 = ResourceMonitor.initialConcurrency(for: .fullSpeed, processorCount: 4)
        XCTAssertEqual(c2, 2)

        // 2 核 → max(2, 2-2) = 2（下限保护）
        let c3 = ResourceMonitor.initialConcurrency(for: .fullSpeed, processorCount: 2)
        XCTAssertEqual(c3, 2)
    }

    func testInitialConcurrencyBalanced() {
        // 8 核 → max(1, 8/2) = 4
        let c = ResourceMonitor.initialConcurrency(for: .balanced, processorCount: 8)
        XCTAssertEqual(c, 4)

        // 2 核 → max(1, 2/2) = 1
        let c2 = ResourceMonitor.initialConcurrency(for: .balanced, processorCount: 2)
        XCTAssertEqual(c2, 1)
    }

    func testInitialConcurrencyBackground() {
        // 8 核 → max(1, 8/4) = 2
        let c = ResourceMonitor.initialConcurrency(for: .background, processorCount: 8)
        XCTAssertEqual(c, 2)

        // 4 核 → max(1, 4/4) = 1
        let c2 = ResourceMonitor.initialConcurrency(for: .background, processorCount: 4)
        XCTAssertEqual(c2, 1)
    }

    // MARK: - 热量降级

    func testComputeConcurrencyThermalNominal() {
        let snapshot = ResourceMonitor.SystemSnapshot(
            thermalState: .nominal,
            availableMemoryMB: 8192,
            processorCount: 8,
            isLowPowerMode: false
        )
        let c = ResourceMonitor.computeConcurrency(snapshot: snapshot, mode: .fullSpeed)
        XCTAssertEqual(c, 6) // max(2, 8-2)
    }

    func testComputeConcurrencyThermalFair() {
        let snapshot = ResourceMonitor.SystemSnapshot(
            thermalState: .fair,
            availableMemoryMB: 8192,
            processorCount: 8,
            isLowPowerMode: false
        )
        let c = ResourceMonitor.computeConcurrency(snapshot: snapshot, mode: .fullSpeed)
        // 6 * 3/4 = 4
        XCTAssertEqual(c, 4)
    }

    func testComputeConcurrencyThermalSerious() {
        let snapshot = ResourceMonitor.SystemSnapshot(
            thermalState: .serious,
            availableMemoryMB: 8192,
            processorCount: 8,
            isLowPowerMode: false
        )
        let c = ResourceMonitor.computeConcurrency(snapshot: snapshot, mode: .fullSpeed)
        // 6 / 2 = 3
        XCTAssertEqual(c, 3)
    }

    func testComputeConcurrencyThermalCritical() {
        let snapshot = ResourceMonitor.SystemSnapshot(
            thermalState: .critical,
            availableMemoryMB: 8192,
            processorCount: 8,
            isLowPowerMode: false
        )
        let c = ResourceMonitor.computeConcurrency(snapshot: snapshot, mode: .fullSpeed)
        XCTAssertEqual(c, 1, "critical 热量应降至 1")
    }

    // MARK: - 内存降级

    func testComputeConcurrencyLowMemory() {
        let snapshot = ResourceMonitor.SystemSnapshot(
            thermalState: .nominal,
            availableMemoryMB: 800, // < 1024
            processorCount: 8,
            isLowPowerMode: false
        )
        let c = ResourceMonitor.computeConcurrency(snapshot: snapshot, mode: .fullSpeed)
        // 6 / 2 = 3（内存 < 1024 减半）
        XCTAssertEqual(c, 3)
    }

    func testComputeConcurrencyVeryLowMemory() {
        let snapshot = ResourceMonitor.SystemSnapshot(
            thermalState: .nominal,
            availableMemoryMB: 400, // < 512
            processorCount: 8,
            isLowPowerMode: false
        )
        let c = ResourceMonitor.computeConcurrency(snapshot: snapshot, mode: .fullSpeed)
        XCTAssertEqual(c, 1, "内存 < 512MB 应降至 1")
    }

    // MARK: - 低电量

    func testComputeConcurrencyLowPowerMode() {
        let snapshot = ResourceMonitor.SystemSnapshot(
            thermalState: .nominal,
            availableMemoryMB: 8192,
            processorCount: 8,
            isLowPowerMode: true
        )
        // 低电量强制后台模式: max(1, 8/4) = 2
        let c = ResourceMonitor.computeConcurrency(snapshot: snapshot, mode: .fullSpeed)
        XCTAssertEqual(c, 2, "低电量应强制后台模式")
    }

    // MARK: - 综合降级

    func testComputeConcurrencyMultipleDegradation() {
        let snapshot = ResourceMonitor.SystemSnapshot(
            thermalState: .serious,
            availableMemoryMB: 800,
            processorCount: 8,
            isLowPowerMode: false
        )
        let c = ResourceMonitor.computeConcurrency(snapshot: snapshot, mode: .balanced)
        // balanced(8核) = 4
        // serious: 4/2 = 2
        // 低内存: 2/2 = 1
        XCTAssertEqual(c, 1)
    }

    // MARK: - 用户活跃度感知

    func testComputeConcurrencyUserActive() {
        // 用户活跃时降速: fullSpeed 6 → 6*2/3 = 4
        let snapshot = ResourceMonitor.SystemSnapshot(
            thermalState: .nominal,
            availableMemoryMB: 8192,
            processorCount: 8,
            isLowPowerMode: false,
            isUserIdle: false
        )
        let c = ResourceMonitor.computeConcurrency(snapshot: snapshot, mode: .fullSpeed)
        XCTAssertEqual(c, 4, "用户活跃时应降至 2/3")
    }

    func testComputeConcurrencyUserActiveBalanced() {
        // balanced(8核)=4, 用户活跃 → 4*2/3 = 2
        let snapshot = ResourceMonitor.SystemSnapshot(
            thermalState: .nominal,
            availableMemoryMB: 8192,
            processorCount: 8,
            isLowPowerMode: false,
            isUserIdle: false
        )
        let c = ResourceMonitor.computeConcurrency(snapshot: snapshot, mode: .balanced)
        XCTAssertEqual(c, 2, "balanced + 用户活跃")
    }

    func testComputeConcurrencyUserActiveBackgroundNoFurtherDegradation() {
        // background 模式不再额外降级
        let snapshot = ResourceMonitor.SystemSnapshot(
            thermalState: .nominal,
            availableMemoryMB: 8192,
            processorCount: 8,
            isLowPowerMode: false,
            isUserIdle: false
        )
        let c = ResourceMonitor.computeConcurrency(snapshot: snapshot, mode: .background)
        XCTAssertEqual(c, 2, "background 不应因用户活跃再降级")
    }

    func testComputeConcurrencyUserIdleFullSpeed() {
        // 用户空闲时不降速
        let snapshot = ResourceMonitor.SystemSnapshot(
            thermalState: .nominal,
            availableMemoryMB: 8192,
            processorCount: 8,
            isLowPowerMode: false,
            isUserIdle: true
        )
        let c = ResourceMonitor.computeConcurrency(snapshot: snapshot, mode: .fullSpeed)
        XCTAssertEqual(c, 6, "用户空闲不应降速")
    }

    // MARK: - ResourceMonitor actor

    func testMonitorSampleAndRecommend() async {
        let monitor = ResourceMonitor(mode: .balanced)
        let recommended = await monitor.sampleAndRecommend()
        // 应该 >= 1
        XCTAssertGreaterThanOrEqual(recommended, 1)
    }

    func testMonitorSetMode() async {
        let monitor = ResourceMonitor(mode: .balanced)

        await monitor.setMode(.background)
        let mode = await monitor.currentMode
        XCTAssertEqual(mode, .background)

        await monitor.setMode(.fullSpeed)
        let mode2 = await monitor.currentMode
        XCTAssertEqual(mode2, .fullSpeed)
    }
}
