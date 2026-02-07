import AppKit
import Quartz

/// Quick Look 预览 + 键盘事件协调器
///
/// 职责：
/// 1. 桥接 AppKit 的 QLPreviewPanel 到 SwiftUI
/// 2. 统一管理全局键盘事件（space / 方向键）
///
/// 使用 NSEvent local monitor 而非 SwiftUI `.onKeyPress`，
/// 因为 `.onKeyPress` 无法与 NSViewRepresentable 的 AppKit 焦点系统协调——
/// 搜索框聚焦时它仍会拦截空格键，而搜索框失焦后它又不触发。
@MainActor
final class QuickLookCoordinator: NSObject, @preconcurrency QLPreviewPanelDataSource {
    /// 当前预览的文件 URL
    private var currentURL: URL?

    /// 键盘事件监听器（常驻，ContentView 启动时安装）
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
    }

    // MARK: - Keyboard Monitor

    /// 启动键盘事件监听（ContentView 初始化时调用一次）
    ///
    /// 搜索框聚焦（firstResponder 是 NSTextView）时放行所有按键，
    /// 否则拦截方向键和空格键并通过 Notification 转发给 ContentView。
    func startMonitoring() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard self != nil else { return event }

            // 文本编辑中（搜索框等）→ 放行所有按键
            if NSApp.keyWindow?.firstResponder is NSTextView {
                return event
            }

            switch event.keyCode {
            case 123: Self.postNavigate("left"); return nil   // ←
            case 124: Self.postNavigate("right"); return nil  // →
            case 125: Self.postNavigate("down"); return nil   // ↓
            case 126: Self.postNavigate("up"); return nil     // ↑
            case 49:  Self.postToggleQL(); return nil         // space
            default:  return event
            }
        }
    }

    func stopMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private static func postNavigate(_ direction: String) {
        NotificationCenter.default.post(
            name: .navigateClip,
            object: nil,
            userInfo: ["direction": direction]
        )
    }

    private static func postToggleQL() {
        NotificationCenter.default.post(name: .toggleQuickLook, object: nil)
    }
}

extension Notification.Name {
    static let navigateClip = Notification.Name("FindIt.navigateClip")
    static let toggleQuickLook = Notification.Name("FindIt.toggleQuickLook")
}
