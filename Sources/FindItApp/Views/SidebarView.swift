import SwiftUI
import FindItCore

/// 侧边栏 — 文件夹管理
///
/// 显示已注册的素材文件夹列表，支持添加新文件夹。
struct SidebarView: View {
    let appState: AppState

    var body: some View {
        List {
            Section("素材库") {
                ForEach(appState.folders, id: \.folderPath) { folder in
                    FolderRow(folder: folder)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                NotificationCenter.default.post(name: .addFolder, object: nil)
            } label: {
                Label("添加文件夹", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding()
        }
        // 宽度由 ContentView 的 .navigationSplitViewColumnWidth 控制
    }
}

// MARK: - FolderRow

private struct FolderRow: View {
    let folder: WatchedFolder

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: folder.isAvailable ? "folder.fill" : "folder.badge.questionmark")
                .foregroundStyle(folder.isAvailable ? .blue : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .lineLimit(1)

                if folder.totalFiles > 0 || folder.indexedFiles > 0 {
                    Text("\(folder.totalFiles) 个视频")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var displayName: String {
        URL(fileURLWithPath: folder.folderPath).lastPathComponent
    }
}
