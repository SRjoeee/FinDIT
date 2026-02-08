import Foundation
import CoreServices

// MARK: - FileChangeEvent

/// 文件系统变更事件
public struct FileChangeEvent: Sendable, Equatable {

    /// 变更类型
    public enum Kind: String, Sendable, Equatable {
        /// 新文件出现（创建或从外部移入）
        case added
        /// 文件消失（删除或移出监控目录）
        case removed
        /// 文件内容或元数据变更
        case modified
        /// 需要全量重新扫描（FSEvents 内核缓冲区溢出或监控根目录变更）
        case rescanNeeded
    }

    /// 文件绝对路径
    public let path: String
    /// 变更类型
    public let kind: Kind
    /// 所属监控文件夹路径
    public let folderPath: String
}

// MARK: - FileSystemWatcher

/// 文件系统变更监控器
///
/// 使用 macOS FSEvents 框架实时监听注册文件夹中的视频文件变动。
/// 仅报告 `FileScanner.supportedExtensions` 匹配的文件事件，
/// 自动过滤 `.clip-index` 元数据目录。
///
/// 每个监控文件夹使用独立的 `FSEventStream`，通过延迟合并窗口
/// （默认 1.5 秒）减少事件风暴。同一批次内的重复路径自动去重。
public final class FileSystemWatcher {

    /// 事件回调类型
    public typealias EventHandler = ([FileChangeEvent]) -> Void

    // MARK: - Properties

    /// 事件回调（在 callbackQueue 上调用）
    private let handler: EventHandler

    /// 回调执行队列
    private let callbackQueue: DispatchQueue

    /// FSEvents 延迟合并窗口（秒）
    private let latency: CFTimeInterval

    /// 活跃的 FSEventStream（folderPath → StreamInfo）
    private var streams: [String: StreamInfo] = [:]

    /// 保护 streams 字典的串行队列
    private let stateQueue = DispatchQueue(label: "com.findit.fswatcher.state")

    // MARK: - Public API

    /// 是否正在监控（至少有一个活跃 stream）
    public var isMonitoring: Bool {
        stateQueue.sync { !streams.isEmpty }
    }

    /// 当前监控的文件夹路径集合
    public var watchedPaths: Set<String> {
        stateQueue.sync { Set(streams.keys) }
    }

    /// 创建文件系统监控器
    ///
    /// - Parameters:
    ///   - latency: FSEvents 延迟合并窗口（秒），默认 1.5
    ///   - callbackQueue: 事件回调的执行队列，默认 `.main`
    ///   - handler: 事件回调，接收一批去重后的文件变更事件
    public init(
        latency: CFTimeInterval = 1.5,
        callbackQueue: DispatchQueue = .main,
        handler: @escaping EventHandler
    ) {
        self.latency = latency
        self.callbackQueue = callbackQueue
        self.handler = handler
    }

    deinit {
        // deinit 时无其他强引用，无需 stateQueue 保护，直接清理避免潜在死锁
        for (_, info) in streams {
            teardownStream(info)
        }
        streams.removeAll()
    }

    /// 开始监控指定文件夹
    ///
    /// 如果该路径已在监控中，不做任何操作。
    /// 递归监控所有子目录，自动排除 `.clip-index` 目录和非视频文件。
    ///
    /// - Parameter folderPath: 文件夹绝对路径
    public func watch(_ folderPath: String) {
        stateQueue.sync {
            guard streams[folderPath] == nil else { return }

            let context = WatcherContext(watcher: self, folderPath: folderPath)
            let retained = Unmanaged.passRetained(context)

            var streamContext = FSEventStreamContext(
                version: 0,
                info: retained.toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                { _, info, numEvents, eventPaths, eventFlags, _ in
                    FileSystemWatcher.handleCallback(
                        info: info,
                        numEvents: numEvents,
                        eventPaths: eventPaths,
                        eventFlags: eventFlags
                    )
                },
                &streamContext,
                [folderPath] as CFArray,
                FSEventsGetCurrentEventId(),
                latency,
                UInt32(kFSEventStreamCreateFlagFileEvents |
                       kFSEventStreamCreateFlagUseCFTypes)
            ) else {
                retained.release()
                print("[FileSystemWatcher] 无法创建 FSEventStream: \(folderPath)")
                return
            }

            let safeLabel = folderPath.replacingOccurrences(of: "/", with: ".")
            let streamQueue = DispatchQueue(label: "com.findit.fswatcher.\(safeLabel)")
            FSEventStreamSetDispatchQueue(stream, streamQueue)
            FSEventStreamStart(stream)

            streams[folderPath] = StreamInfo(stream: stream, contextRef: retained)
            print("[FileSystemWatcher] 开始监控: \(folderPath)")
        }
    }

    /// 停止监控指定文件夹
    ///
    /// - Parameter folderPath: 要停止监控的文件夹路径
    public func unwatch(_ folderPath: String) {
        stateQueue.sync {
            guard let info = streams.removeValue(forKey: folderPath) else { return }
            teardownStream(info)
            print("[FileSystemWatcher] 停止监控: \(folderPath)")
        }
    }

    /// 停止所有监控并释放资源
    public func stopAll() {
        stateQueue.sync {
            for (_, info) in streams {
                teardownStream(info)
            }
            streams.removeAll()
        }
    }

    // MARK: - Internal（可测试）

    /// 同路径去重：后出现的事件覆盖先出现的
    ///
    /// FSEvents 合并窗口内可能为同一路径产生多个事件（如创建后立即修改），
    /// 去重后仅保留最后一个事件。由于 `classifyEvent` 基于文件实时存在性判断，
    /// 同一路径的所有事件具有一致的存在性状态。
    public static func deduplicateEvents(_ events: [FileChangeEvent]) -> [FileChangeEvent] {
        var seen: [String: Int] = [:]
        var result: [FileChangeEvent] = []
        for event in events {
            if let idx = seen[event.path] {
                result[idx] = event
            } else {
                seen[event.path] = result.count
                result.append(event)
            }
        }
        return result
    }

    /// 根据 FSEvents 标志和文件实际存在性判断变更类型
    ///
    /// FSEvents 标志可能不准确（延迟合并 + 内核优化），
    /// 因此以文件实际存在性为最终依据。
    static func classifyEvent(
        flags: FSEventStreamEventFlags,
        path: String
    ) -> FileChangeEvent.Kind? {
        let fileExists = FileManager.default.fileExists(atPath: path)

        if !fileExists {
            // 文件不存在：仅在 flags 明确表明变更时报告 .removed
            let changeMask = UInt32(
                kFSEventStreamEventFlagItemRemoved |
                kFSEventStreamEventFlagItemRenamed |
                kFSEventStreamEventFlagItemCreated |
                kFSEventStreamEventFlagItemModified
            )
            return (flags & changeMask) != 0 ? .removed : nil
        }

        // 文件存在 + 创建标志 → 新增
        if flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 {
            return .added
        }

        // 文件存在 + 重命名标志 → 移入（视为新增）
        if flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 {
            return .added
        }

        // 文件存在 + 修改标志 → 修改
        if flags & UInt32(kFSEventStreamEventFlagItemModified) != 0 ||
           flags & UInt32(kFSEventStreamEventFlagItemInodeMetaMod) != 0 ||
           flags & UInt32(kFSEventStreamEventFlagItemXattrMod) != 0 {
            return .modified
        }

        // 文件存在但无明确标志 → 安全起见报告修改
        return .modified
    }

    // MARK: - Private

    /// 流信息（stream 句柄 + 上下文引用，用于生命周期管理）
    private struct StreamInfo {
        let stream: FSEventStreamRef
        let contextRef: Unmanaged<WatcherContext>
    }

    /// 清理单个 stream：停止 → 失效 → 释放
    private func teardownStream(_ info: StreamInfo) {
        FSEventStreamStop(info.stream)
        FSEventStreamInvalidate(info.stream)
        FSEventStreamRelease(info.stream)
        info.contextRef.release()
    }

    /// 处理 FSEvents 原始回调
    ///
    /// 从 C 回调桥接到 Swift：解析路径和标志，筛选视频文件，
    /// 分类事件类型，去重后分发到 callbackQueue。
    private static func handleCallback(
        info: UnsafeMutableRawPointer?,
        numEvents: Int,
        eventPaths: UnsafeMutableRawPointer,
        eventFlags: UnsafePointer<FSEventStreamEventFlags>
    ) {
        guard let info = info else { return }
        let context = Unmanaged<WatcherContext>.fromOpaque(info).takeUnretainedValue()
        guard let watcher = context.watcher else { return }

        let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        let pathCount = CFArrayGetCount(cfArray)

        var events: [FileChangeEvent] = []
        var needsRescan = false

        for i in 0..<numEvents {
            guard i < pathCount else { break }
            let flags = eventFlags[i]

            // 内核事件缓冲区溢出 → 需要全量重新扫描
            if flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                needsRescan = true
                continue
            }

            // 监控根目录被移动/删除
            if flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                needsRescan = true
                continue
            }

            // 跳过目录事件
            if flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 { continue }

            // 获取路径
            guard let rawPtr = CFArrayGetValueAtIndex(cfArray, i) else { continue }
            let path = Unmanaged<CFString>.fromOpaque(rawPtr)
                .takeUnretainedValue() as String

            // 跳过 .clip-index 元数据目录
            if path.contains("/.clip-index/") { continue }

            // 仅视频文件
            guard FileScanner.isVideoFile(path) else { continue }

            // 判断变更类型
            guard let kind = classifyEvent(flags: flags, path: path) else { continue }

            events.append(FileChangeEvent(
                path: path,
                kind: kind,
                folderPath: context.folderPath
            ))
        }

        // 内核溢出或根目录变更 → 插入 rescanNeeded 事件
        if needsRescan {
            events.insert(
                FileChangeEvent(
                    path: context.folderPath,
                    kind: .rescanNeeded,
                    folderPath: context.folderPath
                ),
                at: 0
            )
        }

        guard !events.isEmpty else { return }

        let deduplicated = deduplicateEvents(events)
        watcher.callbackQueue.async {
            watcher.handler(deduplicated)
        }
    }
}

// MARK: - WatcherContext

/// FSEvents 回调桥接上下文
///
/// 持有监控器的弱引用（避免 retain cycle）和文件夹路径。
/// 生命周期由 `Unmanaged.passRetained` / `.release()` 手动管理。
private final class WatcherContext {
    weak var watcher: FileSystemWatcher?
    let folderPath: String

    init(watcher: FileSystemWatcher, folderPath: String) {
        self.watcher = watcher
        self.folderPath = folderPath
    }
}
