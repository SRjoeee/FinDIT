import SwiftUI
import AppKit
import FindItCore

/// sheet(item:) 驱动导出的载荷
struct ExportPayload: Identifiable {
    let id = UUID()
    let clips: [SearchEngine.SearchResult]
}

struct ContentView: View {
    @State private var appState = AppState()
    @State private var searchState = SearchState()
    @State private var indexingManager = IndexingManager()
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var showFolderSheet = false
    @State private var selectionManager = SelectionManager()
    @State private var qlCoordinator = QuickLookCoordinator()
    @State private var volumeMonitor = VolumeMonitor()
    @State private var fileWatcherManager = FileWatcherManager()
    @State private var sidebarSelection: SidebarSelection = .all
    @State private var folderErrorMessage: String?
    @State private var exportPayload: ExportPayload?
    @State private var showEnhanceAlert = false
    @AppStorage("FindIt.showOfflineFiles") private var showOfflineFiles = false

    var body: some View {
        mainContent
            .onReceive(NotificationCenter.default.publisher(for: .addFolder)) { _ in
                addFolder()
            }
            .onReceive(NotificationCenter.default.publisher(for: .manageFolder)) { _ in
                showFolderSheet = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportToNLE)) { notification in
                if let clips = notification.userInfo?["clips"] as? [SearchEngine.SearchResult], !clips.isEmpty {
                    exportPayload = ExportPayload(clips: clips)
                } else if !selectionManager.selectedResults.isEmpty {
                    exportPayload = ExportPayload(clips: selectionManager.selectedResults)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .srtVisibilityChanged)) { notification in
                guard let hidden = notification.userInfo?["hidden"] as? Bool else { return }
                let folderPaths = appState.folders.map(\.folderPath)
                Task.detached(priority: .utility) {
                    let result = await SRTVisibilityManager.batchSetVisibility(
                        hidden: hidden,
                        folderPaths: folderPaths
                    )
                    if result.processed > 0 || result.failed > 0 {
                        print("[SRT] 批量\(hidden ? "隐藏" : "显示"): 成功 \(result.processed), 失败 \(result.failed)")
                    }
                }
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
                    exportPayload = ExportPayload(clips: selectionManager.selectedResults)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("导出到 NLE (⇧⌘E)")
                .disabled(selectionManager.selectedClipIds.isEmpty)
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .frame(minWidth: 680, minHeight: 460)
        .sheet(isPresented: $showFolderSheet) {
            FolderManagementSheet(appState: appState, indexingManager: indexingManager)
        }
        .sheet(item: $exportPayload) { payload in
            ExportSheet(clips: payload.clips)
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
        .alert("可升级视觉描述", isPresented: $showEnhanceAlert) {
            Button("升级") {
                indexingManager.enhanceUpgradeableClips()
            }
            Button("稍后", role: .cancel) { }
        } message: {
            Text("发现 \(indexingManager.upgradeableVideoCount) 个视频使用本地分析，可升级为云端 AI 描述以提升搜索质量。")
        }
        .onChange(of: selectionManager.focusedClipId) {
            selectionManager.updatePreviewIfNeeded()
        }
        .onChange(of: searchState.query) {
            selectionManager.clearSelection()
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
            selectionManager.searchState = searchState
            selectionManager.qlCoordinator = qlCoordinator
            qlCoordinator.selectionManager = selectionManager
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
            // 检查可升级的视觉描述（延迟 5 秒，等初始化完成）
            Task(priority: .utility) {
                try? await Task.sleep(for: .seconds(5))
                let options = IndexingOptions.load()
                let hasApiKey = (try? APIKeyManager.resolveAPIKey()) != nil
                if hasApiKey && !options.skipVision {
                    await indexingManager.checkUpgradeableClips()
                    if indexingManager.upgradeableVideoCount > 0 {
                        showEnhanceAlert = true
                    }
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
                        selectionManager: selectionManager
                    )
                }
            }
        }
    }

    // MARK: - Helpers

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
