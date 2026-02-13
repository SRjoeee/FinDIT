import AppKit
import AVKit
import AVFoundation

/// 浮动视频预览面板 — 支持 seek-to-time
///
/// 替代 QLPreviewPanel 用于视频文件预览，提供帧精确的时间定位。
/// 面板行为对齐 Quick Look：浮动、不抢焦点、Space 切换、进度保留。
///
/// 使用 `AVPlayerView`（同 QuickTime Player 原生控件），不造轮子。
@MainActor
final class VideoPreviewPanel: NSObject, NSWindowDelegate {

    /// 单例（同 QLPreviewPanel.shared() 模式）
    static let shared = VideoPreviewPanel()

    private var panel: NSPanel?
    private var playerView: AVPlayerView?
    private var player: AVPlayer?

    /// 异步 resize 任务（快速切换时取消上一次）
    private var sizeAdjustTask: Task<Void, Never>?

    /// 当前预览的文件 URL
    private(set) var currentURL: URL?

    /// 当前 clip 的起始时间
    private(set) var currentStartTime: Double = 0

    /// 面板是否可见
    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    /// AVPlayer 不支持的视频格式（RAW 专有格式）
    private static let nonPlayableExtensions: Set<String> = ["braw", "r3d", "nev"]

    /// 检查 AVPlayer 是否能播放该文件
    static func canPlay(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return !nonPlayableExtensions.contains(ext)
    }

    // MARK: - 公开接口

    /// 显示视频预览，seek 到 startTime
    ///
    /// - 同文件: 只 seek（如果时间不同）
    /// - 不同文件: 替换播放项 + seek + resize
    /// - 面板关闭后重开同文件: 恢复播放（进度保留）
    ///
    /// 新文件 + 面板隐藏时：先异步 resize 再显示（避免窗口变形）。
    /// 新文件 + 面板已可见时：立即替换内容，resize 平滑动画过渡。
    func show(url: URL, startTime: Double, endTime: Double) {
        if panel == nil { createPanel() }
        guard let player else { return }

        if currentURL == url {
            // 同文件 — 面板已隐藏时恢复或 seek，已可见时 seek
            if !isVisible {
                if abs(currentStartTime - startTime) > 0.1 {
                    // 不同片段 → seek 到新起点（seekTo 完成后自动 play）
                    currentStartTime = startTime
                    updateTitle(url: url, startTime: startTime)
                    seekTo(startTime)
                } else {
                    // 同片段恢复 → 从上次暂停位置继续
                    player.play()
                }
                panel?.makeKeyAndOrderFront(nil)
            } else if abs(currentStartTime - startTime) > 0.1 {
                seekTo(startTime)
                currentStartTime = startTime
                updateTitle(url: url, startTime: startTime)
            }
        } else {
            // 不同文件 → 替换播放项
            let wasVisible = isVisible
            let asset = AVURLAsset(url: url)
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            currentURL = url
            currentStartTime = startTime
            updateTitle(url: url, startTime: startTime)
            seekTo(startTime)

            // 异步读取视频尺寸并 resize 面板
            sizeAdjustTask?.cancel()
            sizeAdjustTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.adjustPanelSize(for: asset, animate: wasVisible)
                // 面板隐藏时：resize 完成后再显示（避免变形）
                // 失败时也确保面板显示（fallback 到默认尺寸）
                if !wasVisible, !(self.panel?.isVisible ?? true) {
                    self.panel?.makeKeyAndOrderFront(nil)
                }
            }
            // 面板已可见时：内容已替换，resize 异步动画
            // 面板隐藏时：由 Task 在 resize 后显示
        }
    }

    /// 面板已打开时更新预览（方向键导航）
    ///
    /// 仅在面板可见时更新，不主动打开面板。
    func updateIfVisible(url: URL, startTime: Double, endTime: Double) {
        guard isVisible else { return }
        show(url: url, startTime: startTime, endTime: endTime)
    }

    /// 关闭面板（暂停+隐藏，不销毁 player，进度保留）
    func close() {
        player?.pause()
        panel?.orderOut(nil)
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate

    /// 红色关闭按钮 → 转为 pause + hide（同 Space 关闭行为，面板保活可复用）
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    // MARK: - 面板创建

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 450),
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]

        // 标题栏外观：透明 + 隐藏文字（保留红绿灯按钮）
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .black
        panel.minSize = NSSize(width: 400, height: 280)
        panel.center()
        panel.title = "Preview"

        // AVPlayerView（原生浮动控件，同 QuickTime Player）
        let playerView = AVPlayerView()
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true

        let player = AVPlayer()
        player.automaticallyWaitsToMinimizeStalling = false
        playerView.player = player

        panel.contentView = playerView

        self.panel = panel
        self.playerView = playerView
        self.player = player
    }

    // MARK: - Seek

    private func seekTo(_ time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor in
                self?.player?.play()
            }
        }
    }

    // MARK: - 标题

    private func updateTitle(url: URL, startTime: Double) {
        let name = url.lastPathComponent
        let tc = Self.formatTimecode(startTime)
        panel?.title = "\(name) — \(tc)"
        panel?.representedURL = url
    }

    /// 格式化秒数为时间码 (HH:MM:SS 或 MM:SS)
    static func formatTimecode(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - 宽高比自适应

    /// 读取视频 naturalSize，调整面板尺寸匹配视频宽高比
    ///
    /// - Parameter animate: false = 静默 resize（面板隐藏时），true = 平滑过渡（面板可见时）
    private func adjustPanelSize(for asset: AVURLAsset, animate: Bool = true) async {
        guard let panel else { return }
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return }
            let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
            // 应用 preferredTransform 处理手机竖拍等旋转
            let transformed = naturalSize.applying(transform)
            let corrected = CGSize(width: abs(transformed.width), height: abs(transformed.height))
            guard corrected.width > 0, corrected.height > 0 else { return }

            let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
            let targetSize = Self.fitSize(videoSize: corrected, screen: screen)

            // 以当前中心点为基准 resize，保持面板位置稳定
            let current = panel.frame
            let newOrigin = NSPoint(
                x: current.midX - targetSize.width / 2,
                y: current.midY - targetSize.height / 2
            )
            let newFrame = NSRect(origin: newOrigin, size: targetSize)
            let constrained = panel.constrainFrameRect(newFrame, to: screen)
            panel.setFrame(constrained, display: true, animate: animate)
        } catch {
            return
        }
    }

    /// 计算适合视频宽高比的面板尺寸（不超过屏幕 80%，不小于 minSize）
    private static func fitSize(videoSize: CGSize, screen: NSScreen) -> NSSize {
        let aspect = videoSize.width / videoSize.height
        let visible = screen.visibleFrame

        var w = visible.width * 0.6
        var h = w / aspect

        let maxW = visible.width * 0.8
        let maxH = visible.height * 0.8
        if w > maxW { w = maxW; h = w / aspect }
        if h > maxH { h = maxH; w = h * aspect }

        w = max(w, 400)
        h = max(h, 280)

        return NSSize(width: w, height: h)
    }
}
