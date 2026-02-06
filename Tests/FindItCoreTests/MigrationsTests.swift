import XCTest
import GRDB
@testable import FindItCore

final class MigrationsTests: XCTestCase {

    // MARK: - 文件夹级库迁移

    func testFolderMigrationCreatesTables() throws {
        // Arrange & Act
        let db = try DatabaseManager.makeFolderInMemoryDatabase()

        // Assert: 三张表存在
        let tables = try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
                ORDER BY name
                """)
        }
        XCTAssertEqual(tables, ["clips", "videos", "watched_folders"])
    }

    func testFolderMigrationWatchedFoldersColumns() throws {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()

        let columns = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(watched_folders)")
        }.map { $0["name"] as String }

        let expected = ["folder_id", "folder_path", "volume_name", "volume_uuid",
                        "is_available", "last_seen_at", "total_files", "indexed_files"]
        for col in expected {
            XCTAssertTrue(columns.contains(col), "watched_folders 应包含列 \(col)")
        }
    }

    func testFolderMigrationVideosColumns() throws {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()

        let columns = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(videos)")
        }.map { $0["name"] as String }

        let expected = ["video_id", "folder_id", "file_path", "file_name", "duration",
                        "file_size", "file_hash", "file_modified", "created_at", "indexed_at",
                        "index_status", "index_error", "orphaned_at", "priority",
                        "last_processed_clip", "srt_path"]
        for col in expected {
            XCTAssertTrue(columns.contains(col), "videos 应包含列 \(col)")
        }
    }

    func testFolderMigrationClipsColumns() throws {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()

        let columns = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(clips)")
        }.map { $0["name"] as String }

        let expected = ["clip_id", "video_id", "start_time", "end_time", "thumbnail_path",
                        "scene", "subjects", "actions", "objects", "mood", "shot_type",
                        "lighting", "colors", "description", "tags", "transcript",
                        "embedding", "created_at"]
        for col in expected {
            XCTAssertTrue(columns.contains(col), "clips 应包含列 \(col)")
        }
    }

    // MARK: - 全局搜索索引迁移

    func testGlobalMigrationCreatesTables() throws {
        let db = try DatabaseManager.makeGlobalInMemoryDatabase()

        let tables = try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
                ORDER BY name
                """)
        }

        // clips, clips_fts 相关内部表, search_history, sync_meta, videos
        XCTAssertTrue(tables.contains("clips"), "应包含 clips 表")
        XCTAssertTrue(tables.contains("videos"), "应包含 videos 表")
        XCTAssertTrue(tables.contains("search_history"), "应包含 search_history 表")
        XCTAssertTrue(tables.contains("sync_meta"), "应包含 sync_meta 表")
    }

    func testGlobalMigrationFTS5Exists() throws {
        let db = try DatabaseManager.makeGlobalInMemoryDatabase()

        // FTS5 虚拟表在 sqlite_master 中 type='table'
        let ftsExists = try db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master
                WHERE type='table' AND name='clips_fts'
                """)
        }
        XCTAssertEqual(ftsExists, 1, "clips_fts 虚拟表应存在")
    }

    func testGlobalMigrationClipsHasSourceColumns() throws {
        let db = try DatabaseManager.makeGlobalInMemoryDatabase()

        let columns = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(clips)")
        }.map { $0["name"] as String }

        XCTAssertTrue(columns.contains("source_folder"), "全局 clips 应包含 source_folder")
        XCTAssertTrue(columns.contains("source_clip_id"), "全局 clips 应包含 source_clip_id")
    }

    func testGlobalMigrationSyncMetaColumns() throws {
        let db = try DatabaseManager.makeGlobalInMemoryDatabase()

        let columns = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(sync_meta)")
        }.map { $0["name"] as String }

        let expected = ["folder_path", "last_synced_clip_rowid",
                        "last_synced_video_rowid", "last_synced_at"]
        for col in expected {
            XCTAssertTrue(columns.contains(col), "sync_meta 应包含列 \(col)")
        }
    }
}
