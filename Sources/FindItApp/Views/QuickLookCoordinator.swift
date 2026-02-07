import AppKit
import Quartz

/// Quick Look 预览协调器
///
/// 桥接 AppKit 的 QLPreviewPanel 到 SwiftUI。
/// 按空格键打开/关闭视频预览，选择变更时自动更新预览内容。
///
/// QL 面板打开时安装 local event monitor，拦截方向键转发给主窗口，
/// 实现 Finder 式的"QL 预览中方向键切换文件"交互。
@MainActor
final class QuickLookCoordinator: NSObject, @preconcurrency QLPreviewPanelDataSource {
    /// 当前预览的文件 URL
    private var currentURL: URL?

    /// 键盘事件监听器（QL 打开时安装，关闭时移除）
    private var eventMonitor: Any?

    /// QL 面板是否可见
    var isPreviewVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists()
            && QLPreviewPanel.shared()!.isVisible
    }

    /// 切换预览（空格键行为）
    ///
    /// 同一文件再按 → 关闭；不同文件或未打开 → 打开/更新。
    func toggle(url: URL) {
        if isPreviewVisible, currentURL == url {
            close()
        } else {
            show(url: url)
        }
    }

    /// 更新预览内容（选择变更时调用）
    ///
    /// 仅在面板已打开时更新，不主动打开面板。
    /// 不调用 makeKeyAndOrderFront，避免方向键导航时抢焦点。
    func updateIfVisible(url: URL) {
        guard isPreviewVisible else { return }
        currentURL = url
        QLPreviewPanel.shared()!.reloadData()
    }

    /// 关闭预览面板并恢复主窗口焦点
    func close() {
        guard isPreviewVisible else { return }
        QLPreviewPanel.shared()!.orderOut(nil)
        removeEventMonitor()
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        currentURL != nil ? 1 : 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        currentURL as? NSURL
    }

    // MARK: - Private

    private func show(url: URL) {
        currentURL = url
        let panel = QLPreviewPanel.shared()!
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
        installEventMonitor()
    }

    // MARK: - Event Monitor

    /// 安装键盘事件监听器
    ///
    /// QL 面板获得焦点后，SwiftUI 的 `.onKeyPress` 不再触发。
    /// 通过 `NSEvent.addLocalMonitorForEvents` 拦截应用内所有方向键/空格键，
    /// 将方向键转发给 ContentView（通过 Notification），空格键关闭面板。
    ///
    /// 不限制 `event.window` 类型——`reloadData()` 后 macOS 可能短暂
    /// 切换焦点到主窗口，导致 `event.window is QLPreviewPanel` 失败。
    /// QL 可见期间拦截所有窗口的导航键（与 Finder 行为一致）。
    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // QL 已关闭 → 清理 monitor，放行事件
            if !self.isPreviewVisible {
                self.removeEventMonitor()
                return event
            }

            switch event.keyCode {
            case 123: // ←
                Self.postNavigate("left")
                return nil
            case 124: // →
                Self.postNavigate("right")
                return nil
            case 125: // ↓
                Self.postNavigate("down")
                return nil
            case 126: // ↑
                Self.postNavigate("up")
                return nil
            case 49: // space → 关闭 QL
                self.close()
                return nil
            default:
                return event
            }
        }
    }

    /// 移除键盘事件监听器
    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private static func postNavigate(_ direction: String) {
        NotificationCenter.default.post(
            name: .qlNavigateClip,
            object: nil,
            userInfo: ["direction": direction]
        )
    }
}

extension Notification.Name {
    /// QL 面板中方向键导航事件
    static let qlNavigateClip = Notification.Name("FindIt.qlNavigateClip")
}
