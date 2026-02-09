import Foundation
import GRDB
import FindItCore

/// 文件夹操作错误
enum FolderError: LocalizedError {
    /// 路径已注册
    case duplicate
    /// 路径已被父文件夹覆盖（子文件夹书签限制暂不支持）
    case alreadyCovered(String)

    var errorDescription: String? {
        switch self {
        case .duplicate:
            return "该文件夹已添加"
        case .alreadyCovered(let message):
            return message
        }
    }
}

/// App 全局状态
///
/// 管理数据库连接、文件夹列表等应用级状态。
/// 使用 @Observable (macOS 14+) 驱动 SwiftUI 视图更新。
@Observable
@MainActor
final class AppState {
    /// 全局搜索索引数据库
    var globalDB: DatabasePool?

    /// 已注册的文件夹列表
    var folders: [WatchedFolder] = []

    /// 子文件夹书签（父文件夹下被钉住的子路径）
    ///
    /// 这些路径不会被独立索引，仅作为侧边栏快捷入口，
    /// 点击时通过路径前缀过滤搜索结果。
    var subfolderBookmarks: [String] = [] {
        didSet { persistBookmarks() }
    }

    /// 数据库是否已初始化
    var isInitialized = false

    /// 初始化错误信息
    var initError: String?

    /// IndexingManager 引用（由 ContentView 注入）
    weak var indexingManager: IndexingManager?

    /// FileWatcherManager 引用（由 ContentView 注入）
    weak var fileWatcherManager: FileWatcherManager?

    /// 卷信息缓存（避免每次 reloadFolders 都做文件系统调用）
    private var volumeInfoCache: [String: VolumeResolver.VolumeInfo] = [:]

    /// UserDefaults key for subfolder bookmarks
    private static let bookmarksKey = "FindIt.subfolderBookmarks"

    // MARK: - 初始化

    /// 初始化全局数据库并加载文件夹列表
    ///
    /// 在后台线程执行数据库打开操作，避免阻塞主线程。
    func initialize() async {
        do {
            let db = try await Task.detached(priority: .userInitiated) {
                try DatabaseManager.openGlobalDatabase()
            }.value
            self.globalDB = db
            loadBookmarks()
            try reloadFolders()
            self.isInitialized = true
        } catch {
            self.initError = error.localizedDescription
        }
    }

    // MARK: - 文件夹管理

    /// 添加监控文件夹
    ///
    /// 使用 `FolderHierarchy` 智能处理嵌套关系：
    /// - **无重叠**: 正常添加并索引
    /// - **添加父级**: 索引时排除已有子文件夹，避免重复
    /// - **添加子级**: 仅创建侧边栏书签，不重复索引
    /// - **重复**: 静默忽略
    func addFolder(path: String) async throws {
        guard let globalDB = globalDB else { return }

        let existingPaths = folders.map(\.folderPath)
        let plan = FolderHierarchy.resolveAddition(newPath: path, existingPaths: existingPaths)

        switch plan.action {
        case .duplicate:
            return // 静默忽略

        case .addAsSubfolderBookmark(let parentFolder):
            // 子文件夹书签：不索引，仅 UI 快捷入口
            let parentName = URL(fileURLWithPath: parentFolder).lastPathComponent
            let subName = URL(fileURLWithPath: path).lastPathComponent

            guard !subfolderBookmarks.contains(path) else { return }
            subfolderBookmarks.append(path)

            // 不需要数据库操作，仅在侧边栏展示
            print("[AppState] 添加子文件夹书签: \(subName) (父级: \(parentName))")

        case .addAsParent(let existingChildren):
            // 添加父级：创建数据库，索引时排除已有子文件夹
            let volumeInfo = VolumeResolver.resolve(path: path)
            volumeInfoCache[path] = volumeInfo

            try await Task.detached(priority: .userInitiated) {
                let folderDB = try DatabaseManager.openFolderDatabase(at: path)

                // 便携索引：检测并修复路径偏移（跨机器/路径变更）
                let rebaseResult = try PathRebaser.rebaseIfNeeded(
                    folderDB: folderDB,
                    newPath: path
                )

                try folderDB.write { db in
                    let existing = try WatchedFolder.fetchOne(db, sql:
                        "SELECT * FROM watched_folders WHERE folder_path = ?",
                        arguments: [path])
                    if existing == nil {
                        var folder = WatchedFolder(
                            folderPath: path,
                            volumeName: volumeInfo.name,
                            volumeUuid: volumeInfo.uuid,
                            lastSeenAt: Clip.sqliteDatetime()
                        )
                        try folder.insert(db)
                    } else {
                        // 重新添加：更新卷信息（跨机器时 volume 可能变了）
                        try db.execute(sql: """
                            UPDATE watched_folders SET volume_name = ?, volume_uuid = ?,
                                is_available = 1, last_seen_at = ?
                            WHERE folder_path = ?
                            """, arguments: [volumeInfo.name, volumeInfo.uuid,
                                             Clip.sqliteDatetime(), path])
                    }
                }

                let _ = try SyncEngine.sync(
                    folderPath: path,
                    folderDB: folderDB,
                    globalDB: globalDB,
                    force: rebaseResult.didRebase
                )
            }.value

            try reloadFolders()

            // 通知 IndexingManager 索引时排除子文件夹
            indexingManager?.queueFolder(path, excluding: Set(existingChildren))
            fileWatcherManager?.watchFolder(path)

        case .addNormally:
            // 正常添加（无重叠）
            let volumeInfo = VolumeResolver.resolve(path: path)
            volumeInfoCache[path] = volumeInfo

            try await Task.detached(priority: .userInitiated) {
                let folderDB = try DatabaseManager.openFolderDatabase(at: path)

                // 便携索引：检测并修复路径偏移（跨机器/路径变更）
                let rebaseResult = try PathRebaser.rebaseIfNeeded(
                    folderDB: folderDB,
                    newPath: path
                )

                try folderDB.write { db in
                    let existing = try WatchedFolder.fetchOne(db, sql:
                        "SELECT * FROM watched_folders WHERE folder_path = ?",
                        arguments: [path])
                    if existing == nil {
                        var folder = WatchedFolder(
                            folderPath: path,
                            volumeName: volumeInfo.name,
                            volumeUuid: volumeInfo.uuid,
                            lastSeenAt: Clip.sqliteDatetime()
                        )
                        try folder.insert(db)
                    } else {
                        // 重新添加：更新卷信息（跨机器时 volume 可能变了）
                        try db.execute(sql: """
                            UPDATE watched_folders SET volume_name = ?, volume_uuid = ?,
                                is_available = 1, last_seen_at = ?
                            WHERE folder_path = ?
                            """, arguments: [volumeInfo.name, volumeInfo.uuid,
                                             Clip.sqliteDatetime(), path])
                    }
                }

                let _ = try SyncEngine.sync(
                    folderPath: path,
                    folderDB: folderDB,
                    globalDB: globalDB,
                    force: rebaseResult.didRebase
                )
            }.value

            try reloadFolders()

            indexingManager?.queueFolder(path)
            fileWatcherManager?.watchFolder(path)
        }
    }

    /// 移除文件夹
    func removeFolder(path: String) throws {
        fileWatcherManager?.unwatchFolder(path)
        guard let globalDB = globalDB else { return }

        try SyncEngine.removeFolderData(folderPath: path, from: globalDB)

        // 同时移除该文件夹下的所有子文件夹书签
        subfolderBookmarks.removeAll { bookmark in
            FolderHierarchy.relationship(path, bookmark) == .parent
        }

        try reloadFolders()
    }

    /// 移除子文件夹书签
    func removeBookmark(path: String) {
        subfolderBookmarks.removeAll { $0 == path }
    }

    // MARK: - 文件夹列表

    /// 从全局库加载文件夹列表
    ///
    /// 刷新 `folders` 数组，包含卷信息和统计数据。
    /// IndexingManager 索引完成后也需调用此方法以反映新同步的数据。
    func reloadFolders() throws {
        guard let globalDB = globalDB else { return }

        // 从 sync_meta 获取所有已同步的文件夹路径
        let rows = try globalDB.read { db in
            try Row.fetchAll(db, sql: "SELECT folder_path FROM sync_meta ORDER BY folder_path")
        }

        self.folders = try rows.map { row in
            let path: String = row["folder_path"]
            var isAvailable = FileManager.default.fileExists(atPath: path)

            // 缓存卷信息（仅在缓存未命中且路径可达时解析）
            if volumeInfoCache[path] == nil, isAvailable {
                volumeInfoCache[path] = VolumeResolver.resolve(path: path)
            }

            let volumeInfo = volumeInfoCache[path]

            // 如果路径不可达但有 UUID，尝试通过 UUID 恢复
            if !isAvailable, let uuid = volumeInfo?.uuid {
                if VolumeResolver.resolveUpdatedPath(oldPath: path, volumeUUID: uuid) != nil {
                    isAvailable = true
                }
            }

            // 从全局库查询统计
            let stats = try globalDB.read { db in
                try SearchEngine.folderStats(db, folderPath: path)
            }

            return WatchedFolder(
                folderPath: path,
                volumeName: volumeInfo?.name,
                volumeUuid: volumeInfo?.uuid,
                isAvailable: isAvailable,
                lastSeenAt: isAvailable ? Clip.sqliteDatetime() : nil,
                totalFiles: stats.videoCount,
                indexedFiles: stats.clipCount
            )
        }

        // 清理失效的子文件夹书签（父文件夹被移除后）
        let registeredPaths = Set(self.folders.map(\.folderPath))
        subfolderBookmarks.removeAll { bookmark in
            FolderHierarchy.findParent(of: bookmark, in: Array(registeredPaths)) == nil
        }
    }

    // MARK: - 文件夹健康检查

    /// 轻量级文件夹可用性检查
    ///
    /// 仅检查 `FileManager.fileExists`（单次 stat() 调用），
    /// 当检测到状态变化时触发完整 `reloadFolders()`。
    func checkFolderHealth() {
        var changed = false
        for folder in folders {
            let exists = FileManager.default.fileExists(atPath: folder.folderPath)
            if exists != folder.isAvailable {
                changed = true
                break
            }
        }
        if changed {
            try? reloadFolders()
        }
    }

    /// 启动周期性文件夹健康检查
    ///
    /// 每 30 秒验证所有注册文件夹的可达性。
    /// 仅在检测到变化时才执行完整刷新（避免无谓的数据库查询和 UI 重绘）。
    /// 在 ContentView 的 `.task` 中调用，Task 取消时自动退出。
    func startPeriodicHealthCheck() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            checkFolderHealth()
        }
    }

    // MARK: - 书签持久化

    private func loadBookmarks() {
        subfolderBookmarks = UserDefaults.standard.stringArray(forKey: Self.bookmarksKey) ?? []
    }

    private func persistBookmarks() {
        UserDefaults.standard.set(subfolderBookmarks, forKey: Self.bookmarksKey)
    }
}
