import SwiftUI
import FindItCore

/// 侧边栏 — 文件夹管理
///
/// 显示已注册的素材文件夹列表，支持添加新文件夹。
/// 每个文件夹显示在线/离线状态、视频/片段统计。
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
            // 在线/离线状态圆点
            Circle()
                .fill(folder.isAvailable ? .green : .red)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 2) {
                // 文件夹名称（外接卷显示卷名前缀）
                Text(displayName)
                    .lineLimit(1)

                // 索引进度 或 统计文本
                if let progress = progress {
                    indexingStatusText(progress)
                } else {
                    statsText
                }

                // 离线时显示 "上次在线" 时间
                if !folder.isAvailable, let lastSeen = folder.lastSeenAt {
                    lastSeenText(lastSeen)
                }
            }

            Spacer()

            // 右侧状态指示
            statusIndicator
        }
    }

    // MARK: - 显示名称

    /// 显示名称：外接卷加卷名前缀
    private var displayName: String {
        let folderName = URL(fileURLWithPath: folder.folderPath).lastPathComponent

        // 有卷名 + 路径在 /Volumes/ 下 = 外接卷，加前缀
        if let volumeName = folder.volumeName,
           folder.folderPath.hasPrefix("/Volumes/") {
            return "\(volumeName) /\(folderName)"
        }
        return folderName
    }

    // MARK: - 统计文本

    @ViewBuilder
    private var statsText: some View {
        if folder.totalFiles > 0 || folder.indexedFiles > 0 {
            Text("\(folder.totalFiles) 个视频 · \(folder.indexedFiles) 个片段")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - "上次在线" 文本

    @ViewBuilder
    private func lastSeenText(_ dateString: String) -> some View {
        if let date = Self.parseDate(dateString) {
            Text("上次在线：\(date, format: .relative(presentation: .named))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static func parseDate(_ string: String) -> Date? {
        dateFormatter.date(from: string)
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
                // 索引完成后显示统计
                statsText
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
