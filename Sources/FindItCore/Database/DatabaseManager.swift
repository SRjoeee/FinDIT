import Foundation
import GRDB

/// 数据库相关错误
public enum StorageError: LocalizedError {
    /// 文件夹路径不存在或不可访问
    case folderNotAccessible(String)
    /// 无法创建 .clip-index 目录
    case cannotCreateIndexDirectory(String)
    /// 数据库打开失败
    case openFailed(underlying: Error)
    /// 无法获取 Application Support 目录
    case appSupportNotFound

    public var errorDescription: String? {
        switch self {
        case .folderNotAccessible(let path):
            return "文件夹不可访问: \(path)"
        case .cannotCreateIndexDirectory(let path):
            return "无法创建索引目录: \(path)"
        case .openFailed(let error):
            return "数据库打开失败: \(error.localizedDescription)"
        case .appSupportNotFound:
            return "无法获取 Application Support 目录"
        }
    }
}

/// 数据库连接管理器
///
/// 负责创建和管理文件夹级 SQLite 和全局搜索索引的连接。
/// 所有数据库均使用 WAL 模式以支持并发读写。
public final class DatabaseManager {

    /// 文件夹级索引数据库的子目录名
    static let indexDirectoryName = ".clip-index"
    /// 文件夹级索引数据库的文件名
    static let indexFileName = "index.sqlite"
    /// 全局搜索索引的文件名
    static let globalFileName = "search.sqlite"

    /// App 的 Application Support 目录
    private static func appSupportDirectory() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StorageError.appSupportNotFound
        }
        return base.appendingPathComponent("FindIt", isDirectory: true)
    }

    // MARK: - 文件夹级数据库

    /// 打开（或创建）指定素材文件夹的索引数据库
    ///
    /// 数据库位于 `<folderPath>/.clip-index/index.sqlite`。
    /// 目录不存在时自动创建。
    ///
    /// - Parameter folderPath: 素材文件夹的绝对路径
    /// - Returns: 配置好 WAL 模式的数据库连接池
    public static func openFolderDatabase(at folderPath: String) throws -> DatabasePool {
        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)

        // 检查文件夹是否存在
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw StorageError.folderNotAccessible(folderPath)
        }

        // 创建 .clip-index 子目录
        let indexDir = folderURL.appendingPathComponent(indexDirectoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
        } catch {
            throw StorageError.cannotCreateIndexDirectory(indexDir.path)
        }

        let dbPath = indexDir.appendingPathComponent(indexFileName).path
        let pool = try openPool(at: dbPath)
        try Migrations.folderMigrator().migrate(pool)
        return pool
    }

    // MARK: - 全局搜索索引

    /// 打开（或创建）全局搜索索引数据库
    ///
    /// 数据库位于 `~/Library/Application Support/FindIt/search.sqlite`。
    /// 目录不存在时自动创建。自动执行全局库迁移。
    ///
    /// - Returns: 配置好 WAL 模式的数据库连接池
    public static func openGlobalDatabase() throws -> DatabasePool {
        let dir = try appSupportDirectory()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw StorageError.cannotCreateIndexDirectory(dir.path)
        }

        let dbPath = dir.appendingPathComponent(globalFileName).path
        let pool = try openPool(at: dbPath)
        try Migrations.globalMigrator().migrate(pool)
        return pool
    }

    // MARK: - 内存数据库（测试用）

    /// 创建文件夹级库的内存数据库（含迁移），用于单元测试
    public static func makeFolderInMemoryDatabase() throws -> DatabaseQueue {
        let db = try makeRawInMemoryDatabase()
        try Migrations.folderMigrator().migrate(db)
        return db
    }

    /// 创建全局库的内存数据库（含迁移），用于单元测试
    public static func makeGlobalInMemoryDatabase() throws -> DatabaseQueue {
        let db = try makeRawInMemoryDatabase()
        try Migrations.globalMigrator().migrate(db)
        return db
    }

    /// 创建无迁移的裸内存数据库
    public static func makeRawInMemoryDatabase() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try DatabaseQueue(configuration: config)
    }

    // MARK: - Private

    /// 以 WAL 模式打开 DatabasePool
    private static func openPool(at path: String) throws -> DatabasePool {
        do {
            var config = Configuration()
            config.foreignKeysEnabled = true
            // GRDB 的 DatabasePool 默认使用 WAL 模式
            let pool = try DatabasePool(path: path, configuration: config)
            return pool
        } catch {
            throw StorageError.openFailed(underlying: error)
        }
    }
}
