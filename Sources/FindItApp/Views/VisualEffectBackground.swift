import SwiftUI
import AppKit

/// 桌面壁纸透出的毛玻璃背景
///
/// 使用 NSVisualEffectView 实现 Permute 风格的窗口透明效果。
/// 配合 `.ignoresSafeArea()` 使用可扩展到整个窗口（含 toolbar 区域）。
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
