import SwiftUI
import FindItCore

/// 侧边栏 — 文件夹管理
///
/// 显示已注册的素材文件夹列表，支持添加新文件夹。
/// 索引进行中时显示进度指示器。
struct SidebarView: View {
    let appState: AppState
    let indexingManager: IndexingManager

    var body: some View {
        List {
            Section("素材库") {
                ForEach(appState.folders, id: \.folderPath) { folder in
                    FolderRow(
                        folder: folder,
                        progress: indexingManager.folderProgress[folder.folderPath],
                        isCurrentFolder: indexingManager.currentFolder == folder.folderPath
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    NotificationCenter.default.post(name: .addFolder, object: nil)
                } label: {
                    Label("添加文件夹", systemImage: "plus")
                }
                .buttonStyle(.plain)

                Spacer()

                IndexingProgressRing(indexingManager: indexingManager)
            }
            .padding()
        }
        // 宽度由 ContentView 的 .navigationSplitViewColumnWidth 控制
    }
}

// MARK: - FolderRow

private struct FolderRow: View {
    let folder: WatchedFolder
    let progress: FolderIndexProgress?
    let isCurrentFolder: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: folderIcon)
                .foregroundStyle(folderColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .lineLimit(1)

                // 索引进度或文件计数
                if let progress = progress {
                    indexingStatusText(progress)
                } else if folder.totalFiles > 0 || folder.indexedFiles > 0 {
                    Text("\(folder.totalFiles) 个视频")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // 右侧状态指示
            statusIndicator
        }
    }

    private var displayName: String {
        URL(fileURLWithPath: folder.folderPath).lastPathComponent
    }

    // MARK: - 图标与颜色

    private var folderIcon: String {
        if !folder.isAvailable { return "folder.badge.questionmark" }
        return "folder.fill"
    }

    private var folderColor: Color {
        if !folder.isAvailable { return .orange }
        return .blue
    }

    // MARK: - 索引状态文本

    @ViewBuilder
    private func indexingStatusText(_ progress: FolderIndexProgress) -> some View {
        if isCurrentFolder {
            Text("索引中 \(progress.completedVideos + progress.failedVideos)/\(progress.totalVideos)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if progress.isComplete {
            if progress.failedVideos > 0 {
                Text("\(progress.completedVideos) 完成, \(progress.failedVideos) 失败")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                Text("\(progress.totalVideos) 个视频")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("等待索引...")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 右侧状态指示器

    @ViewBuilder
    private var statusIndicator: some View {
        if isCurrentFolder {
            ProgressView()
                .controlSize(.mini)
        } else if let progress = progress {
            if progress.isComplete && progress.failedVideos == 0 {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else if progress.failedVideos > 0 {
                Text("\(progress.failedVideos)")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.orange, in: Capsule())
            }
        }
    }
}
