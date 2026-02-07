import SwiftUI
import AppKit

/// 原生搜索框 (NSSearchField)
///
/// macOS 原生 NSSearchField（与 Finder 同款），居中放入 Toolbar。
/// macOS 26 自动获得 Liquid Glass 样式。
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String = "搜索素材..."
    var onSubmit: () -> Void = {}

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        // 不设置 translatesAutoresizingMaskIntoConstraints = false
        // 不添加手动 Auto Layout 约束
        // 让 SwiftUI 通过 .frame() 控制尺寸，避免与 SwiftUI 布局系统冲突
        context.coordinator.searchField = field
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        // 仅在未编辑状态下更新（避免光标跳动 / 竞态条件）
        // currentEditor() 非 nil 表示用户正在编辑，此时不应从外部设置 stringValue
        if nsView.currentEditor() == nil && nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        weak var searchField: NSSearchField?
        private var observation: Any?

        init(_ parent: NativeSearchField) {
            self.parent = parent
            super.init()
            observation = NotificationCenter.default.addObserver(
                forName: .focusSearch,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let field = self?.searchField else { return }
                field.window?.makeFirstResponder(field)
            }
        }

        deinit {
            if let observation {
                NotificationCenter.default.removeObserver(observation)
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                // 提交搜索后失焦，焦点移到结果区（space/arrow 可用于 QL/导航）
                control.window?.makeFirstResponder(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if parent.text.isEmpty {
                    control.window?.makeFirstResponder(nil)
                } else {
                    parent.text = ""
                    (control as? NSSearchField)?.stringValue = ""
                }
                return true
            }
            return false
        }
    }
}
