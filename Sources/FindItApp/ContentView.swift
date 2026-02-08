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
    @State private var columnsPerRow: Int = 3
    @State private var scrollOnSelect = false
    @State private var sidebarSelection: SidebarSelection = .all
    @State private var folderErrorMessage: String?

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
        .toolbarBackground(hasScrollableContent ? .automatic : .hidden, for: .windowToolbar)
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
                  let result = searchState.results.first(where: { $0.clipId == clipId }),
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
            NotificationManager.requestPermission()
            await appState.initialize()
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
        } else if searchState.results.isEmpty {
            ContentUnavailableView.search(text: searchState.query)
        } else {
            ResultsGrid(
                results: searchState.results,
                resultCount: searchState.resultCount,
                offlineFolders: offlineFolderPaths,
                selectedClipId: $selectedClipId,
                columnsPerRow: $columnsPerRow,
                scrollOnSelect: $scrollOnSelect
            )
        }
    }

    // MARK: - Keyboard Actions

    /// 空格键：切换 Quick Look 预览
    private func handleSpaceKey() {
        guard let clipId = selectedClipId,
              let result = searchState.results.first(where: { $0.clipId == clipId }),
              let path = result.filePath,
              FileManager.default.fileExists(atPath: path) else { return }
        qlCoordinator.toggle(url: URL(fileURLWithPath: path))
    }

    /// 方向键：网格导航
    ///
    /// 左/右移动 ±1，上/下按列数跳行。
    /// 无选中时按任意方向键选中第一项。
    private func handleArrowKey(_ direction: String) {
        let results = searchState.results
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

    /// detail 区域是否有可滚动的结果内容
    ///
    /// 用于控制 toolbar 背景：有结果时系统自动处理 Liquid Glass + 滚动分隔线，
    /// 无结果时隐藏 toolbar 背景（含分隔线），保持界面干净。
    private var hasScrollableContent: Bool {
        appState.isInitialized && !searchState.query.isEmpty && !searchState.results.isEmpty
    }

    /// 离线文件夹路径集合（用于搜索结果离线蒙层）
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
            } catch let error as FolderError {
                folderErrorMessage = error.localizedDescription
            } catch {
                folderErrorMessage = error.localizedDescription
            }
        }
    }
}
