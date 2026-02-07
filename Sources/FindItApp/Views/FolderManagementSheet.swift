import SwiftUI
import FindItCore

/// 文件夹管理 Sheet
///
/// 通过 ⌘, 或 File 菜单唤起，管理已注册的素材文件夹。
struct FolderManagementSheet: View {
    let appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("素材文件夹")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            // 文件夹列表 或 空状态
            if appState.folders.isEmpty {
                ContentUnavailableView(
                    "尚未添加文件夹",
                    systemImage: "folder.badge.plus",
                    description: Text("⌘O 添加素材文件夹")
                )
            } else {
                List {
                    ForEach(appState.folders, id: \.folderPath) { folder in
                        FolderManagementRow(folder: folder, onRemove: {
                            try? appState.removeFolder(path: folder.folderPath)
                        })
                    }
                }
            }
        }
        .frame(width: 480, height: 360)
    }
}

// MARK: - FolderManagementRow

private struct FolderManagementRow: View {
    let folder: WatchedFolder
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: folder.isAvailable ? "folder.fill" : "folder.badge.questionmark")
                .foregroundStyle(folder.isAvailable ? .blue : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: folder.folderPath).lastPathComponent)
                    .lineLimit(1)
                Text(folder.folderPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}
