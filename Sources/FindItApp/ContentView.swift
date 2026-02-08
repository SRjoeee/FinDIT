import SwiftUI
import AppKit
import FindItCore

struct ContentView: View {
    @State private var appState = AppState()
    @State private var searchState = SearchState()
    @State private var indexingManager = IndexingManager()
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var showFolderSheet = false
    @State private var selectedClipId: Int64?
    @State private var qlCoordinator = QuickLookCoordinator()
    @State private var volumeMonitor = VolumeMonitor()
    @State private var fileWatcherManager = FileWatcherManager()
    @State private var columnsPerRow: Int = 3
    @State private var scrollOnSelect = false
    @State private var sidebarSelection: SidebarSelection = .all
    @State private var folderErrorMessage: String?
    @AppStorage("FindIt.showOfflineFiles") private var showOfflineFiles = false

    var body: some View {
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
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .frame(minWidth: 680, minHeight: 460)
        .sheet(isPresented: $showFolderSheet) {
            FolderManagementSheet(appState: appState, indexingManager: indexingManager)
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
        .onChange(of: selectedClipId) {
            // 点击卡片时让搜索框失焦，event monitor 可处理后续键盘事件
            if selectedClipId != nil {
                let window = NSApp.keyWindow
                if window?.firstResponder is NSTextView {
                    window?.makeFirstResponder(nil)
                }
            }
            // QL 面板已打开时，选中变更自动更新预览
            guard let clipId = selectedClipId,
                  let result = visibleResults.first(where: { $0.clipId == clipId }),
                  let path = result.filePath,
                  FileManager.default.fileExists(atPath: path) else { return }
            qlCoordinator.updateIfVisible(url: URL(fileURLWithPath: path))
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
            fileWatcherManager.startWatching()
            searchState.loadFacets()
        }
        .task {
            // 周期性文件夹健康检查（30秒间隔）
            await appState.startPeriodicHealthCheck()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // App 从后台切回时立即检查（用户可能在 Finder 中操作了文件夹）
            appState.checkFolderHealth()
        }
        .onReceive(NotificationCenter.default.publisher(for: .addFolder)) { _ in
            addFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .manageFolder)) { _ in
            showFolderSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateClip)) { notification in
            guard let direction = notification.userInfo?["direction"] as? String else { return }
            handleArrowKey(direction)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleQuickLook)) { _ in
            handleSpaceKey()
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

                if visibleResults.isEmpty {
                    ContentUnavailableView.search(text: searchState.query)
                        .frame(maxHeight: .infinity)
                } else {
                    ResultsGrid(
                        results: visibleResults,
                        resultCount: visibleResults.count,
                        offlineFolders: offlineFolderPaths,
                        globalDB: appState.globalDB,
                        selectedClipId: $selectedClipId,
                        columnsPerRow: $columnsPerRow,
                        scrollOnSelect: $scrollOnSelect
                    )
                }
            }
        }
    }

    // MARK: - Keyboard Actions

    /// 空格键：切换 Quick Look 预览
    private func handleSpaceKey() {
        guard let clipId = selectedClipId,
              let result = visibleResults.first(where: { $0.clipId == clipId }),
              let path = result.filePath,
              FileManager.default.fileExists(atPath: path) else { return }
        qlCoordinator.toggle(url: URL(fileURLWithPath: path))
    }

    /// 方向键：网格导航
    ///
    /// 左/右移动 ±1，上/下按列数跳行。
    /// 无选中时按任意方向键选中第一项。
    private func handleArrowKey(_ direction: String) {
        let results = visibleResults
        guard !results.isEmpty else { return }

        // 无选中 → 选第一项
        guard let currentId = selectedClipId,
              let currentIndex = results.firstIndex(where: { $0.clipId == currentId }) else {
            scrollOnSelect = true
            selectedClipId = results[0].clipId
            return
        }

        let newIndex: Int
        switch direction {
        case "left":
            newIndex = max(0, currentIndex - 1)
        case "right":
            newIndex = min(results.count - 1, currentIndex + 1)
        case "up":
            newIndex = max(0, currentIndex - columnsPerRow)
        case "down":
            newIndex = min(results.count - 1, currentIndex + columnsPerRow)
        default:
            return
        }

        guard newIndex != currentIndex else { return }
        scrollOnSelect = true
        selectedClipId = results[newIndex].clipId
    }

    // MARK: - Helpers

    /// 离线文件夹路径集合
    private var offlineFolderPaths: Set<String> {
        Set(appState.folders.filter { !$0.isAvailable }.map(\.folderPath))
    }

    /// 对用户可见的搜索结果（过滤 + 排序 + 离线过滤）
    private var visibleResults: [SearchEngine.SearchResult] {
        let results = searchState.displayResults
        guard !showOfflineFiles else { return results }
        let offline = offlineFolderPaths
        guard !offline.isEmpty else { return results }
        return results.filter { !offline.contains($0.sourceFolder) }
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
            } catch let error as FolderError {
                folderErrorMessage = error.localizedDescription
            } catch {
                folderErrorMessage = error.localizedDescription
            }
        }
    }
}
