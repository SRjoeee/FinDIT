import Foundation
import DiskArbitration
import FindItCore

/// 卷挂载/卸载事件监控
///
/// 使用 DiskArbitration 框架监听卷事件。
/// - 卷卸载 → 标记受影响文件夹为离线，暂停索引
/// - 卷挂载 → UUID 匹配 → 恢复在线 + 路径更新 + 恢复索引
@Observable
@MainActor
final class VolumeMonitor {

    /// 是否正在监控
    private(set) var isMonitoring = false

    /// AppState 引用
    weak var appState: AppState?

    /// IndexingManager 引用
    weak var indexingManager: IndexingManager?

    /// DiskArbitration session
    private var session: DASession?

    /// 是否已注册回调（用于 stopMonitoring 中平衡引用计数）
    private var hasRegisteredCallbacks = false

    // MARK: - 生命周期

    deinit {
        // 防御性安全网：确保 DiskArbitration 引用计数平衡
        // deinit 是 nonisolated，需 assumeIsolated 访问 actor 属性
        // （@State 属性的 deinit 在主线程执行，assumeIsolated 安全）
        MainActor.assumeIsolated {
            stopMonitoring()
        }
    }

    /// 开始监控卷挂载/卸载事件
    func startMonitoring() {
        guard !isMonitoring else { return }

        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            print("[VolumeMonitor] 无法创建 DASession")
            return
        }

        self.session = session
        DASessionSetDispatchQueue(session, DispatchQueue.main)

        // 使用 passRetained 防止回调期间 self 被释放
        // stopMonitoring/deinit 中通过 DASessionSetDispatchQueue(nil) 取消回调
        let context = Unmanaged.passRetained(self).toOpaque()

        DARegisterDiskAppearedCallback(session, nil, { disk, ctx in
            guard let ctx = ctx else { return }
            let monitor = Unmanaged<VolumeMonitor>.fromOpaque(ctx).takeUnretainedValue()
            monitor.handleDiskAppeared(disk)
        }, context)

        DARegisterDiskDisappearedCallback(session, nil, { disk, ctx in
            guard let ctx = ctx else { return }
            let monitor = Unmanaged<VolumeMonitor>.fromOpaque(ctx).takeUnretainedValue()
            monitor.handleDiskDisappeared(disk)
        }, context)

        hasRegisteredCallbacks = true
        isMonitoring = true
        print("[VolumeMonitor] 开始监控卷事件")
    }

    /// 停止监控
    func stopMonitoring() {
        guard isMonitoring else { return }

        if let session = session {
            // 取消所有回调（DASessionSetDispatchQueue(nil) 会 unregister）
            DASessionSetDispatchQueue(session, nil)
        }

        // 平衡 startMonitoring 中的 passRetained（注册了 1 次 context，retain 了 1 次）
        if hasRegisteredCallbacks {
            Unmanaged.passUnretained(self).release()
            hasRegisteredCallbacks = false
        }

        session = nil
        isMonitoring = false
        print("[VolumeMonitor] 停止监控卷事件")
    }

    /// 启动后主动对账路径重定向
    ///
    /// 解决“App 启动时卷已挂载，但未触发 DiskAppeared 回调”的场景：
    /// 对不可达路径按 UUID 做一次重定向修复，避免后续索引仍走旧路径。
    func reconcilePathsAtStartup() {
        guard let appState = appState else { return }

        var hasPathChange = false

        for folder in appState.folders where !folder.isAvailable {
            guard let uuid = folder.volumeUuid else { continue }
            guard let newPath = VolumeResolver.resolveUpdatedPath(
                oldPath: folder.folderPath,
                volumeUUID: uuid
            ) else { continue }
            guard newPath != folder.folderPath else { continue }

            updateFolderPath(from: folder.folderPath, to: newPath)
            hasPathChange = true
        }

        if hasPathChange {
            try? appState.reloadFolders()
            print("[VolumeMonitor] 启动对账完成，已修复路径重定向")
        }
    }

    // MARK: - 事件处理

    /// 新卷挂载
    private func handleDiskAppeared(_ disk: DADisk) {
        guard let description = DADiskCopyDescription(disk) as? [String: Any] else { return }

        // 只关心有挂载点的卷（跳过未挂载的分区）
        guard let mountPointURL = description[kDADiskDescriptionVolumePathKey as String] as? URL else { return }
        let mountPoint = mountPointURL.path

        // 通过 VolumeResolver 获取卷信息（URL.resourceValues，安全的 Swift API）
        let volumeInfo = VolumeResolver.resolve(path: mountPoint)
        let volumeName = volumeInfo.name
            ?? (description[kDADiskDescriptionVolumeNameKey as String] as? String)

        print("[VolumeMonitor] 卷挂载: \(volumeName ?? "未知") at \(mountPoint)" +
              (volumeInfo.uuid != nil ? " UUID=\(volumeInfo.uuid!)" : ""))

        handleVolumeAppeared(mountPoint: mountPoint, uuid: volumeInfo.uuid, volumeName: volumeName)
    }

    /// 卷卸载
    private func handleDiskDisappeared(_ disk: DADisk) {
        guard let description = DADiskCopyDescription(disk) as? [String: Any] else { return }

        guard let mountPointURL = description[kDADiskDescriptionVolumePathKey as String] as? URL else { return }
        let mountPoint = mountPointURL.path

        let volumeName = description[kDADiskDescriptionVolumeNameKey as String] as? String

        print("[VolumeMonitor] 卷卸载: \(volumeName ?? "未知") at \(mountPoint)")

        handleVolumeDisappeared(mountPoint: mountPoint)
    }

    // MARK: - 业务逻辑

    /// 处理卷挂载 — 恢复离线文件夹
    private func handleVolumeAppeared(mountPoint: String, uuid: String?, volumeName: String?) {
        guard let appState = appState else { return }

        // 记录恢复后的实际路径（可能因挂载点变更而不同于原始路径）
        var restoredPaths: [String] = []

        for folder in appState.folders where !folder.isAvailable {
            // 策略 1: 路径直接可达（卷重新挂载到相同路径）
            if VolumeResolver.isPath(folder.folderPath, underMountPoint: mountPoint),
               FileManager.default.fileExists(atPath: folder.folderPath) {
                restoredPaths.append(folder.folderPath)
                continue
            }

            // 策略 2: UUID 匹配（挂载点可能变了）
            if let uuid = uuid, let folderUUID = folder.volumeUuid, uuid == folderUUID {
                if let newPath = VolumeResolver.resolveUpdatedPath(
                    oldPath: folder.folderPath,
                    volumeUUID: uuid
                ) {
                    // 挂载点变更，需要更新数据库中的路径
                    if newPath != folder.folderPath {
                        updateFolderPath(from: folder.folderPath, to: newPath)
                    }
                    restoredPaths.append(newPath)
                }
            }
        }

        if !restoredPaths.isEmpty {
            try? appState.reloadFolders()

            // 恢复未完成的索引（使用更新后的路径）
            for folderPath in restoredPaths {
                indexingManager?.queueFolder(folderPath)
            }

            // 系统通知
            if let volumeName = volumeName ?? uuid {
                NotificationManager.notifyVolumeReconnected(
                    volumeName: volumeName,
                    restoredFolders: restoredPaths.count
                )
            }

            print("[VolumeMonitor] 恢复 \(restoredPaths.count) 个文件夹")
        }
    }

    /// 处理卷卸载 — 标记文件夹离线
    private func handleVolumeDisappeared(mountPoint: String) {
        guard let appState = appState else { return }

        var affectedFolders: [String] = []

        for folder in appState.folders where folder.isAvailable {
            if VolumeResolver.isPath(folder.folderPath, underMountPoint: mountPoint) {
                affectedFolders.append(folder.folderPath)
            }
        }

        if !affectedFolders.isEmpty {
            // 获取卷名（用于通知），在 reloadFolders 之前取
            let volumeName = appState.folders
                .first { affectedFolders.contains($0.folderPath) }?
                .volumeName

            try? appState.reloadFolders()

            // 系统通知
            if let volumeName = volumeName {
                NotificationManager.notifyVolumeDisconnected(volumeName: volumeName)
            }

            print("[VolumeMonitor] \(affectedFolders.count) 个文件夹离线")
        }
    }

    /// 更新文件夹路径（挂载点变更时）
    ///
    /// 路径切换时需保持"文件夹库(source of truth)"与全局库一致：
    /// 1) 先重定向文件夹库中的绝对路径（PathRebaser 处理 videos/clips）。
    /// 2) 更新全局库中的 source_folder 键（SyncEngine 按此定位记录）。
    /// 3) Force sync 把文件夹库最新路径同步到全局库的所有字段。
    private func updateFolderPath(from oldPath: String, to newPath: String) {
        guard let globalDB = appState?.globalDB else { return }

        do {
            // 修复文件夹库路径（source of truth）
            let folderDB = try DatabaseManager.openFolderDatabase(at: newPath)
            let rebaseResult = try PathRebaser.rebaseIfNeeded(
                folderDB: folderDB,
                newPath: newPath
            )

            // 更新全局库的键列（source_folder 是 SyncEngine 的 upsert 冲突键）
            try globalDB.write { db in
                try db.execute(sql: """
                    UPDATE sync_meta SET folder_path = ? WHERE folder_path = ?
                    """, arguments: [newPath, oldPath])
                try db.execute(sql: """
                    UPDATE videos SET source_folder = ? WHERE source_folder = ?
                    """, arguments: [newPath, oldPath])
                try db.execute(sql: """
                    UPDATE clips SET source_folder = ? WHERE source_folder = ?
                    """, arguments: [newPath, oldPath])
            }

            // Force sync 更新全局库中的路径字段（file_path, srt_path, thumbnail_path 等）
            let _ = try SyncEngine.sync(
                folderPath: newPath,
                folderDB: folderDB,
                globalDB: globalDB,
                force: true
            )

            print("[VolumeMonitor] 路径更新: \(oldPath) → \(newPath), rebase=\(rebaseResult.didRebase)")
        } catch {
            print("[VolumeMonitor] 路径更新失败: \(error)")
        }
    }
}
