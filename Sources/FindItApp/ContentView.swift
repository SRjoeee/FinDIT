import SwiftUI
import AppKit
import FindItCore

struct ContentView: View {
    @State private var appState = AppState()
    @State private var searchState = SearchState()
    @State private var indexingManager = IndexingManager()
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var showFolderSheet = false
    @State private var selectedClipIds: Set<Int64> = []
    @State private var focusedClipId: Int64?
    @State private var selectionAnchorId: Int64?
    @State private var qlCoordinator = QuickLookCoordinator()
    @State private var volumeMonitor = VolumeMonitor()
    @State private var fileWatcherManager = FileWatcherManager()
    @State private var columnsPerRow: Int = 3
    @State private var scrollOnSelect = false
    @State private var sidebarSelection: SidebarSelection = .all
    @State private var folderErrorMessage: String?
    @State private var showExportSheet = false
    @State private var exportClips: [SearchEngine.SearchResult] = []
    @AppStorage("FindIt.showOfflineFiles") private var showOfflineFiles = false

    var body: some View {
        mainContent
            .onReceive(NotificationCenter.default.publisher(for: .addFolder)) { _ in
                addFolder()
            }
            .onReceive(NotificationCenter.default.publisher(for: .manageFolder)) { _ in
                showFolderSheet = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateClip)) { notification in
                guard let direction = notification.userInfo?["direction"] as? NavigationDirection else { return }
                let modifiers = notification.userInfo?["modifiers"] as? NSEvent.ModifierFlags ?? []
                handleArrowKey(direction, modifiers: modifiers)
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleQuickLook)) { _ in
                handleSpaceKey()
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectAllClips)) { _ in
                handleSelectAll()
            }
            .onReceive(NotificationCenter.default.publisher(for: .deselectAllClips)) { _ in
                handleDeselectAll()
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportToNLE)) { notification in
                if let clips = notification.userInfo?["clips"] as? [SearchEngine.SearchResult], !clips.isEmpty {
                    exportClips = clips
                } else if !selectedResults.isEmpty {
                    exportClips = selectedResults
                } else {
                    return
                }
                showExportSheet = true
            }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                appState: appState,
                indexingManager: indexingManager,
                selection: $sidebarSelection
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 240)
        } detail: {
            detailContent
        }
        .environment(searchState)
        .navigationSplitViewStyle(.prominentDetail)
        .transaction { $0.disablesAnimations = true }
        .toolbar {
            ToolbarItem(placement: .principal) {
                NativeSearchField(
                    text: $searchState.query,
                    prompt: "搜索素材...",
                    onSubmit: { searchState.recordCurrentSearch() }
                )
                .frame(minWidth: 160, maxWidth: 320)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    exportClips = selectedResults
                    showExportSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("导出到 NLE (⇧⌘E)")
                .disabled(selectedClipIds.isEmpty)
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .frame(minWidth: 680, minHeight: 460)
        .sheet(isPresented: $showFolderSheet) {
            FolderManagementSheet(appState: appState, indexingManager: indexingManager)
        }
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(clips: exportClips)
        }
        .alert("无法添加文件夹", isPresented: Binding(
            get: { folderErrorMessage != nil },
            set: { if !$0 { folderErrorMessage = nil } }
        )) {
            Button("好") { folderErrorMessage = nil }
        } message: {
            if let msg = folderErrorMessage {
                Text(msg)
            }
        }
        .onChange(of: focusedClipId) {
            // 点击卡片时让搜索框失焦，event monitor 可处理后续键盘事件
            if focusedClipId != nil {
                let window = NSApp.keyWindow
                if window?.firstResponder is NSTextView {
                    window?.makeFirstResponder(nil)
                }
            }
            // QL 面板已打开时，焦点变更自动更新预览
            guard let clipId = focusedClipId,
                  let result = searchState.visibleResults.first(where: { $0.clipId == clipId }),
                  let path = result.filePath,
                  FileManager.default.fileExists(atPath: path) else { return }
            qlCoordinator.updateIfVisible(url: URL(fileURLWithPath: path))
        }
        .onChange(of: searchState.query) {
            // 搜索词变更时清空选中
            selectedClipIds = []
            focusedClipId = nil
            selectionAnchorId = nil
        }
        .onChange(of: sidebarSelection) {
            switch sidebarSelection {
            case .all:
                searchState.folderFilter = nil
                searchState.pathPrefixFilter = nil
            case .folder(let path):
                // 选择父文件夹时，自动包含所有已注册的子文件夹
                let allPaths = appState.folders.map(\.folderPath)
                let children = FolderHierarchy.findChildren(of: path, in: allPaths)
                var filterSet: Set<String> = [path]
                for child in children {
                    filterSet.insert(child)
                }
                searchState.folderFilter = filterSet
                searchState.pathPrefixFilter = nil
            case .subfolder(let path):
                // 子文件夹书签：通过路径前缀过滤
                searchState.folderFilter = nil
                searchState.pathPrefixFilter = path
            }
        }
        .task {
            qlCoordinator.startMonitoring()
            searchState.appState = appState
            indexingManager.appState = appState
            indexingManager.searchState = searchState
            appState.indexingManager = indexingManager
            volumeMonitor.appState = appState
            volumeMonitor.indexingManager = indexingManager
            volumeMonitor.startMonitoring()
            fileWatcherManager.appState = appState
            fileWatcherManager.indexingManager = indexingManager
            fileWatcherManager.searchState = searchState
            indexingManager.fileWatcherManager = fileWatcherManager
            appState.fileWatcherManager = fileWatcherManager
            NotificationManager.requestPermission()
            await appState.initialize()
            // 初始化向量索引管理器（需要 globalDB 已就绪）
            if let db = appState.globalDB {
                searchState.vectorIndexManager = VectorIndexManager(globalDB: db)
                searchState.prewarm()
            }
            // 启动时主动对账卷路径重定向（处理"卷已挂载但无出现事件"的场景）。
            volumeMonitor.reconcilePathsAtStartup()
            fileWatcherManager.startWatching()
            // 启动后自动恢复可达文件夹的索引任务（含 pending/failed/orphan 恢复路径）。
            indexingManager.indexPendingFolders()
            // 注册夜间自动索引（24h 周期，系统空闲时触发）
            BackgroundIndexScheduler.shared.indexingManager = indexingManager
            BackgroundIndexScheduler.shared.register()
            searchState.loadFacets()
            // 清理过期 orphaned 记录（方法内部已通过 runBlockingIO 下沉阻塞 I/O）
            Task(priority: .utility) {
                let retention = IndexingOptions.load().orphanedRetentionDays
                if retention > 0 {
                    await indexingManager.cleanupOrphanedRecords(retentionDays: retention)
                }
            }
        }
        .task {
            // 同步初始偏好设置
            searchState.showOfflineFiles = showOfflineFiles
            // 周期性文件夹健康检查（30秒间隔）
            await appState.startPeriodicHealthCheck()
        }
        .onChange(of: showOfflineFiles) {
            searchState.showOfflineFiles = showOfflineFiles
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // App 从后台切回时立即检查（用户可能在 Finder 中操作了文件夹）
            appState.checkFolderHealth()
        }
    }

    // MARK: - Detail Content

    @ViewBuilder
    private var detailContent: some View {
        if let error = appState.initError {
            ContentUnavailableView {
                Label("初始化失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
        } else if !appState.isInitialized {
            ProgressView("正在初始化...")
        } else if searchState.query.isEmpty {
            EmptyStateView()
        } else {
            VStack(spacing: 0) {
                // 过滤栏：有搜索结果或有活跃过滤器时显示
                if !searchState.results.isEmpty || searchState.hasActiveFilter {
                    FilterBar(
                        filter: $searchState.activeFilter,
                        facets: searchState.facets
                    )
                }

                let visible = searchState.visibleResults
                if visible.isEmpty {
                    ContentUnavailableView.search(text: searchState.query)
                        .frame(maxHeight: .infinity)
                } else {
                    ResultsGrid(
                        results: visible,
                        resultCount: visible.count,
                        offlineFolders: offlineFolderPaths,
                        globalDB: appState.globalDB,
                        selectedClipIds: $selectedClipIds,
                        focusedClipId: $focusedClipId,
                        selectionAnchorId: $selectionAnchorId,
                        columnsPerRow: $columnsPerRow,
                        scrollOnSelect: $scrollOnSelect
                    )
                }
            }
        }
    }

    // MARK: - Keyboard Actions

    /// 空格键：切换 Quick Look 预览（使用焦点 clip）
    private func handleSpaceKey() {
        guard let clipId = focusedClipId,
              let result = searchState.visibleResults.first(where: { $0.clipId == clipId }),
              let path = result.filePath,
              FileManager.default.fileExists(atPath: path) else { return }
        qlCoordinator.toggle(url: URL(fileURLWithPath: path))
    }

    /// 方向键：网格导航
    ///
    /// 左/右移动 ±1，上/下按列数跳行。
    /// 无选中时按任意方向键选中第一项。
    /// Shift+方向键扩展选中范围。
    private func handleArrowKey(_ direction: NavigationDirection, modifiers: NSEvent.ModifierFlags = []) {
        let results = searchState.visibleResults
        guard !results.isEmpty else { return }

        // 无焦点 → 选第一项
        guard let currentId = focusedClipId,
              let currentIndex = results.firstIndex(where: { $0.clipId == currentId }) else {
            let firstId = results[0].clipId
            scrollOnSelect = true
            focusedClipId = firstId
            selectedClipIds = [firstId]
            selectionAnchorId = firstId
            return
        }

        let newIndex: Int
        switch direction {
        case .left:
            newIndex = max(0, currentIndex - 1)
        case .right:
            newIndex = min(results.count - 1, currentIndex + 1)
        case .up:
            newIndex = max(0, currentIndex - columnsPerRow)
        case .down:
            newIndex = min(results.count - 1, currentIndex + columnsPerRow)
        }

        guard newIndex != currentIndex else { return }
        let newId = results[newIndex].clipId
        scrollOnSelect = true
        focusedClipId = newId

        if modifiers.contains(.shift) {
            // Shift+方向键：扩展选中
            selectedClipIds.insert(newId)
        } else {
            // 普通方向键：单选
            selectedClipIds = [newId]
            selectionAnchorId = newId
        }
    }

    /// ⌘A：全选当前可见结果
    private func handleSelectAll() {
        let results = searchState.visibleResults
        guard !results.isEmpty else { return }
        selectedClipIds = Set(results.map(\.clipId))
        if focusedClipId == nil {
            focusedClipId = results[0].clipId
        }
    }

    /// Escape：清空选中
    private func handleDeselectAll() {
        selectedClipIds = []
        focusedClipId = nil
        selectionAnchorId = nil
    }

    // MARK: - Helpers

    /// 当前选中的搜索结果
    private var selectedResults: [SearchEngine.SearchResult] {
        searchState.visibleResults.filter { selectedClipIds.contains($0.clipId) }
    }

    /// 离线文件夹路径集合
    private var offlineFolderPaths: Set<String> {
        Set(appState.folders.filter { !$0.isAvailable }.map(\.folderPath))
    }

    // MARK: - Actions

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择素材文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                try await appState.addFolder(path: url.path)
                searchState.invalidateVectorStore()
            } catch let error as FolderError {
                folderErrorMessage = error.localizedDescription
            } catch {
                folderErrorMessage = error.localizedDescription
            }
        }
    }
}
