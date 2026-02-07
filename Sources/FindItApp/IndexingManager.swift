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

    // MARK: - 私有状态

    /// 待处理文件夹队列
    private var pendingFolders: [String] = []

    /// 当前处理 Task（用于取消）
    private var processingTask: Task<Void, Never>?

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
    func queueFolder(_ path: String) {
        // 避免重复入队
        guard !pendingFolders.contains(path) else { return }
        // 避免正在处理的文件夹重复入队
        guard currentFolder != path else { return }

        pendingFolders.append(path)

        // 如果没有正在运行的 task，启动处理
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
        // 唤醒可能阻塞在信号量上的等待者
        if let scheduler = scheduler {
            Task { await scheduler.releaseWaiters() }
        }
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

        for folder in appState.folders {
            queueFolder(folder.folderPath)
        }
    }

    // MARK: - 私有方法

    /// 启动队列处理
    private func startProcessing() {
        processingTask = Task { [weak self] in
            guard let self = self else { return }
            await self.processQueue()
        }
    }

    /// 串行处理文件夹队列
    private func processQueue() async {
        isIndexing = true

        while !pendingFolders.isEmpty {
            guard !Task.isCancelled else { break }

            let folderPath = pendingFolders.removeFirst()
            await processFolder(folderPath)
        }

        // 队列清空
        isIndexing = false
        currentFolder = nil
        currentVideoName = nil
        currentStage = nil
        processingTask = nil
    }

    /// 处理单个文件夹（通过 IndexingScheduler 并行处理视频）
    private func processFolder(_ folderPath: String) async {
        currentFolder = folderPath

        // 扫描视频文件
        let videoFiles: [String]
        do {
            videoFiles = try FileScanner.scanVideoFiles(in: folderPath)
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
            folderDB = try DatabaseManager.openFolderDatabase(at: folderPath)
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
        await currentScheduler.processVideos(
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
                    self?.currentVideoName = progress.fileName
                    self?.currentStage = progress.stage
                }
            },
            onComplete: { [weak self] outcome in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if outcome.success {
                        self.folderProgress[folderPath]?.completedVideos += 1
                        let name = (outcome.videoPath as NSString).lastPathComponent
                        print("[IndexingManager] 完成: \(name)")
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

        currentVideoName = nil
        currentStage = nil

        // 刷新文件夹列表（可能有新数据同步到全局库）
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
