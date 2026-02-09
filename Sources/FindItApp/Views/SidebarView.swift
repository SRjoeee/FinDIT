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
    /// 搜索指定文件夹（已注册的独立文件夹）
    case folder(String)
    /// 子文件夹书签（通过路径前缀过滤搜索结果）
    case subfolder(String)
}

// MARK: - 侧边栏项模型

/// 侧边栏显示项（文件夹或书签）
private struct SidebarItem: Identifiable {
    let id: String
    let path: String
    let displayName: String
    let isBookmark: Bool
    let folder: WatchedFolder?
    let children: [SidebarItem]
}

// MARK: - 文件夹分组

/// 按卷分组的侧边栏项集合
private struct FolderGroup: Identifiable {
    let id: String
    let displayName: String
    let items: [SidebarItem]
}

// MARK: - SidebarView

/// 侧边栏 — 文件夹管理
///
/// 显示已注册的素材文件夹列表，按卷自动分组。
/// 支持智能嵌套：父子文件夹自动缩进展示。
/// 支持点击选择文件夹以筛选搜索范围。
/// 每个文件夹显示在线/离线状态、视频/片段统计。
struct SidebarView: View {
    let appState: AppState
    let indexingManager: IndexingManager
    @Binding var selection: SidebarSelection

    /// 待移除的文件夹（触发确认弹窗）
    @State private var folderToRemove: WatchedFolder?
    /// 文件夹移除确认弹窗
    @State private var showFolderRemoveAlert = false

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
                    ForEach(group.items) { item in
                        if item.isBookmark {
                            bookmarkRowView(path: item.path, displayName: item.displayName)
                                .padding(.leading, 16)
                        } else if let folder = item.folder {
                            folderRowView(folder)

                            // 子项（注册的子文件夹 + 子文件夹书签，缩进展示）
                            ForEach(item.children) { child in
                                if child.isBookmark {
                                    bookmarkRowView(path: child.path, displayName: child.displayName)
                                        .padding(.leading, 16)
                                } else if let childFolder = child.folder {
                                    folderRowView(childFolder)
                                        .padding(.leading, 16)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .alert("移除文件夹？", isPresented: $showFolderRemoveAlert, presenting: folderToRemove) { folder in
            Button("取消", role: .cancel) { }
            Button("移除", role: .destructive) {
                let removedPath = folder.folderPath
                do {
                    try appState.removeFolder(path: removedPath)
                } catch {
                    print("[SidebarView] 移除文件夹失败: \(error)")
                }
                switch selection {
                case .folder(let path) where path == removedPath:
                    selection = .all
                case .subfolder(let path) where path.hasPrefix(removedPath + "/"):
                    selection = .all
                default:
                    break
                }
            }
        } message: { folder in
            let name = URL(fileURLWithPath: folder.folderPath).lastPathComponent
            Text("将清除「\(name)」的索引数据（\(folder.indexedFiles) 个片段）。视频文件不受影响。")
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

    // MARK: - 共用行渲染

    /// 渲染注册文件夹行 + 上下文菜单（顶级和子级共用，消除重复）
    @ViewBuilder
    private func folderRowView(_ folder: WatchedFolder) -> some View {
        let isCurrent = indexingManager.currentFolder == folder.folderPath
        FolderRow(
            folder: folder,
            progress: indexingManager.folderProgress[folder.folderPath],
            isCurrentFolder: isCurrent
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
            .disabled(isCurrent || !folder.isAvailable)

            Divider()

            Button("从资料库中移除…", role: .destructive) {
                folderToRemove = folder
                showFolderRemoveAlert = true
            }
        }
    }

    /// 渲染子文件夹书签行 + 上下文菜单（顶级和子级共用）
    @ViewBuilder
    private func bookmarkRowView(path: String, displayName: String) -> some View {
        BookmarkRow(displayName: displayName)
            .tag(SidebarSelection.subfolder(path))
            .contextMenu {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                }
                Button("取消钉住") {
                    unpinBookmark(path: path)
                }
            }
    }

    // MARK: - Actions

    /// 直接取消钉住书签（非破坏性操作，无需确认）
    private func unpinBookmark(path: String) {
        appState.removeBookmark(path: path)
        // 如果当前选中的就是这个书签，切回"全部"
        if case .subfolder(let selected) = selection, selected == path {
            selection = .all
        }
    }

    // MARK: - 分组逻辑

    /// 按卷自动分组文件夹，含层级检测
    ///
    /// - 内置硬盘 → "本地"
    /// - 外置卷 → 按 volumeName 或挂载点名称分组
    /// - 子文件夹书签挂载在对应父文件夹下方
    private var folderGroups: [FolderGroup] {
        // 构建 SidebarItem 列表（含子文件夹书签）
        let allItems = buildSidebarItems()

        let internalItems = allItems.filter { !$0.path.hasPrefix("/Volumes/") }
        let externalItems = allItems.filter { $0.path.hasPrefix("/Volumes/") }

        var groups: [FolderGroup] = []

        if !internalItems.isEmpty {
            groups.append(FolderGroup(id: "internal", displayName: "本地", items: internalItems))
        }

        // 外置卷按卷名分组
        let volumeDict = Dictionary(grouping: externalItems) { item -> String in
            if let folder = item.folder {
                return folder.volumeName
                    ?? URL(fileURLWithPath: folder.folderPath).pathComponents.dropFirst(2).first
                    ?? "外置硬盘"
            }
            // 书签（顶级，无父级）→ 从路径推断卷名
            return URL(fileURLWithPath: item.path).pathComponents.dropFirst(2).first ?? "外置硬盘"
        }

        for (name, items) in volumeDict.sorted(by: { $0.key < $1.key }) {
            groups.append(FolderGroup(id: "vol-\(name)", displayName: name, items: items))
        }

        return groups
    }

    /// 构建侧边栏项列表
    ///
    /// 将注册的文件夹和子文件夹书签合并为层级结构。
    /// 注册文件夹之间如果存在父子关系（比如先添加子文件夹再添加父文件夹），
    /// 子文件夹仍然保持为独立项（因为它有自己的数据库和索引数据）。
    private func buildSidebarItems() -> [SidebarItem] {
        let folderPaths = appState.folders.map(\.folderPath)
        let folderMap = Dictionary(uniqueKeysWithValues: appState.folders.map { ($0.folderPath, $0) })
        let bookmarks = appState.subfolderBookmarks

        // 子文件夹书签按父文件夹分组
        var bookmarksByParent: [String: [String]] = [:]
        for bm in bookmarks {
            if let parent = FolderHierarchy.findParent(of: bm, in: folderPaths) {
                bookmarksByParent[parent, default: []].append(bm)
            }
        }

        // 检测注册文件夹间的父子关系
        var childFolderPaths = Set<String>()
        for path in folderPaths {
            if FolderHierarchy.findParent(of: path, in: folderPaths) != nil {
                childFolderPaths.insert(path)
            }
        }

        var items: [SidebarItem] = []

        for folder in appState.folders {
            let path = folder.folderPath

            // 构建此文件夹下的子项（书签 + 注册的子文件夹）
            var children: [SidebarItem] = []

            // 注册的子文件夹（作为独立项展示在父级下方）
            let registeredChildren = FolderHierarchy.findChildren(of: path, in: folderPaths)
            for childPath in registeredChildren {
                if let childFolder = folderMap[childPath] {
                    children.append(SidebarItem(
                        id: "reg-\(childPath)",
                        path: childPath,
                        displayName: URL(fileURLWithPath: childPath).lastPathComponent,
                        isBookmark: false,
                        folder: childFolder,
                        children: []
                    ))
                }
            }

            // 子文件夹书签
            for bmPath in (bookmarksByParent[path] ?? []).sorted() {
                children.append(SidebarItem(
                    id: "bm-\(bmPath)",
                    path: bmPath,
                    displayName: URL(fileURLWithPath: bmPath).lastPathComponent,
                    isBookmark: true,
                    folder: nil,
                    children: []
                ))
            }

            // 跳过已被识别为其他文件夹子级的注册文件夹（它们在父级的 children 中展示）
            if childFolderPaths.contains(path) {
                continue
            }

            items.append(SidebarItem(
                id: "folder-\(path)",
                path: path,
                displayName: URL(fileURLWithPath: path).lastPathComponent,
                isBookmark: false,
                folder: folder,
                children: children
            ))
        }

        return items
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

// MARK: - BookmarkRow

/// 子文件夹书签行
private struct BookmarkRow: View {
    let displayName: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.plus")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(displayName)
                .lineLimit(1)
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
                // 文件夹名称（离线时降低对比度）
                Text(displayName)
                    .lineLimit(1)
                    .foregroundStyle(folder.isAvailable ? .primary : .secondary)

                if folder.isAvailable {
                    // 在线：索引进度或统计
                    if let progress = progress {
                        indexingStatusText(progress)
                    } else {
                        statsText
                    }
                } else {
                    // 离线：显示原因
                    Text(unavailabilityReason)
                        .font(.caption2)
                        .foregroundStyle(.orange)

                    if let lastSeen = folder.lastSeenAt {
                        lastSeenText(lastSeen)
                    }
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

    /// 离线原因描述（区分卷断开 vs 文件夹删除）
    private var unavailabilityReason: String {
        let path = folder.folderPath
        // 外置卷路径: /Volumes/<VolumeName>/...
        if path.hasPrefix("/Volumes/") {
            let components = path.split(separator: "/", maxSplits: 3)
            if components.count >= 2 {
                let volumeMountPoint = "/\(components[0])/\(components[1])"
                if !FileManager.default.fileExists(atPath: volumeMountPoint) {
                    return "卷已断开"
                }
            }
        }
        return "文件夹不存在"
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
            let base = "索引中 \(progress.completedVideos + progress.failedVideos)/\(progress.totalVideos)"
            if progress.sttSkippedNoAudioVideos > 0 {
                Text("\(base) · \(progress.sttSkippedNoAudioVideos) 无音轨")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(base)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if progress.isComplete {
            if progress.failedVideos > 0 {
                Text("\(progress.completedVideos) 完成, \(progress.failedVideos) 失败")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if progress.sttSkippedNoAudioVideos > 0 {
                Text("索引完成 · \(progress.sttSkippedNoAudioVideos) 无音轨")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
