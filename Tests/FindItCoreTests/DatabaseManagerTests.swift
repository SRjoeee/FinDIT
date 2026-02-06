import XCTest
import GRDB
@testable import FindItCore

final class DatabaseManagerTests: XCTestCase {

    // MARK: - 内存数据库

    func testInMemoryDatabaseCreation() throws {
        // Arrange & Act
        let db = try DatabaseManager.makeInMemoryDatabase()

        // Assert: 可以执行基本 SQL
        let result = try db.read { db in
            try Int.fetchOne(db, sql: "SELECT 1")
        }
        XCTAssertEqual(result, 1)
    }

    func testInMemoryDatabaseForeignKeysEnabled() throws {
        // Arrange
        let db = try DatabaseManager.makeInMemoryDatabase()

        // Act: 检查 foreign_keys pragma
        let fkEnabled = try db.read { db in
            try Bool.fetchOne(db, sql: "PRAGMA foreign_keys")
        }

        // Assert
        XCTAssertEqual(fkEnabled, true, "外键约束应已开启")
    }

    // MARK: - 文件夹级数据库

    func testFolderDatabaseCreation() throws {
        // Arrange: 创建临时目录模拟素材文件夹
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FindItTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Act
        let pool = try DatabaseManager.openFolderDatabase(at: tempDir.path)

        // Assert: 数据库文件存在
        let dbPath = tempDir
            .appendingPathComponent(".clip-index", isDirectory: true)
            .appendingPathComponent("index.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath.path),
                      ".clip-index/index.sqlite 应已创建")

        // Assert: WAL 模式
        let journalMode = try pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        XCTAssertEqual(journalMode, "wal", "应使用 WAL 模式")

        // Assert: 外键约束
        let fkEnabled = try pool.read { db in
            try Bool.fetchOne(db, sql: "PRAGMA foreign_keys")
        }
        XCTAssertEqual(fkEnabled, true, "外键约束应已开启")
    }

    func testFolderDatabaseFailsForNonexistentPath() {
        // Arrange
        let fakePath = "/tmp/FindItTest-nonexistent-\(UUID().uuidString)"

        // Act & Assert
        do {
            _ = try DatabaseManager.openFolderDatabase(at: fakePath)
            XCTFail("应抛出错误")
        } catch let error as StorageError {
            if case .folderNotAccessible(let path) = error {
                XCTAssertEqual(path, fakePath)
            } else {
                XCTFail("应抛出 folderNotAccessible 错误，实际: \(error)")
            }
        } catch {
            XCTFail("应抛出 StorageError，实际: \(error)")
        }
    }

    // MARK: - 全局数据库

    func testGlobalDatabaseCreation() throws {
        // Act
        let pool = try DatabaseManager.openGlobalDatabase()

        // Assert: WAL 模式
        let journalMode = try pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        XCTAssertEqual(journalMode, "wal", "应使用 WAL 模式")

        // Assert: 可以执行基本查询
        let result = try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT 1")
        }
        XCTAssertEqual(result, 1)
    }
}
