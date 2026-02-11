import Foundation
import GRDB
import FindItCore

/// 文件夹索引进度
struct FolderIndexProgress {
    /// 视频文件总数
    var totalVideos: Int = 0
    /// 已完成视频数
    var completedVideos: Int = 0
    /// 失败视频数
    var failedVideos: Int = 0
    /// 失败的视频路径 → 错误信息
    var errors: [(path: String, message: String)] = []
    /// 非致命降级（例如无音轨跳过 STT）
    var nonFatalIssues: [(path: String, message: String)] = []
    /// 因无音轨而跳过 STT 的视频数量
    var sttSkippedNoAudioVideos: Int = 0

    /// 进度百分比 (0.0 ~ 1.0)
    var progress: Double {
        guard totalVideos > 0 else { return 0 }
        return Double(completedVideos + failedVideos) / Double(totalVideos)
    }

    /// 是否全部完成
    var isComplete: Bool {
        totalVideos > 0 && (completedVideos + failedVideos) >= totalVideos
    }
}

/// 后台索引编排器
///
/// 管理文件夹的视频索引队列。添加文件夹后自动扫描视频并通过
/// `IndexingScheduler` 并行处理。文件夹间串行、文件夹内视频并行。
///
/// 共享资源（GeminiRateLimiter、EmbeddingProvider）懒初始化并复用。
/// 并发数由 `ResourceMonitor` 根据系统状态动态调整。
///
/// 读取 `IndexingOptions` 控制功能开关和性能模式（Settings 页面配置）。
@Observable
@MainActor
final class IndexingManager {

    // MARK: - 公开状态

    /// 是否正在索引
    var isIndexing: Bool = false

    /// 当前正在索引的文件夹路径
    var currentFolder: String?

    /// 当前正在处理的视频文件名（并行时显示最近上报的）
    var currentVideoName: String?

    /// 当前处理阶段描述
    var currentStage: String?

    /// 各文件夹的索引进度
    var folderProgress: [String: FolderIndexProgress] = [:]

    /// AppState 引用（用于触发文件夹列表刷新）
    weak var appState: AppState?

    /// FileWatcherManager 引用（用于索引冲突信号）
    weak var fileWatcherManager: FileWatcherManager?
    /// SearchState 引用（用于索引后失效 VectorStore）
    weak var searchState: SearchState?

    // MARK: - 私有状态

    /// 待处理文件夹队列（全量扫描）
    private var pendingFolders: [String] = []

    /// 待处理的增量视频队列（folderPath → videoPaths）
    ///
    /// 由 FileWatcherManager 通过 `queueVideos()` 填充，
    /// 文件夹全量扫描优先于增量视频处理。
    private var pendingVideos: [String: [String]] = [:]

    /// 各文件夹的排除子目录集合（智能嵌套：添加父文件夹时排除已索引子文件夹）
    private var folderExclusions: [String: Set<String>] = [:]

    /// 当前处理 Task（用于取消）
    private var processingTask: Task<Void, Never>?

    /// ProcessInfo 后台活动令牌（防止 macOS 节能降速）
    private var backgroundActivity: NSObjectProtocol?

    /// 进度回调节流：上次 MainActor 更新时间
    private var lastProgressUpdate: ContinuousClock.Instant = .now
    /// 进度节流间隔（500ms）
    private let progressThrottleInterval: Duration = .milliseconds(500)

    /// 并行调度器（根据 IndexingOptions.performanceMode 初始化）
    private var scheduler: IndexingScheduler?

    /// 共享 Gemini 限速器
    private var rateLimiter: GeminiRateLimiter?

    /// 共享嵌入 provider
    private var embeddingProvider: (any EmbeddingProvider)?

    /// 已解析的 API Key（nil = 尝试过但没找到）
    private var resolvedAPIKey: String?

    /// 是否已尝试解析 API Key
    private var hasResolvedAPIKey = false

    // MARK: - 公开方法

    /// 添加文件夹到索引队列
    ///
    /// 如果队列未在处理，立即启动。如果正在处理，追加到队列末尾。
    ///
    /// - Parameters:
    ///   - path: 文件夹路径
    ///   - excluding: 要排除的子文件夹集合（智能嵌套时使用）
    func queueFolder(_ path: String, excluding: Set<String> = []) {
        // 避免重复入队
        guard !pendingFolders.contains(path) else { return }
        // 避免正在处理的文件夹重复入队
        guard currentFolder != path else { return }

        pendingFolders.append(path)
        if !excluding.isEmpty {
            folderExclusions[path] = excluding
        }

        // 如果没有正在运行的 task，启动处理
        if processingTask == nil {
            startProcessing()
        }
    }

    /// 添加指定视频文件到增量索引队列
    ///
    /// 与 `queueFolder()` 不同，不触发全量文件夹扫描，
    /// 直接将指定视频路径加入处理队列。
    /// 由 FileWatcherManager 在检测到 .added / .modified 事件时调用。
    ///
    /// - Parameters:
    ///   - videoPaths: 视频文件路径列表
    ///   - folderPath: 所属监控文件夹路径
    func queueVideos(_ videoPaths: [String], folderPath: String) {
        guard !videoPaths.isEmpty else { return }
        pendingVideos[folderPath, default: []].append(contentsOf: videoPaths)

        if processingTask == nil {
            startProcessing()
        }
    }

    /// 取消当前索引
    ///
    /// 取消正在处理的视频，清空待处理队列。
    /// 已完成的视频数据保留在数据库中。
    func cancelIndexing() {
        processingTask?.cancel()
        processingTask = nil
        pendingFolders.removeAll()
        pendingVideos.removeAll()
        // 唤醒可能阻塞在信号量上的等待者
        if let scheduler = scheduler {
            Task { await scheduler.releaseWaiters() }
        }
        endBackgroundActivity()
        isIndexing = false
        currentFolder = nil
        currentVideoName = nil
        currentStage = nil
    }

    /// 恢复未完成的索引
    ///
    /// App 启动时调用。检查已注册文件夹中是否有未完成索引的视频，
    /// 利用 PipelineManager 的断点续传机制恢复处理。
    func indexPendingFolders() {
        guard let appState = appState else { return }

        // 仅恢复当前可达的文件夹；离线卷由 VolumeMonitor 恢复后再入队。
        for folder in appState.folders where folder.isAvailable {
            queueFolder(folder.folderPath)
        }
    }

    /// 清理过期 orphaned 记录
    ///
    /// 遍历所有可用的文件夹数据库，清理超过保留天数的 orphaned 记录。
    /// 应在 App 启动或空闲时调用。
    func cleanupOrphanedRecords(retentionDays: Int) async {
        guard retentionDays > 0, let appState = appState else { return }

        // 在 MainActor 上获取文件夹列表（避免在后台闭包中使用 await）
        let folders = appState.folders

        // 切换到后台线程执行数据库清理，避免阻塞 MainActor
        try? await runBlockingIO {
            for folder in folders where folder.isAvailable {
                if let folderDB = try? DatabaseManager.openFolderDatabase(at: folder.folderPath) {
                    do {
                        let result = try OrphanRecovery.cleanupExpired(
                            retentionDays: retentionDays,
                            folderPath: folder.folderPath,
                            folderDB: folderDB
                        )
                        if result.removedCount > 0 {
                            print("[IndexingManager] 清理 \(result.removedCount) 个过期 orphaned in \(folder.folderPath)")
                        }
                    } catch {
                        print("[IndexingManager] 清理 orphaned 失败: \(folder.folderPath) - \(error)")
                    }
                }
            }
        }
    }

    // MARK: - 私有方法

    /// 在后台队列执行阻塞 I/O，避免占用 MainActor
    ///
    /// IndexingManager 作为 `@MainActor` 状态对象保留 UI 一致性，
    /// 但目录扫描/数据库打开属于阻塞操作，应移到后台执行。
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

    /// 启动队列处理
    private func startProcessing() {
        processingTask = Task { [weak self] in
            guard let self = self else { return }
            await self.processQueue()
        }
    }

    /// 串行处理文件夹队列（全量扫描优先于增量视频）
    private func processQueue() async {
        isIndexing = true

        // 声明后台活动，防止 macOS 在 App 最小化时节能降速
        backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: [.suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "FindIt is indexing video files"
        )

        while !pendingFolders.isEmpty || !pendingVideos.isEmpty {
            guard !Task.isCancelled else { break }

            if !pendingFolders.isEmpty {
                let folderPath = pendingFolders.removeFirst()
                fileWatcherManager?.folderIndexingStarted(folderPath)
                await processFolder(folderPath)
                fileWatcherManager?.folderIndexingFinished(folderPath)
            } else if let (folderPath, videos) = pendingVideos.first {
                pendingVideos.removeValue(forKey: folderPath)
                await processSpecificVideos(videos, in: folderPath)
            }
        }

        // 队列清空，结束后台活动声明
        endBackgroundActivity()
        isIndexing = false
        currentFolder = nil
        currentVideoName = nil
        currentStage = nil
        processingTask = nil
    }

    /// 处理单个文件夹（通过 IndexingScheduler 并行处理视频）
    private func processFolder(_ folderPath: String) async {
        currentFolder = folderPath

        // 扫描视频文件（排除已索引的子文件夹）
        // 这里不能只依赖一次性入队参数，否则后续重扫会丢失排除规则。
        // 每次处理时都根据当前注册文件夹动态计算父子关系，保证一致性。
        let explicitExclusions = folderExclusions.removeValue(forKey: folderPath) ?? []
        let dynamicExclusions: Set<String>
        if let appState = appState {
            let allPaths = appState.folders.map(\.folderPath)
            dynamicExclusions = Set(FolderHierarchy.findChildren(of: folderPath, in: allPaths))
        } else {
            dynamicExclusions = []
        }
        let exclusions = explicitExclusions.union(dynamicExclusions)
        let videoFiles: [String]
        do {
            videoFiles = try await runBlockingIO {
                try FileScanner.scanVideoFiles(in: folderPath, excluding: exclusions)
            }
        } catch {
            print("[IndexingManager] 扫描文件夹失败: \(error)")
            return
        }

        guard !videoFiles.isEmpty else {
            print("[IndexingManager] 文件夹无视频文件: \(folderPath)")
            return
        }

        // 初始化进度
        folderProgress[folderPath] = FolderIndexProgress(totalVideos: videoFiles.count)

        // 打开文件夹级数据库
        let folderDB: DatabasePool
        do {
            folderDB = try await runBlockingIO {
                try DatabaseManager.openFolderDatabase(at: folderPath)
            }
        } catch {
            print("[IndexingManager] 打开文件夹数据库失败: \(error)")
            return
        }

        // 读取索引选项（每个文件夹处理前读一次，反映最新设置）
        let options = IndexingOptions.load()

        // 懒初始化共享资源
        initSharedResources(options: options)

        let globalDB = appState?.globalDB

        // 根据 skip 标志决定传递什么参数
        let effectiveAPIKey = options.skipVision ? nil : resolvedAPIKey
        let effectiveEmbeddingProvider = options.skipEmbedding ? nil : embeddingProvider

        print("[IndexingManager] 开始并行索引: \(videoFiles.count) 个视频 (模式: \(options.performanceMode.displayName))")

        // 确保 scheduler 存在
        let currentScheduler = ensureScheduler(mode: options.performanceMode)

        // 通过调度器并行处理视频
        let syncResult = await currentScheduler.processVideos(
            videoFiles,
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB,
            apiKey: effectiveAPIKey,
            rateLimiter: rateLimiter,
            embeddingProvider: effectiveEmbeddingProvider,
            skipStt: options.skipStt,
            onProgress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    // 节流：距上次 UI 更新不足 500ms 则跳过属性写入，
                    // 避免频繁触发 @Observable 变更通知和 SwiftUI 重渲染
                    let now = ContinuousClock.now
                    guard now - self.lastProgressUpdate >= self.progressThrottleInterval else { return }
                    self.lastProgressUpdate = now
                    self.currentVideoName = progress.fileName
                    self.currentStage = progress.stage
                }
            },
            onComplete: { [weak self] outcome in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if outcome.success {
                        self.folderProgress[folderPath]?.completedVideos += 1
                        if outcome.sttSkippedNoAudio {
                            self.folderProgress[folderPath]?.sttSkippedNoAudioVideos += 1
                            self.folderProgress[folderPath]?.nonFatalIssues.append(
                                (path: outcome.videoPath, message: "视频无音轨，已跳过语音转录")
                            )
                        }
                        let name = (outcome.videoPath as NSString).lastPathComponent
                        let suffix = outcome.sttSkippedNoAudio ? " [无音轨，已跳过 STT]" : ""
                        print("[IndexingManager] 完成: \(name)\(suffix)")
                    } else if outcome.errorMessage != "cancelled" {
                        self.folderProgress[folderPath]?.failedVideos += 1
                        self.folderProgress[folderPath]?.errors.append(
                            (path: outcome.videoPath,
                             message: outcome.errorMessage ?? "未知错误")
                        )
                        let name = (outcome.videoPath as NSString).lastPathComponent
                        print("[IndexingManager] 失败: \(name) - \(outcome.errorMessage ?? "")")
                    }
                }
            }
        )
        if let syncResult, syncResult.syncedClips > 0 {
            searchState?.invalidateVectorStore()
        }

        currentVideoName = nil
        currentStage = nil

        // 刷新文件夹列表（可能有新数据同步到全局库）
        try? appState?.reloadFolders()

        // 发送系统通知
        let folderName = URL(fileURLWithPath: folderPath).lastPathComponent
        if let progress = folderProgress[folderPath] {
            if progress.failedVideos > 0 {
                NotificationManager.notifyIndexFailed(
                    folderName: folderName,
                    failedCount: progress.failedVideos,
                    reason: progress.errors.first?.message
                )
            } else {
                NotificationManager.notifyIndexComplete(
                    folderName: folderName,
                    videoCount: progress.completedVideos,
                    clipCount: 0 // 片段数需从数据库查询，此处简化
                )
            }
        }
    }

    /// 处理指定视频文件列表（增量索引，跳过全量扫描）
    ///
    /// 由 FileWatcherManager 触发的 .added / .modified 事件使用。
    /// 复用 processFolder 的共享资源和调度器，但不扫描整个文件夹。
    private func processSpecificVideos(_ videoPaths: [String], in folderPath: String) async {
        currentFolder = folderPath

        // 过滤不存在的文件（.modified 事件后文件可能已被再次删除）
        let existingPaths = videoPaths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existingPaths.isEmpty else {
            currentFolder = nil
            return
        }

        let folderDB: DatabasePool
        do {
            folderDB = try await runBlockingIO {
                try DatabaseManager.openFolderDatabase(at: folderPath)
            }
        } catch {
            print("[IndexingManager] 打开文件夹数据库失败（增量）: \(error)")
            return
        }

        let options = IndexingOptions.load()
        initSharedResources(options: options)

        let globalDB = appState?.globalDB
        let effectiveAPIKey = options.skipVision ? nil : resolvedAPIKey
        let effectiveEmbeddingProvider = options.skipEmbedding ? nil : embeddingProvider

        let progressKey = folderPath
        // 累加到现有进度（如果有）或创建新的
        if folderProgress[progressKey] != nil {
            folderProgress[progressKey]!.totalVideos += existingPaths.count
        } else {
            folderProgress[progressKey] = FolderIndexProgress(totalVideos: existingPaths.count)
        }

        print("[IndexingManager] 增量索引: \(existingPaths.count) 个视频 in \(folderPath)")

        let currentScheduler = ensureScheduler(mode: options.performanceMode)

        let syncResult = await currentScheduler.processVideos(
            existingPaths,
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB,
            apiKey: effectiveAPIKey,
            rateLimiter: rateLimiter,
            embeddingProvider: effectiveEmbeddingProvider,
            skipStt: options.skipStt,
            onProgress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let now = ContinuousClock.now
                    guard now - self.lastProgressUpdate >= self.progressThrottleInterval else { return }
                    self.lastProgressUpdate = now
                    self.currentVideoName = progress.fileName
                    self.currentStage = progress.stage
                }
            },
            onComplete: { [weak self] outcome in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if outcome.success {
                        self.folderProgress[progressKey]?.completedVideos += 1
                        if outcome.sttSkippedNoAudio {
                            self.folderProgress[progressKey]?.sttSkippedNoAudioVideos += 1
                            self.folderProgress[progressKey]?.nonFatalIssues.append(
                                (path: outcome.videoPath, message: "视频无音轨，已跳过语音转录")
                            )
                        }
                        let name = (outcome.videoPath as NSString).lastPathComponent
                        let suffix = outcome.sttSkippedNoAudio ? " [无音轨，已跳过 STT]" : ""
                        print("[IndexingManager] 增量完成: \(name)\(suffix)")
                    } else if outcome.errorMessage != "cancelled" {
                        self.folderProgress[progressKey]?.failedVideos += 1
                        let name = (outcome.videoPath as NSString).lastPathComponent
                        print("[IndexingManager] 增量失败: \(name) - \(outcome.errorMessage ?? "")")
                    }
                }
            }
        )
        if let syncResult, syncResult.syncedClips > 0 {
            searchState?.invalidateVectorStore()
        }

        currentVideoName = nil
        currentStage = nil
        try? appState?.reloadFolders()
    }

    /// 确保 scheduler 存在，模式变更时重建
    private var currentMode: PerformanceMode?

    private func ensureScheduler(mode: PerformanceMode) -> IndexingScheduler {
        if let existing = scheduler, currentMode == mode {
            return existing
        }
        let newScheduler = IndexingScheduler(mode: mode)
        scheduler = newScheduler
        currentMode = mode
        return newScheduler
    }

    /// 结束后台活动声明
    private func endBackgroundActivity() {
        if let activity = backgroundActivity {
            ProcessInfo.processInfo.endActivity(activity)
            backgroundActivity = nil
        }
    }

    /// 懒初始化共享资源
    private func initSharedResources(options: IndexingOptions) {
        let config = ProviderConfig.load()

        // API Key
        if !hasResolvedAPIKey {
            hasResolvedAPIKey = true
            resolvedAPIKey = try? APIKeyManager.resolveAPIKey()
        }

        // RateLimiter（使用 ProviderConfig 的 RPM 设置）
        if rateLimiter == nil, resolvedAPIKey != nil {
            rateLimiter = GeminiRateLimiter(config: config.toRateLimiterConfig())
        }

        // EmbeddingProvider: 仅在未跳过时初始化
        if embeddingProvider == nil, !options.skipEmbedding {
            if let apiKey = resolvedAPIKey {
                embeddingProvider = GeminiEmbeddingProvider(
                    apiKey: apiKey,
                    config: config.toEmbeddingConfig()
                )
            } else {
                let nlProvider = NLEmbeddingProvider()
                if nlProvider.isAvailable() {
                    embeddingProvider = nlProvider
                    print("[IndexingManager] 使用 NLEmbedding 离线嵌入 (512 维)")
                }
            }
        }
    }
}
