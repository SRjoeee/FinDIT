import Foundation
import FindItCore
import GRDB

/// 文件变更事件管理器
///
/// 将 FileSystemWatcher（Core 层 FSEvents 封装）接入 App 层。
/// 参照 VolumeMonitor 模式：独立 `@Observable @MainActor` 类。
///
/// 职责:
/// - 管理 FileSystemWatcher 的 watch/unwatch 生命周期
/// - 将 FSEvents 事件路由到 IndexingManager（添加/修改）或 VideoManager（删除）
/// - 索引冲突避免：当 IndexingManager 正在全量处理某文件夹时，延迟该文件夹的事件
@Observable
@MainActor
final class FileWatcherManager {

    /// 是否正在监控
    private(set) var isWatching = false

    /// AppState 引用
    weak var appState: AppState?

    /// IndexingManager 引用
    weak var indexingManager: IndexingManager?

    /// SearchState 引用（用于 VectorStore 失效通知）
    weak var searchState: SearchState?

    // MARK: - 私有状态

    /// Core 层 FSEvents 监控器
    private var watcher: FileSystemWatcher?

    /// 正在全量索引中的文件夹（事件延迟处理）
    private var indexingFolders: Set<String> = []

    /// 延迟事件缓存（folderPath → events）
    private var deferredEvents: [String: [FileChangeEvent]] = [:]

    /// 待处理事件队列（保持回调顺序）
    private var pendingEvents: [FileChangeEvent] = []

    /// 串行 drain Task（同一时间仅允许一个）
    private var eventDrainTask: Task<Void, Never>?

    // MARK: - 生命周期

    /// 启动监控所有已注册且在线的文件夹
    func startWatching() {
        guard !isWatching else { return }

        let watcher = FileSystemWatcher(latency: 1.5, callbackQueue: .main) { [weak self] events in
            self?.enqueueEvents(events)
        }
        self.watcher = watcher

        guard let appState = appState else { return }
        for folder in appState.folders where folder.isAvailable {
            watcher.watch(folder.folderPath)
        }

        isWatching = true
        print("[FileWatcherManager] 开始监控 \(appState.folders.filter(\.isAvailable).count) 个文件夹")
    }

    /// 添加文件夹时开始监控
    func watchFolder(_ path: String) {
        watcher?.watch(path)
    }

    /// 移除文件夹时停止监控
    func unwatchFolder(_ path: String) {
        watcher?.unwatch(path)
        deferredEvents.removeValue(forKey: path)
        indexingFolders.remove(path)
        pendingEvents.removeAll { $0.folderPath == path }
    }

    /// 停止所有监控
    func stopWatching() {
        eventDrainTask?.cancel()
        eventDrainTask = nil
        watcher?.stopAll()
        watcher = nil
        isWatching = false
        deferredEvents.removeAll()
        indexingFolders.removeAll()
        pendingEvents.removeAll()
        print("[FileWatcherManager] 停止监控")
    }

    // MARK: - 索引冲突信号

    /// IndexingManager 开始全量处理某文件夹时调用
    ///
    /// 后续该文件夹的 FSEvents 事件将被延迟到索引完成后再处理。
    func folderIndexingStarted(_ folderPath: String) {
        indexingFolders.insert(folderPath)
    }

    /// IndexingManager 完成全量处理某文件夹时调用
    ///
    /// 处理延迟期间积累的事件。
    func folderIndexingFinished(_ folderPath: String) {
        indexingFolders.remove(folderPath)

        if let deferred = deferredEvents.removeValue(forKey: folderPath), !deferred.isEmpty {
            let deduplicated = FileSystemWatcher.deduplicateEvents(deferred)
            enqueueEvents(deduplicated)
        }
    }

    // MARK: - 事件处理

    /// 入队一批 FSEvents，并确保按回调顺序串行处理。
    ///
    /// 之前每个回调都创建独立 Task，遇到 `await` 挂起后可能交错执行，
    /// 导致删除/新增顺序反转。这里改为单 drain task，保证事件时序稳定。
    private func enqueueEvents(_ events: [FileChangeEvent]) {
        guard !events.isEmpty else { return }
        pendingEvents.append(contentsOf: events)

        guard eventDrainTask == nil else { return }

        eventDrainTask = Task { @MainActor [weak self] in
            await self?.drainEventQueue()
        }
    }

    private func drainEventQueue() async {
        defer { eventDrainTask = nil }

        while !pendingEvents.isEmpty {
            guard !Task.isCancelled else {
                pendingEvents.removeAll()
                return
            }

            let batch = FileSystemWatcher.deduplicateEvents(pendingEvents)
            pendingEvents.removeAll(keepingCapacity: true)
            await handleEvents(batch)
        }
    }

    /// 在后台队列执行阻塞 I/O，避免占用 MainActor
    private func runBlockingIO<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 处理一批文件变更事件（FileSystemWatcher 回调入口）
    private func handleEvents(_ events: [FileChangeEvent]) async {
        guard isWatching else { return }

        // 按文件夹分组
        var grouped: [String: [FileChangeEvent]] = [:]
        for event in events {
            grouped[event.folderPath, default: []].append(event)
        }

        for (folderPath, folderEvents) in grouped {
            // 正在全量索引的文件夹 → 延迟
            if indexingFolders.contains(folderPath) {
                deferredEvents[folderPath, default: []].append(contentsOf: folderEvents)
                print("[FileWatcherManager] 延迟 \(folderEvents.count) 个事件 (文件夹索引中): \(folderPath)")
                continue
            }

            // rescanNeeded 优先处理（整个文件夹重扫）
            if folderEvents.contains(where: { $0.kind == .rescanNeeded }) {
                print("[FileWatcherManager] 需要全量重扫: \(folderPath)")
                indexingManager?.queueFolder(folderPath)
                continue
            }

            await processEvents(folderEvents, folderPath: folderPath)
        }
    }

    /// 处理单个文件夹的事件列表
    private func processEvents(_ events: [FileChangeEvent], folderPath: String) async {
        guard let appState = appState else { return }
        guard let globalDB = appState.globalDB else { return }

        let folderDB: DatabasePool
        do {
            folderDB = try await runBlockingIO {
                try DatabaseManager.openFolderDatabase(at: folderPath)
            }
        } catch {
            print("[FileWatcherManager] 无法打开文件夹数据库: \(error)")
            return
        }

        var addedPaths: [String] = []
        var removedPaths: [String] = []
        var modifiedPaths: [String] = []

        for event in events {
            switch event.kind {
            case .added:
                addedPaths.append(event.path)
            case .removed:
                removedPaths.append(event.path)
            case .modified:
                modifiedPaths.append(event.path)
            case .rescanNeeded:
                break // 已在 handleEvents 中处理
            }
        }

        // 删除处理（同步，立即生效）
        if !removedPaths.isEmpty {
            await handleRemovals(removedPaths, folderPath: folderPath, folderDB: folderDB, globalDB: globalDB)
        }

        // 添加 + 修改 → 统一加入增量索引队列
        // PipelineManager.processVideo 内部 3 层 skip 检测会处理：
        // - 新文件：正常索引
        // - 修改文件：size/mtime 变 → hash 比对 → 决定是否重新索引
        // - 未实际变化的文件：快速跳过
        let toIndex = addedPaths + modifiedPaths
        if !toIndex.isEmpty {
            print("[FileWatcherManager] 加入索引队列: \(toIndex.count) 个视频 in \(folderPath)")
            indexingManager?.queueVideos(toIndex, folderPath: folderPath)
        }
    }

    /// 处理文件删除（软删除 / 硬删除）
    private func handleRemovals(
        _ paths: [String],
        folderPath: String,
        folderDB: DatabasePool,
        globalDB: DatabasePool
    ) async {
        let retentionDays = IndexingOptions.load().orphanedRetentionDays
        do {
            if retentionDays > 0 {
                // 软删除：标记 orphaned，保留索引数据
                let result = try await runBlockingIO {
                    try OrphanRecovery.markOrphanedBatch(
                        videoPaths: paths,
                        folderPath: folderPath,
                        folderDB: folderDB,
                        globalDB: globalDB
                    )
                }
                if result.markedCount > 0 {
                    try? appState?.reloadFolders()
                    searchState?.invalidateVectorStore()
                    print("[FileWatcherManager] 软删除 \(result.markedCount) 个视频 from \(folderPath)")
                }
            } else {
                // 硬删除：立即清除所有数据
                let count = try await runBlockingIO {
                    try VideoManager.removeVideos(
                        videoPaths: paths,
                        folderPath: folderPath,
                        folderDB: folderDB,
                        globalDB: globalDB
                    )
                }
                if count > 0 {
                    try? appState?.reloadFolders()
                    searchState?.invalidateVectorStore()
                    print("[FileWatcherManager] 硬删除 \(count) 个视频 from \(folderPath)")
                }
            }
        } catch {
            print("[FileWatcherManager] 删除处理失败: \(error)")
        }
    }
}
