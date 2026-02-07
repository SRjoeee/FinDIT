import SwiftUI
import AppKit
import FindItCore

// MARK: - 侧边栏选择模型

/// 侧边栏选择状态
///
/// 用于 `List(selection:)` 绑定，决定搜索的文件夹范围。
enum SidebarSelection: Hashable {
    /// 搜索全部文件夹
    case all
    /// 搜索指定文件夹
    case folder(String)
}

// MARK: - 文件夹分组

/// 按卷分组的文件夹集合
private struct FolderGroup: Identifiable {
    let id: String
    let displayName: String
    let folders: [WatchedFolder]
}

// MARK: - SidebarView

/// 侧边栏 — 文件夹管理
///
/// 显示已注册的素材文件夹列表，按卷自动分组。
/// 支持点击选择文件夹以筛选搜索范围。
/// 每个文件夹显示在线/离线状态、视频/片段统计。
struct SidebarView: View {
    let appState: AppState
    let indexingManager: IndexingManager
    @Binding var selection: SidebarSelection

    /// 待移除的文件夹（触发确认弹窗）
    @State private var folderToRemove: WatchedFolder?

    var body: some View {
        List(selection: $selection) {
            // "全部素材" 固定行
            AllFoldersRow(
                totalVideos: appState.folders.reduce(0) { $0 + $1.totalFiles },
                totalClips: appState.folders.reduce(0) { $0 + $1.indexedFiles }
            )
            .tag(SidebarSelection.all)

            // 按卷分组
            ForEach(folderGroups) { group in
                Section(group.displayName) {
                    ForEach(group.folders, id: \.folderPath) { folder in
                        let isCurrentFolder = indexingManager.currentFolder == folder.folderPath
                        FolderRow(
                            folder: folder,
                            progress: indexingManager.folderProgress[folder.folderPath],
                            isCurrentFolder: isCurrentFolder
                        )
                        .tag(SidebarSelection.folder(folder.folderPath))
                        .contextMenu {
                            Button("在 Finder 中显示") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.folderPath)
                            }
                            .disabled(!folder.isAvailable)

                            Button("重新索引") {
                                indexingManager.queueFolder(folder.folderPath)
                            }
                            .disabled(isCurrentFolder || !folder.isAvailable)

                            Divider()

                            Button("从资料库中移除…", role: .destructive) {
                                folderToRemove = folder
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .alert("移除文件夹？", isPresented: Binding(
            get: { folderToRemove != nil },
            set: { if !$0 { folderToRemove = nil } }
        )) {
            Button("取消", role: .cancel) { folderToRemove = nil }
            Button("移除", role: .destructive) { performRemove() }
        } message: {
            if let folder = folderToRemove {
                let name = URL(fileURLWithPath: folder.folderPath).lastPathComponent
                Text("将清除「\(name)」的索引数据（\(folder.indexedFiles) 个片段）。视频文件不受影响。")
            }
        }
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
    }

    // MARK: - Actions

    /// 执行文件夹移除
    private func performRemove() {
        guard let folder = folderToRemove else { return }
        let removedPath = folder.folderPath

        do {
            try appState.removeFolder(path: removedPath)
        } catch {
            print("[SidebarView] 移除文件夹失败: \(error)")
        }

        // 如果移除的是当前选中项，切回 "全部"
        if case .folder(let path) = selection, path == removedPath {
            selection = .all
        }

        folderToRemove = nil
    }

    // MARK: - 分组逻辑

    /// 按卷自动分组文件夹
    ///
    /// - 内置硬盘 → "本地"
    /// - 外置卷 → 按 volumeName 或挂载点名称分组
    private var folderGroups: [FolderGroup] {
        let internalFolders = appState.folders.filter { !$0.folderPath.hasPrefix("/Volumes/") }
        let externalFolders = appState.folders.filter { $0.folderPath.hasPrefix("/Volumes/") }

        var groups: [FolderGroup] = []

        if !internalFolders.isEmpty {
            groups.append(FolderGroup(id: "internal", displayName: "本地", folders: internalFolders))
        }

        // 外置卷按卷名分组
        let volumeDict = Dictionary(grouping: externalFolders) { folder -> String in
            folder.volumeName
                ?? URL(fileURLWithPath: folder.folderPath).pathComponents.dropFirst(2).first
                ?? "外置硬盘"
        }

        for (name, folders) in volumeDict.sorted(by: { $0.key < $1.key }) {
            groups.append(FolderGroup(id: "vol-\(name)", displayName: name, folders: folders))
        }

        return groups
    }
}

// MARK: - AllFoldersRow

/// "全部素材" 行 — 侧边栏顶部固定项
private struct AllFoldersRow: View {
    let totalVideos: Int
    let totalClips: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text("全部素材")

                if totalVideos > 0 || totalClips > 0 {
                    Text("\(totalVideos) 个视频 · \(totalClips) 个片段")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
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
                // 文件夹名称
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

    /// 显示名称：文件夹最后一段路径
    private var displayName: String {
        URL(fileURLWithPath: folder.folderPath).lastPathComponent
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
