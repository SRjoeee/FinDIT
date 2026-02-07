import SwiftUI
import AppKit

struct ContentView: View {
    @State private var appState = AppState()
    @State private var searchState = SearchState()
    @State private var indexingManager = IndexingManager()
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var showFolderSheet = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(appState: appState, indexingManager: indexingManager)
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
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background {
            VisualEffectBackground()
                .ignoresSafeArea()
        }
        .frame(minWidth: 680, minHeight: 460)
        .sheet(isPresented: $showFolderSheet) {
            FolderManagementSheet(appState: appState, indexingManager: indexingManager)
        }
        .task {
            searchState.appState = appState
            indexingManager.appState = appState
            appState.indexingManager = indexingManager
            await appState.initialize()
        }
        .onReceive(NotificationCenter.default.publisher(for: .addFolder)) { _ in
            addFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .manageFolder)) { _ in
            showFolderSheet = true
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
            ResultsGrid(results: searchState.results, resultCount: searchState.resultCount)
        }
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
            } catch {
                print("添加文件夹失败: \(error)")
            }
        }
    }
}
