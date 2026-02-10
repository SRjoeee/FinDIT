import Foundation
import GRDB
import FindItCore

/// MCP Server 的数据库连接管理
///
/// 管理全局搜索索引和按需打开的文件夹级数据库。
/// GRDB DatabasePool 本身线程安全，无需额外同步。
final class DatabaseContext: Sendable {

    /// 全局搜索索引（FTS5 + 向量）
    let globalDB: DatabasePool

    /// 文件夹库缓存（folderPath → DatabasePool）
    private let folderDBCache = Mutex<[String: DatabasePool]>([:])

    init() throws {
        self.globalDB = try DatabaseManager.openGlobalDatabase()
    }

    /// 获取文件夹级数据库（按需打开 + 缓存）
    func folderDB(for folderPath: String) throws -> DatabasePool {
        return try folderDBCache.withLock { cache in
            if let existing = cache[folderPath] {
                return existing
            }
            let db = try DatabaseManager.openFolderDatabase(at: folderPath)
            cache[folderPath] = db
            return db
        }
    }
}

/// 简单互斥锁封装
///
/// 用于保护文件夹库缓存的线程安全访问。
private final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
