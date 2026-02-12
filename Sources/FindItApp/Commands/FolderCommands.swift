import SwiftUI

/// 菜单栏命令
///
/// File 菜单: 添加/管理文件夹。Edit 菜单: ⌘F 聚焦搜索框。
struct FolderCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("添加素材文件夹...") {
                NotificationCenter.default.post(name: .addFolder, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("管理文件夹...") {
                NotificationCenter.default.post(name: .manageFolder, object: nil)
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
        }

        CommandGroup(after: .importExport) {
            Button("导出到 NLE...") {
                NotificationCenter.default.post(name: .exportToNLE, object: nil)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }

        // ⌘F 聚焦搜索框（添加到 Edit 菜单尾部，不替换系统项）
        CommandGroup(after: .textEditing) {
            Button("搜索素材") {
                NotificationCenter.default.post(name: .focusSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
        }
    }
}

extension Notification.Name {
    static let addFolder = Notification.Name("FindIt.addFolder")
    static let manageFolder = Notification.Name("FindIt.manageFolder")
    static let focusSearch = Notification.Name("FindIt.focusSearch")
    static let exportToNLE = Notification.Name("FindIt.exportToNLE")
}
