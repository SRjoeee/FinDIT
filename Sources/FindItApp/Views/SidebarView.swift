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
    /// 待移除的书签路径
    @State private var bookmarkToRemove: String?

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
                            // 子文件夹书签行
                            BookmarkRow(displayName: item.displayName)
                                .tag(SidebarSelection.subfolder(item.path))
                                .padding(.leading, 16)
                                .contextMenu {
                                    Button("在 Finder 中显示") {
                                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.path)
                                    }
                                    Button("取消钉住") {
                                        bookmarkToRemove = item.path
                                    }
                                }
                        } else if let folder = item.folder {
                            // 注册的文件夹行
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

                            // 子文件夹书签（缩进展示）
                            ForEach(item.children) { child in
                                BookmarkRow(displayName: child.displayName)
                                    .tag(SidebarSelection.subfolder(child.path))
                                    .padding(.leading, 16)
                                    .contextMenu {
                                        Button("在 Finder 中显示") {
                                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: child.path)
                                        }
                                        Button("取消钉住") {
                                            bookmarkToRemove = child.path
                                        }
                                    }
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
        .alert("取消钉住？", isPresented: Binding(
            get: { bookmarkToRemove != nil },
            set: { if !$0 { bookmarkToRemove = nil } }
        )) {
            Button("取消", role: .cancel) { bookmarkToRemove = nil }
            Button("取消钉住") { performRemoveBookmark() }
        } message: {
            if let path = bookmarkToRemove {
                let name = URL(fileURLWithPath: path).lastPathComponent
                Text("将从侧边栏移除「\(name)」快捷入口。索引数据不受影响。")
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
        switch selection {
        case .folder(let path) where path == removedPath:
            selection = .all
        case .subfolder(let path) where path.hasPrefix(removedPath + "/"):
            selection = .all
        default:
            break
        }

        folderToRemove = nil
    }

    /// 执行书签移除
    private func performRemoveBookmark() {
        guard let path = bookmarkToRemove else { return }
        appState.removeBookmark(path: path)

        if case .subfolder(let selected) = selection, selected == path {
            selection = .all
        }

        bookmarkToRemove = nil
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
