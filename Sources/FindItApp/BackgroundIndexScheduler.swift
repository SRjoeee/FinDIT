import Foundation

/// 夜间自动索引调度器
///
/// 使用 `NSBackgroundActivityScheduler` 每 24 小时在系统空闲时
/// 自动触发已注册文件夹的重索引，确保新增/修改的视频及时被发现。
///
/// ```swift
/// // App 启动时注册
/// BackgroundIndexScheduler.shared.indexingManager = indexingManager
/// BackgroundIndexScheduler.shared.register()
/// ```
@MainActor
final class BackgroundIndexScheduler {

    static let shared = BackgroundIndexScheduler()

    /// IndexingManager 引用（弱引用避免循环）
    weak var indexingManager: IndexingManager?

    private var scheduler: NSBackgroundActivityScheduler?

    private init() {}

    /// 注册后台活动调度
    ///
    /// 每 24 小时在系统空闲时触发一次索引检查。
    /// macOS 会自动选择电源充足、系统负载低的时间窗口执行。
    func register() {
        guard scheduler == nil else { return }

        let s = NSBackgroundActivityScheduler(
            identifier: "com.findit.background-indexing"
        )
        s.repeats = true
        s.interval = 24 * 3600       // 24 小时
        s.tolerance = 3600            // 容忍 1 小时延迟
        s.qualityOfService = .background

        s.schedule { [weak self] completion in
            Task { @MainActor [weak self] in
                await self?.performBackgroundIndexing()
                completion(.finished)
            }
        }

        scheduler = s
        print("[BackgroundIndexScheduler] 已注册 24h 自动索引")
    }

    /// 取消调度
    func invalidate() {
        scheduler?.invalidate()
        scheduler = nil
    }

    /// 执行后台索引
    private func performBackgroundIndexing() async {
        guard let mgr = indexingManager else { return }
        guard !mgr.isIndexing else {
            print("[BackgroundIndexScheduler] 已有索引任务在运行，跳过")
            return
        }

        print("[BackgroundIndexScheduler] 开始自动索引")
        mgr.indexPendingFolders()
    }
}
