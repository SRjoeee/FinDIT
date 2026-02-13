import AppKit
import Quartz

/// 预览目标信息（URL + 时间范围 + 文件类型）
struct ClipPreviewInfo {
    let url: URL
    let startTime: Double
    let endTime: Double
    let isVideo: Bool
}

/// 预览 + 键盘事件协调器
///
/// 职责：
/// 1. 视频文件 → VideoPreviewPanel（AVPlayerView，支持 seek-to-time）
/// 2. 其他文件 → QLPreviewPanel（标准 Quick Look）
/// 3. 统一管理全局键盘事件（space / 方向键）
///
/// 使用 NSEvent local monitor 而非 SwiftUI `.onKeyPress`，
/// 因为 `.onKeyPress` 无法与 NSViewRepresentable 的 AppKit 焦点系统协调——
/// 搜索框聚焦时它仍会拦截空格键，而搜索框失焦后它又不触发。
@MainActor
final class QuickLookCoordinator: NSObject, @preconcurrency QLPreviewPanelDataSource {
    /// 当前 QL 预览的文件 URL（仅用于非视频文件）
    private var currentURL: URL?

    /// 键盘事件监听器（常驻，ContentView 启动时安装）
    private var eventMonitor: Any?

    /// 任一预览面板是否可见
    var isPreviewVisible: Bool {
        isQLVisible || VideoPreviewPanel.shared.isVisible
    }

    /// QL 面板是否可见
    private var isQLVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists()
            && QLPreviewPanel.shared()!.isVisible
    }

    // MARK: - 切换预览

    /// 切换预览（空格键行为）
    ///
    /// 视频文件路由到 VideoPreviewPanel（支持 seek-to-time），
    /// 其他文件路由到 QLPreviewPanel。
    func toggle(info: ClipPreviewInfo) {
        let isPlayableVideo = info.isVideo && VideoPreviewPanel.canPlay(url: info.url)

        if isPlayableVideo {
            toggleVideo(info: info)
        } else {
            toggleQL(url: info.url)
        }
    }

    /// 面板已打开时更新预览（方向键导航）
    ///
    /// 仅在面板可见时更新，不主动打开面板。
    func updateIfVisible(info: ClipPreviewInfo) {
        let isPlayableVideo = info.isVideo && VideoPreviewPanel.canPlay(url: info.url)

        if isPlayableVideo {
            VideoPreviewPanel.shared.updateIfVisible(
                url: info.url, startTime: info.startTime, endTime: info.endTime
            )
        } else if isQLVisible {
            currentURL = info.url
            QLPreviewPanel.shared()!.reloadData()
        }
    }

    /// 关闭任一打开的预览面板
    func close() {
        if VideoPreviewPanel.shared.isVisible {
            VideoPreviewPanel.shared.close()
        }
        if isQLVisible {
            QLPreviewPanel.shared()!.orderOut(nil)
        }
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Video Preview

    private func toggleVideo(info: ClipPreviewInfo) {
        let videoPanel = VideoPreviewPanel.shared

        if videoPanel.isVisible, videoPanel.currentURL == info.url {
            // 同文件再按 → 关闭
            videoPanel.close()
        } else {
            // 先关 QL（如果打开着）
            if isQLVisible {
                QLPreviewPanel.shared()!.orderOut(nil)
            }
            videoPanel.show(url: info.url, startTime: info.startTime, endTime: info.endTime)
        }
    }

    // MARK: - Quick Look (非视频)

    private func toggleQL(url: URL) {
        if isQLVisible, currentURL == url {
            closeQL()
        } else {
            // 先关视频面板（如果打开着）
            if VideoPreviewPanel.shared.isVisible {
                VideoPreviewPanel.shared.close()
            }
            showQL(url: url)
        }
    }

    private func showQL(url: URL) {
        currentURL = url
        let panel = QLPreviewPanel.shared()!
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    private func closeQL() {
        guard isQLVisible else { return }
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

            // ⌘A → 全选
            if event.keyCode == 0 && event.modifierFlags.contains(.command) {
                Self.postSelectAll()
                return nil
            }

            // Escape → 清空选中
            if event.keyCode == 53 {
                Self.postDeselectAll()
                return nil
            }

            let mods = event.modifierFlags
            switch event.keyCode {
            case 123: Self.postNavigate(.left, modifiers: mods); return nil   // ←
            case 124: Self.postNavigate(.right, modifiers: mods); return nil  // →
            case 125: Self.postNavigate(.down, modifiers: mods); return nil   // ↓
            case 126: Self.postNavigate(.up, modifiers: mods); return nil     // ↑
            case 49:  Self.postToggleQL(); return nil                         // space
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

    private static func postNavigate(_ direction: NavigationDirection, modifiers: NSEvent.ModifierFlags) {
        NotificationCenter.default.post(
            name: .navigateClip,
            object: nil,
            userInfo: ["direction": direction, "modifiers": modifiers]
        )
    }

    private static func postToggleQL() {
        NotificationCenter.default.post(name: .toggleQuickLook, object: nil)
    }

    private static func postSelectAll() {
        NotificationCenter.default.post(name: .selectAllClips, object: nil)
    }

    private static func postDeselectAll() {
        NotificationCenter.default.post(name: .deselectAllClips, object: nil)
    }
}

extension Notification.Name {
    static let navigateClip = Notification.Name("FindIt.navigateClip")
    static let toggleQuickLook = Notification.Name("FindIt.toggleQuickLook")
    static let selectAllClips = Notification.Name("FindIt.selectAllClips")
    static let deselectAllClips = Notification.Name("FindIt.deselectAllClips")
}
