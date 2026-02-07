import Foundation

/// 索引性能模式
///
/// 控制后台索引的资源使用策略。影响视频并发处理数量、
/// Task 优先级等参数。可在设置页配置，运行时动态切换。
///
/// | 模式 | 并发数 | QoS | 场景 |
/// |------|--------|-----|------|
/// | fullSpeed | cores-2 | high | 用户手动选择快速完成 |
/// | balanced | cores/2 | medium | 默认模式 |
/// | background | cores/4 | low | 最低干扰，后台运行 |
public enum PerformanceMode: String, CaseIterable, Codable, Sendable {
    /// 全速：最大并发，尽快完成索引
    case fullSpeed = "full_speed"
    /// 平衡：适度并发，不影响日常使用（默认）
    case balanced = "balanced"
    /// 后台：最低干扰，仅空闲时处理
    case background = "background"

    /// 显示名称
    public var displayName: String {
        switch self {
        case .fullSpeed: return "全速"
        case .balanced: return "平衡"
        case .background: return "后台"
        }
    }

    /// 描述说明
    public var descriptionText: String {
        switch self {
        case .fullSpeed: return "最大并发，尽快完成索引"
        case .balanced: return "适度并发，不影响日常使用"
        case .background: return "最低干扰，仅空闲时处理"
        }
    }

    /// 对应的 Task 优先级
    public var taskPriority: TaskPriority {
        switch self {
        case .fullSpeed: return .high
        case .balanced: return .medium
        case .background: return .low
        }
    }
}
