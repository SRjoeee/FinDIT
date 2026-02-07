import SwiftUI
import FindItCore

/// 文件夹管理 Sheet
///
/// 通过 ⌘, 或 File 菜单唤起，管理已注册的素材文件夹。
/// 显示每个文件夹的索引状态，支持重新索引和删除。
struct FolderManagementSheet: View {
    let appState: AppState
    let indexingManager: IndexingManager
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
                        FolderManagementRow(
                            folder: folder,
                            progress: indexingManager.folderProgress[folder.folderPath],
                            isCurrentFolder: indexingManager.currentFolder == folder.folderPath,
                            onReindex: {
                                indexingManager.queueFolder(folder.folderPath)
                            },
                            onRemove: {
                                try? appState.removeFolder(path: folder.folderPath)
                            }
                        )
                    }
                }
            }
        }
        .frame(width: 520, height: 360)
    }
}

// MARK: - FolderManagementRow

private struct FolderManagementRow: View {
    let folder: WatchedFolder
    let progress: FolderIndexProgress?
    let isCurrentFolder: Bool
    let onReindex: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: folder.isAvailable ? "folder.fill" : "folder.badge.questionmark")
                .foregroundStyle(folder.isAvailable ? .blue : .orange)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(URL(fileURLWithPath: folder.folderPath).lastPathComponent)
                        .lineLimit(1)

                    // 在线/离线 badge
                    Text(folder.isAvailable ? "在线" : "离线")
                        .font(.caption2)
                        .foregroundStyle(folder.isAvailable ? .green : .orange)
                }

                HStack(spacing: 4) {
                    Text(folder.folderPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                // 统计信息
                if folder.totalFiles > 0 || folder.indexedFiles > 0 {
                    Text("\(folder.totalFiles) 个视频 · \(folder.indexedFiles) 个片段")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // 索引状态行
                if let progress = progress {
                    indexingStatusLabel(progress)
                }
            }

            Spacer()

            // 操作按钮
            HStack(spacing: 8) {
                // 重新索引按钮（仅非索引中时显示）
                if !isCurrentFolder {
                    Button {
                        onReindex()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("重新索引")
                }

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

    @ViewBuilder
    private func indexingStatusLabel(_ progress: FolderIndexProgress) -> some View {
        HStack(spacing: 4) {
            if isCurrentFolder {
                ProgressView()
                    .controlSize(.mini)
                Text("索引中 \(progress.completedVideos + progress.failedVideos)/\(progress.totalVideos)")
            } else if progress.isComplete {
                if progress.failedVideos > 0 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(progress.completedVideos) 完成, \(progress.failedVideos) 失败")
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("索引完成")
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}
