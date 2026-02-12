import Foundation
import GRDB

/// 并行索引调度器（ADR-014）
///
/// 基于资源池模型的视频索引调度器。使用 `AsyncSemaphore` 控制
/// 视频级并发，`ResourceMonitor` 根据系统状态动态调整并发数。
///
/// 架构:
/// ```
///                 ┌──────────────────────────┐
///                 │   IndexingScheduler       │
///                 │   videoSemaphore(N slots)  │
///                 └─────────┬────────────────┘
///                           │ (TaskGroup)
///        ┌────────┬────────┼────────┬────────┐
///        ▼        ▼        ▼        ▼        ▼
///    [Video1] [Video2] [Video3]   ...    [VideoN]
///    Pipeline Pipeline Pipeline         Pipeline
/// ```
///
/// 每个视频通过 `LayeredIndexer.indexVideo()` 处理，
/// 并发数由 ResourceMonitor 根据热量/内存/电源动态调整。
///
/// 使用示例:
/// ```swift
/// let scheduler = IndexingScheduler(mode: .balanced)
/// await scheduler.processVideosLayered(
///     videoFiles, folderPath: path,
///     folderDB: db,
///     onProgress: { print($0.fileName, $0.stage) },
///     onComplete: { print($0.videoPath, $0.success) }
/// )
/// ```
public final class IndexingScheduler: @unchecked Sendable {

    // MARK: - 回调类型

    /// 单视频进度报告
    public struct VideoProgress: Sendable {
        /// 视频文件路径
        public let videoPath: String
        /// 视频文件名
        public let fileName: String
        /// 当前阶段描述
        public let stage: String
    }

    /// 单视频处理结果
    public struct VideoOutcome: Sendable {
        /// 视频文件路径
        public let videoPath: String
        /// 是否成功
        public let success: Bool
        /// 错误信息（失败时）
        public let errorMessage: String?
        /// 创建的 clip 数量（成功时）
        public let clipsCreated: Int
        /// 完成视觉分析的 clip 数量（成功时）
        public let clipsAnalyzed: Int
        /// 完成嵌入的 clip 数量（成功时）
        public let clipsEmbedded: Int
        /// 是否因无音轨而跳过 STT（非致命降级）
        public let sttSkippedNoAudio: Bool

        /// 成功结果
        public static func success(
            videoPath: String,
            clipsCreated: Int = 0,
            clipsAnalyzed: Int = 0,
            clipsEmbedded: Int = 0,
            sttSkippedNoAudio: Bool = false
        ) -> VideoOutcome {
            VideoOutcome(
                videoPath: videoPath, success: true, errorMessage: nil,
                clipsCreated: clipsCreated, clipsAnalyzed: clipsAnalyzed,
                clipsEmbedded: clipsEmbedded,
                sttSkippedNoAudio: sttSkippedNoAudio
            )
        }

        /// 失败结果
        public static func failure(videoPath: String, error: String) -> VideoOutcome {
            VideoOutcome(
                videoPath: videoPath, success: false, errorMessage: error,
                clipsCreated: 0, clipsAnalyzed: 0, clipsEmbedded: 0,
                sttSkippedNoAudio: false
            )
        }

        /// 被取消/跳过
        public static func skipped(videoPath: String) -> VideoOutcome {
            VideoOutcome(
                videoPath: videoPath, success: false, errorMessage: "cancelled",
                clipsCreated: 0, clipsAnalyzed: 0, clipsEmbedded: 0,
                sttSkippedNoAudio: false
            )
        }
    }

    // MARK: - 属性

    /// 资源监控器（公开，供 UI 读取系统状态）
    public let resourceMonitor: ResourceMonitor

    /// 视频级并发信号量
    let videoSemaphore: AsyncSemaphore

    // MARK: - 初始化

    /// 创建调度器
    ///
    /// - Parameter mode: 性能模式（默认 `.balanced`）
    public init(mode: PerformanceMode = .balanced) {
        let initial = ResourceMonitor.initialConcurrency(for: mode)
        self.resourceMonitor = ResourceMonitor(mode: mode)
        self.videoSemaphore = AsyncSemaphore(value: initial)
    }

    /// 创建调度器（指定初始并发数，用于测试）
    public init(concurrency: Int, mode: PerformanceMode = .balanced) {
        self.resourceMonitor = ResourceMonitor(mode: mode)
        self.videoSemaphore = AsyncSemaphore(value: max(1, concurrency))
    }

    // MARK: - 核心方法

    /// 并行处理视频列表
    ///
    // MARK: - 分层索引

    /// 并行处理视频列表（分层索引）
    ///
    /// 使用 `LayeredIndexer` 四层架构。Layer 1 完成后视频即可搜索。
    public func processVideosLayered(
        _ videos: [String],
        folderPath: String,
        folderDB: DatabaseWriter,
        globalDB: DatabaseWriter? = nil,
        config: LayeredIndexer.Config,
        onProgress: @Sendable @escaping (VideoProgress) -> Void = { _ in },
        onComplete: @Sendable @escaping (VideoOutcome) -> Void = { _ in }
    ) async -> SyncEngine.SyncResult? {
        guard !videos.isEmpty else { return nil }

        let sem = videoSemaphore
        let monitor = resourceMonitor
        var requiresForceSync = false

        await monitor.startMonitoring { recommended in
            Task { await sem.setMaxPermits(recommended) }
        }

        await withTaskGroup(of: Bool.self) { group in
            for videoPath in videos {
                guard !Task.isCancelled else { break }
                await sem.acquire()
                guard !Task.isCancelled else {
                    await sem.release()
                    break
                }

                let fileName = (videoPath as NSString).lastPathComponent

                group.addTask {
                    onProgress(VideoProgress(
                        videoPath: videoPath, fileName: fileName, stage: "准备中"
                    ))

                    do {
                        let result = try await PipelineManager.processVideoLayered(
                            videoPath: videoPath,
                            folderPath: folderPath,
                            folderDB: folderDB,
                            globalDB: globalDB,
                            config: config,
                            skipSync: true,
                            onProgress: { stage in
                                onProgress(VideoProgress(
                                    videoPath: videoPath,
                                    fileName: fileName,
                                    stage: stage
                                ))
                            }
                        )

                        await sem.release()

                        onComplete(.success(
                            videoPath: videoPath,
                            clipsCreated: result.clipsCreated,
                            clipsAnalyzed: result.clipsAnalyzed,
                            clipsEmbedded: result.clipsEmbedded,
                            sttSkippedNoAudio: result.sttSkippedNoAudio
                        ))
                        return result.requiresForceSync

                    } catch is CancellationError {
                        await sem.release()
                        onComplete(.skipped(videoPath: videoPath))
                        return false

                    } catch {
                        await sem.release()
                        onComplete(.failure(
                            videoPath: videoPath,
                            error: error.localizedDescription
                        ))
                        return false
                    }
                }
            }
            for await childRequiresForceSync in group {
                requiresForceSync = requiresForceSync || childRequiresForceSync
            }
        }

        await monitor.stopMonitoring()

        if let globalDB = globalDB {
            do {
                let sr = try SyncEngine.sync(
                    folderPath: folderPath,
                    folderDB: folderDB,
                    globalDB: globalDB,
                    force: requiresForceSync
                )
                if sr.syncedClips > 0 || sr.syncedVideos > 0 {
                    onProgress(VideoProgress(
                        videoPath: folderPath,
                        fileName: "",
                        stage: "同步完成: \(sr.syncedVideos) 视频, \(sr.syncedClips) 片段"
                    ))
                }
                return sr
            } catch {
                onProgress(VideoProgress(
                    videoPath: folderPath,
                    fileName: "",
                    stage: "同步失败: \(error.localizedDescription)"
                ))
                return nil
            }
        }
        return nil
    }

    // MARK: - 运行时控制

    /// 更新性能模式
    ///
    /// 立即生效：调整资源监控器模式并更新信号量许可数。
    /// 正在处理的视频不受影响，新的并发上限影响后续调度。
    public func updateMode(_ mode: PerformanceMode) async {
        await resourceMonitor.setMode(mode)
        let recommended = await resourceMonitor.sampleAndRecommend()
        await videoSemaphore.setMaxPermits(recommended)
    }

    /// 释放所有等待中的信号量许可
    ///
    /// 配合 Task.cancel() 使用。先取消父 Task，
    /// 再调用此方法唤醒可能阻塞在 `acquire()` 的等待者。
    public func releaseWaiters() async {
        await videoSemaphore.releaseAll()
    }

    /// 当前并发状态
    public func concurrencyInfo() async -> (available: Int, waiting: Int, max: Int) {
        let available = await videoSemaphore.available
        let waiting = await videoSemaphore.waitingCount
        let max = await videoSemaphore.currentMax
        return (available, waiting, max)
    }
}
