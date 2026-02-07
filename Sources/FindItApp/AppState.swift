import Foundation
import GRDB
import FindItCore

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

    /// 数据库是否已初始化
    var isInitialized = false

    /// 初始化错误信息
    var initError: String?

    /// IndexingManager 引用（由 ContentView 注入）
    weak var indexingManager: IndexingManager?

    /// 卷信息缓存（避免每次 reloadFolders 都做文件系统调用）
    private var volumeInfoCache: [String: VolumeResolver.VolumeInfo] = [:]

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
            try reloadFolders()
            self.isInitialized = true
        } catch {
            self.initError = error.localizedDescription
        }
    }

    // MARK: - 文件夹管理

    /// 添加监控文件夹
    ///
    /// 打开文件夹级数据库，同步到全局库，刷新文件夹列表。
    /// 数据库操作在后台线程执行，避免阻塞主线程。
    func addFolder(path: String) async throws {
        guard let globalDB = globalDB else { return }

        // 检查是否已存在
        let exists = folders.contains { $0.folderPath == path }
        guard !exists else { return }

        // 解析卷信息并缓存
        let volumeInfo = VolumeResolver.resolve(path: path)
        volumeInfoCache[path] = volumeInfo

        // 在后台线程执行数据库操作
        try await Task.detached(priority: .userInitiated) {
            let folderDB = try DatabaseManager.openFolderDatabase(at: path)

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
                }
            }

            let _ = try SyncEngine.sync(
                folderPath: path,
                folderDB: folderDB,
                globalDB: globalDB
            )
        }.value

        try reloadFolders()

        // 触发后台索引
        indexingManager?.queueFolder(path)
    }

    /// 移除文件夹
    func removeFolder(path: String) throws {
        guard let globalDB = globalDB else { return }

        try SyncEngine.removeFolderData(folderPath: path, from: globalDB)
        try reloadFolders()
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
                if let newPath = VolumeResolver.resolveUpdatedPath(oldPath: path, volumeUUID: uuid) {
                    // 挂载点变更：路径变了但卷还在
                    // 注意：实际路径更新需要同步到数据库，这里暂只用于可用性判断
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
    }
}
