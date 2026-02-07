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

        // 在后台线程执行数据库操作
        try await Task.detached(priority: .userInitiated) {
            let folderDB = try DatabaseManager.openFolderDatabase(at: path)

            try folderDB.write { db in
                let existing = try WatchedFolder.fetchOne(db, sql:
                    "SELECT * FROM watched_folders WHERE folder_path = ?",
                    arguments: [path])
                if existing == nil {
                    var folder = WatchedFolder(folderPath: path)
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
    /// 刷新 `folders` 数组。IndexingManager 索引完成后也需调用此方法
    /// 以反映新同步的数据。
    func reloadFolders() throws {
        guard let globalDB = globalDB else { return }

        // 从 sync_meta 获取所有已同步的文件夹路径
        let rows = try globalDB.read { db in
            try Row.fetchAll(db, sql: "SELECT folder_path FROM sync_meta ORDER BY folder_path")
        }

        self.folders = rows.map { row in
            let path: String = row["folder_path"]
            let isAvailable = FileManager.default.fileExists(atPath: path)
            return WatchedFolder(
                folderPath: path,
                isAvailable: isAvailable
            )
        }
    }
}
