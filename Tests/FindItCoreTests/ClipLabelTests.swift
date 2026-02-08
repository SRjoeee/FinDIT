import XCTest
import GRDB
@testable import FindItCore

final class ClipLabelTests: XCTestCase {

    // MARK: - 辅助

    /// 创建一个带测试 clip 的内存文件夹数据库
    private func makeDBWithClip(
        rating: Int = 0,
        colorLabel: String? = nil
    ) throws -> (DatabaseQueue, Int64) {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()
        var clipId: Int64 = 0

        try db.write { conn in
            try conn.execute(sql: """
                INSERT INTO watched_folders (folder_path) VALUES ('/test')
                """)
            try conn.execute(sql: """
                INSERT INTO videos (folder_id, file_path, file_name, index_status)
                VALUES (1, '/test/v.mp4', 'v.mp4', 'completed')
                """)
            try conn.execute(sql: """
                INSERT INTO clips (video_id, start_time, end_time, rating, color_label, created_at)
                VALUES (1, 0.0, 5.0, ?, ?, datetime('now'))
                """, arguments: [rating, colorLabel])
            clipId = conn.lastInsertedRowID
        }

        return (db, clipId)
    }

    private func makeGlobalDB() throws -> DatabaseQueue {
        let db = try DatabaseQueue(path: ":memory:")
        let migrator = Migrations.globalMigrator()
        try migrator.migrate(db)
        return db
    }

    // MARK: - ColorLabel

    func testColorLabelAllCases() {
        XCTAssertEqual(ColorLabel.allCases.count, 7)
        XCTAssertEqual(ColorLabel.red.rawValue, "red")
        XCTAssertEqual(ColorLabel.gray.rawValue, "gray")
    }

    func testColorLabelDisplayName() {
        XCTAssertEqual(ColorLabel.red.displayName, "红色")
        XCTAssertEqual(ColorLabel.orange.displayName, "橙色")
        XCTAssertEqual(ColorLabel.yellow.displayName, "黄色")
        XCTAssertEqual(ColorLabel.green.displayName, "绿色")
        XCTAssertEqual(ColorLabel.blue.displayName, "蓝色")
        XCTAssertEqual(ColorLabel.purple.displayName, "紫色")
        XCTAssertEqual(ColorLabel.gray.displayName, "灰色")
    }

    func testColorLabelRGB() {
        let rgb = ColorLabel.red.rgb
        XCTAssertEqual(rgb.r, 0.94, accuracy: 0.01)
        XCTAssertEqual(rgb.g, 0.27, accuracy: 0.01)
        XCTAssertEqual(rgb.b, 0.27, accuracy: 0.01)
    }

    func testColorLabelCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let original = ColorLabel.blue
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ColorLabel.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - finderLabelNumber

    func testFinderLabelNumberMapping() {
        XCTAssertEqual(ColorLabel.red.finderLabelNumber, 6)
        XCTAssertEqual(ColorLabel.orange.finderLabelNumber, 7)
        XCTAssertEqual(ColorLabel.yellow.finderLabelNumber, 5)
        XCTAssertEqual(ColorLabel.green.finderLabelNumber, 2)
        XCTAssertEqual(ColorLabel.blue.finderLabelNumber, 4)
        XCTAssertEqual(ColorLabel.purple.finderLabelNumber, 3)
        XCTAssertEqual(ColorLabel.gray.finderLabelNumber, 1)
    }

    func testFinderLabelNumberAllUnique() {
        let numbers = ColorLabel.allCases.map(\.finderLabelNumber)
        XCTAssertEqual(Set(numbers).count, 7, "所有 Finder 标签编号应唯一")
        // 所有编号应在 1-7 范围内
        for num in numbers {
            XCTAssertTrue((1...7).contains(num), "\(num) 应在 1-7 范围内")
        }
    }

    func testFinderTagName() {
        XCTAssertEqual(ColorLabel.red.finderTagName, "Red")
        XCTAssertEqual(ColorLabel.orange.finderTagName, "Orange")
        XCTAssertEqual(ColorLabel.yellow.finderTagName, "Yellow")
        XCTAssertEqual(ColorLabel.green.finderTagName, "Green")
        XCTAssertEqual(ColorLabel.blue.finderTagName, "Blue")
        XCTAssertEqual(ColorLabel.purple.finderTagName, "Purple")
        XCTAssertEqual(ColorLabel.gray.finderTagName, "Gray")
    }

    // MARK: - syncFinderTag

    /// 用 NSURL 直接读取资源值（绕过 URL struct 缓存）
    private func readFinderLabel(_ path: String) throws -> (labelNumber: Int, tagNames: [String]) {
        let nsurl = URL(fileURLWithPath: path) as NSURL
        var labelValue: AnyObject?
        try nsurl.getResourceValue(&labelValue, forKey: .labelNumberKey)
        var tagValue: AnyObject?
        try nsurl.getResourceValue(&tagValue, forKey: .tagNamesKey)
        return (
            labelNumber: (labelValue as? NSNumber)?.intValue ?? 0,
            tagNames: (tagValue as? [String]) ?? []
        )
    }

    func testSyncFinderTagSetsLabelAndTag() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FindItTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("test.mp4")
        FileManager.default.createFile(atPath: file.path, contents: Data("test".utf8))

        try ClipLabel.syncFinderTag(filePath: file.path, label: .red)

        let result = try readFinderLabel(file.path)
        XCTAssertEqual(result.labelNumber, 6, "应设置 Red 的 Finder 标签编号 6")
        XCTAssertTrue(result.tagNames.contains("Red"), "应包含 Red 标签名")
    }

    func testSyncFinderTagClearsLabel() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FindItTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("test.mp4")
        FileManager.default.createFile(atPath: file.path, contents: Data("test".utf8))

        // 先设置，再清除
        try ClipLabel.syncFinderTag(filePath: file.path, label: .blue)
        try ClipLabel.syncFinderTag(filePath: file.path, label: nil)

        let result = try readFinderLabel(file.path)
        XCTAssertEqual(result.labelNumber, 0, "清除后 labelNumber 应为 0")
        let colorNames = Set(ColorLabel.allCases.map(\.finderTagName))
        let remaining = result.tagNames.filter { colorNames.contains($0) }
        XCTAssertTrue(remaining.isEmpty, "清除后不应有颜色标签名")
    }

    func testSyncFinderTagPreservesNonColorTags() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FindItTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("test.mp4")
        FileManager.default.createFile(atPath: file.path, contents: Data("test".utf8))

        // 预设自定义标签
        try (file as NSURL).setResourceValue(["B-roll", "Interview"], forKey: .tagNamesKey)

        try ClipLabel.syncFinderTag(filePath: file.path, label: .green)

        let result = try readFinderLabel(file.path)
        XCTAssertTrue(result.tagNames.contains("B-roll"), "应保留非颜色标签 B-roll")
        XCTAssertTrue(result.tagNames.contains("Interview"), "应保留非颜色标签 Interview")
        XCTAssertTrue(result.tagNames.contains("Green"), "应添加颜色标签 Green")
    }

    func testSyncFinderTagReplacesColorTag() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FindItTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("test.mp4")
        FileManager.default.createFile(atPath: file.path, contents: Data("test".utf8))

        try ClipLabel.syncFinderTag(filePath: file.path, label: .red)
        try ClipLabel.syncFinderTag(filePath: file.path, label: .blue)

        let result = try readFinderLabel(file.path)
        XCTAssertFalse(result.tagNames.contains("Red"), "旧颜色标签 Red 应被移除")
        XCTAssertTrue(result.tagNames.contains("Blue"), "新颜色标签 Blue 应存在")
    }

    // MARK: - effectiveVideoColor

    func testEffectiveVideoColorReturnsLatest() throws {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()

        try db.write { conn in
            try conn.execute(sql: "INSERT INTO watched_folders (folder_path) VALUES ('/test')")
            try conn.execute(sql: """
                INSERT INTO videos (folder_id, file_path, file_name) VALUES (1, '/t.mp4', 't.mp4')
                """)
            // clip 1: red
            try conn.execute(sql: """
                INSERT INTO clips (video_id, start_time, end_time, color_label)
                VALUES (1, 0, 5, 'red')
                """)
            // clip 2: blue（最新）
            try conn.execute(sql: """
                INSERT INTO clips (video_id, start_time, end_time, color_label)
                VALUES (1, 5, 10, 'blue')
                """)
        }

        let label = try db.read { conn in
            try ClipLabel.effectiveVideoColor(conn, videoId: 1)
        }
        XCTAssertEqual(label, .blue, "应返回最新设置的颜色")
    }

    func testEffectiveVideoColorReturnsNilWhenAllCleared() throws {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()

        try db.write { conn in
            try conn.execute(sql: "INSERT INTO watched_folders (folder_path) VALUES ('/test')")
            try conn.execute(sql: """
                INSERT INTO videos (folder_id, file_path, file_name) VALUES (1, '/t.mp4', 't.mp4')
                """)
            try conn.execute(sql: """
                INSERT INTO clips (video_id, start_time, end_time, color_label)
                VALUES (1, 0, 5, NULL)
                """)
        }

        let label = try db.read { conn in
            try ClipLabel.effectiveVideoColor(conn, videoId: 1)
        }
        XCTAssertNil(label, "所有片段无颜色时应返回 nil")
    }

    // MARK: - updateRating

    func testUpdateRating() throws {
        let (db, clipId) = try makeDBWithClip()

        try db.write { conn in
            try ClipLabel.updateRating(conn, clipId: clipId, rating: 4)
        }

        let fetched = try db.read { conn in
            try ClipLabel.fetchRating(conn, clipId: clipId)
        }
        XCTAssertEqual(fetched, 4)
    }

    func testUpdateRatingClampsAboveFive() throws {
        let (db, clipId) = try makeDBWithClip()

        try db.write { conn in
            try ClipLabel.updateRating(conn, clipId: clipId, rating: 10)
        }

        let fetched = try db.read { conn in
            try ClipLabel.fetchRating(conn, clipId: clipId)
        }
        XCTAssertEqual(fetched, 5, "评分超过 5 应被钳制为 5")
    }

    func testUpdateRatingClampsBelowZero() throws {
        let (db, clipId) = try makeDBWithClip(rating: 3)

        try db.write { conn in
            try ClipLabel.updateRating(conn, clipId: clipId, rating: -2)
        }

        let fetched = try db.read { conn in
            try ClipLabel.fetchRating(conn, clipId: clipId)
        }
        XCTAssertEqual(fetched, 0, "评分低于 0 应被钳制为 0")
    }

    func testUpdateRatingToZero() throws {
        let (db, clipId) = try makeDBWithClip(rating: 5)

        try db.write { conn in
            try ClipLabel.updateRating(conn, clipId: clipId, rating: 0)
        }

        let fetched = try db.read { conn in
            try ClipLabel.fetchRating(conn, clipId: clipId)
        }
        XCTAssertEqual(fetched, 0, "应能清除评分为 0")
    }

    // MARK: - updateColorLabel

    func testUpdateColorLabel() throws {
        let (db, clipId) = try makeDBWithClip()

        try db.write { conn in
            try ClipLabel.updateColorLabel(conn, clipId: clipId, label: .green)
        }

        let fetched = try db.read { conn in
            try ClipLabel.fetchColorLabel(conn, clipId: clipId)
        }
        XCTAssertEqual(fetched, .green)
    }

    func testUpdateColorLabelToNil() throws {
        let (db, clipId) = try makeDBWithClip(colorLabel: "red")

        try db.write { conn in
            try ClipLabel.updateColorLabel(conn, clipId: clipId, label: nil)
        }

        let fetched = try db.read { conn in
            try ClipLabel.fetchColorLabel(conn, clipId: clipId)
        }
        XCTAssertNil(fetched, "设置 nil 应清除颜色标签")
    }

    func testUpdateColorLabelReplace() throws {
        let (db, clipId) = try makeDBWithClip(colorLabel: "red")

        try db.write { conn in
            try ClipLabel.updateColorLabel(conn, clipId: clipId, label: .blue)
        }

        let fetched = try db.read { conn in
            try ClipLabel.fetchColorLabel(conn, clipId: clipId)
        }
        XCTAssertEqual(fetched, .blue, "应能替换颜色标签")
    }

    // MARK: - fetchRating / fetchColorLabel

    func testFetchRatingDefault() throws {
        let (db, clipId) = try makeDBWithClip()

        let rating = try db.read { conn in
            try ClipLabel.fetchRating(conn, clipId: clipId)
        }
        XCTAssertEqual(rating, 0, "默认评分应为 0")
    }

    func testFetchColorLabelDefault() throws {
        let (db, clipId) = try makeDBWithClip()

        let label = try db.read { conn in
            try ClipLabel.fetchColorLabel(conn, clipId: clipId)
        }
        XCTAssertNil(label, "默认颜色标签应为 nil")
    }

    func testFetchRatingNonexistentClip() throws {
        let (db, _) = try makeDBWithClip()

        let rating = try db.read { conn in
            try ClipLabel.fetchRating(conn, clipId: 999)
        }
        XCTAssertEqual(rating, 0, "不存在的 clip 应返回 0")
    }

    func testFetchColorLabelNonexistentClip() throws {
        let (db, _) = try makeDBWithClip()

        let label = try db.read { conn in
            try ClipLabel.fetchColorLabel(conn, clipId: 999)
        }
        XCTAssertNil(label, "不存在的 clip 应返回 nil")
    }

    // MARK: - Migration

    func testFolderMigrationV8RatingColorLabel() throws {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()

        // 验证 rating 和 color_label 列存在且有默认值
        try db.write { conn in
            try conn.execute(sql: """
                INSERT INTO watched_folders (folder_path) VALUES ('/test')
                """)
            try conn.execute(sql: """
                INSERT INTO videos (folder_id, file_path, file_name) VALUES (1, '/t.mp4', 't.mp4')
                """)
            try conn.execute(sql: """
                INSERT INTO clips (video_id, start_time, end_time) VALUES (1, 0, 5)
                """)
        }

        let row = try db.read { conn in
            try Row.fetchOne(conn, sql: "SELECT rating, color_label FROM clips WHERE clip_id = 1")
        }
        XCTAssertEqual(row?["rating"] as Int?, 0, "rating 默认应为 0")
        XCTAssertNil(row?["color_label"] as String?, "color_label 默认应为 nil")
    }

    func testFolderMigrationV8Indexes() throws {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()

        let indexes = try db.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT name FROM sqlite_master WHERE type = 'index'
                AND (name = 'idx_clips_rating' OR name = 'idx_clips_color_label')
                """)
        }
        let names = Set(indexes.map { $0["name"] as String })
        XCTAssertTrue(names.contains("idx_clips_rating"), "应创建 rating 索引")
        XCTAssertTrue(names.contains("idx_clips_color_label"), "应创建 color_label 索引")
    }

    func testGlobalMigrationV7RatingColorLabel() throws {
        let db = try makeGlobalDB()

        try db.write { conn in
            try conn.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, start_time, end_time, rating, color_label)
                VALUES ('/test', 1, 0.0, 5.0, 3, 'blue')
                """)
        }

        let row = try db.read { conn in
            try Row.fetchOne(conn, sql: "SELECT rating, color_label FROM clips WHERE source_clip_id = 1")
        }
        XCTAssertEqual(row?["rating"] as Int?, 3)
        XCTAssertEqual(row?["color_label"] as String?, "blue")
    }

    // MARK: - SyncEngine 传播

    func testSyncEngineCarriesRatingAndColorLabel() throws {
        let folderDB = try DatabaseManager.makeFolderInMemoryDatabase()
        let globalDB = try makeGlobalDB()

        try folderDB.write { db in
            try db.execute(sql: "INSERT INTO watched_folders (folder_path) VALUES ('/test')")
            try db.execute(sql: """
                INSERT INTO videos (folder_id, file_path, file_name, index_status)
                VALUES (1, '/test/v.mp4', 'v.mp4', 'completed')
                """)
            try db.execute(sql: """
                INSERT INTO clips (video_id, start_time, end_time, rating, color_label)
                VALUES (1, 0.0, 5.0, 4, 'red')
                """)
        }

        let result = try SyncEngine.sync(folderPath: "/test", folderDB: folderDB, globalDB: globalDB)
        XCTAssertEqual(result.syncedClips, 1)

        let row = try globalDB.read { db in
            try Row.fetchOne(db, sql: "SELECT rating, color_label FROM clips WHERE source_clip_id = 1")
        }
        XCTAssertEqual(row?["rating"] as Int?, 4)
        XCTAssertEqual(row?["color_label"] as String?, "red")
    }

    // MARK: - Clip Model

    func testClipModelRatingColorLabel() throws {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()

        try db.write { conn in
            try conn.execute(sql: "INSERT INTO watched_folders (folder_path) VALUES ('/test')")
            try conn.execute(sql: """
                INSERT INTO videos (folder_id, file_path, file_name) VALUES (1, '/t.mp4', 't.mp4')
                """)
            var clip = Clip(videoId: 1, startTime: 0, endTime: 5, rating: 3, colorLabel: "green")
            try clip.insert(conn)
        }

        let fetched = try db.read { conn in
            try Clip.fetchOne(conn)
        }
        XCTAssertEqual(fetched?.rating, 3)
        XCTAssertEqual(fetched?.colorLabel, "green")
    }
}
