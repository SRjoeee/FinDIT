import XCTest
@testable import FindItCore
import GRDB

final class VolumeResolverTests: XCTestCase {

    // MARK: - resolve()

    func testResolveLocalPath_returnsNonNilName() {
        // 本机路径一定有卷名
        let info = VolumeResolver.resolve(path: "/")
        XCTAssertNotNil(info.name, "根卷应有名称")
    }

    func testResolveLocalPath_isInternal() {
        let info = VolumeResolver.resolve(path: "/")
        XCTAssertTrue(info.isInternal, "根卷应标记为内置")
        XCTAssertFalse(info.isRemovable, "根卷不应标记为可移除")
    }

    func testResolveNonexistentPath_returnsDefaults() {
        let info = VolumeResolver.resolve(path: "/nonexistent/path/abc123")
        // 不存在的路径返回默认值
        XCTAssertNil(info.uuid)
        XCTAssertNil(info.name)
        XCTAssertFalse(info.isRemovable)
        XCTAssertTrue(info.isInternal)
    }

    func testResolveHomePath_returnsVolumeInfo() {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let info = VolumeResolver.resolve(path: homePath)
        XCTAssertNotNil(info.name, "用户目录应在有名称的卷上")
    }

    // MARK: - isAccessible()

    func testIsAccessible_existingPath() {
        XCTAssertTrue(VolumeResolver.isAccessible(path: "/"))
        XCTAssertTrue(VolumeResolver.isAccessible(path: "/tmp"))
    }

    func testIsAccessible_nonexistentPath() {
        XCTAssertFalse(VolumeResolver.isAccessible(path: "/nonexistent/path/xyz"))
    }

    // MARK: - findMountPoint()

    func testFindMountPoint_emptyUUID_returnsNil() {
        XCTAssertNil(VolumeResolver.findMountPoint(forVolumeUUID: ""))
    }

    func testFindMountPoint_fakeUUID_returnsNil() {
        XCTAssertNil(VolumeResolver.findMountPoint(forVolumeUUID: "FAKE-UUID-0000-0000"))
    }

    func testFindMountPoint_rootVolumeUUID_returnsPath() {
        // 获取根卷 UUID 后再查找
        let rootInfo = VolumeResolver.resolve(path: "/")
        guard let uuid = rootInfo.uuid else {
            // 某些 macOS 环境根卷可能无 UUID（如 CI），跳过
            return
        }

        let mountPoint = VolumeResolver.findMountPoint(forVolumeUUID: uuid)
        XCTAssertNotNil(mountPoint, "根卷 UUID 应能找到挂载点")
    }

    // MARK: - resolveUpdatedPath()

    func testResolveUpdatedPath_fakeUUID_returnsNil() {
        let result = VolumeResolver.resolveUpdatedPath(
            oldPath: "/Volumes/OldDisk/videos",
            volumeUUID: "FAKE-UUID"
        )
        XCTAssertNil(result)
    }

    // MARK: - mountedVolumePaths()

    func testMountedVolumePaths_includesRoot() {
        let paths = VolumeResolver.mountedVolumePaths()
        XCTAssertFalse(paths.isEmpty, "至少应有根卷")
        XCTAssertTrue(paths.contains("/"), "应包含根卷挂载点")
    }

    // MARK: - VolumeInfo Equatable

    func testVolumeInfoEquatable() {
        let a = VolumeResolver.VolumeInfo(uuid: "A", name: "Disk", isRemovable: true, isInternal: false)
        let b = VolumeResolver.VolumeInfo(uuid: "A", name: "Disk", isRemovable: true, isInternal: false)
        let c = VolumeResolver.VolumeInfo(uuid: "B", name: "Disk", isRemovable: true, isInternal: false)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}

// MARK: - FolderStats Tests

final class FolderStatsTests: XCTestCase {

    func testFolderStats_emptyDatabase() throws {
        let db = try DatabaseManager.makeGlobalInMemoryDatabase()

        let stats = try db.read { db in
            try SearchEngine.folderStats(db, folderPath: "/some/folder")
        }

        XCTAssertEqual(stats.videoCount, 0)
        XCTAssertEqual(stats.clipCount, 0)
    }

    func testFolderStats_withData() throws {
        let db = try DatabaseManager.makeGlobalInMemoryDatabase()

        // 插入测试数据
        try db.write { db in
            // 插入两个视频
            try db.execute(sql: """
                INSERT INTO videos (source_folder, source_video_id, file_path, file_name)
                VALUES (?, ?, ?, ?)
                """, arguments: ["/folder/a", 1, "/folder/a/v1.mp4", "v1.mp4"])

            try db.execute(sql: """
                INSERT INTO videos (source_folder, source_video_id, file_path, file_name)
                VALUES (?, ?, ?, ?)
                """, arguments: ["/folder/a", 2, "/folder/a/v2.mp4", "v2.mp4"])

            let v1Id = db.lastInsertedRowID - 1
            let v2Id = db.lastInsertedRowID

            // 插入三个 clip（v1 两个，v2 一个）
            try db.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, video_id, start_time, end_time)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: ["/folder/a", 1, v1Id, 0.0, 5.0])

            try db.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, video_id, start_time, end_time)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: ["/folder/a", 2, v1Id, 5.0, 10.0])

            try db.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, video_id, start_time, end_time)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: ["/folder/a", 3, v2Id, 0.0, 8.0])
        }

        let stats = try db.read { db in
            try SearchEngine.folderStats(db, folderPath: "/folder/a")
        }

        XCTAssertEqual(stats.videoCount, 2, "应有 2 个视频")
        XCTAssertEqual(stats.clipCount, 3, "应有 3 个片段")
    }

    func testFolderStats_multipleFolder_isolation() throws {
        let db = try DatabaseManager.makeGlobalInMemoryDatabase()

        try db.write { db in
            // 文件夹 A: 1 视频 2 clips
            try db.execute(sql: """
                INSERT INTO videos (source_folder, source_video_id, file_path, file_name)
                VALUES (?, ?, ?, ?)
                """, arguments: ["/folder/a", 1, "/folder/a/v1.mp4", "v1.mp4"])
            let vId = db.lastInsertedRowID

            try db.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, video_id, start_time, end_time)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: ["/folder/a", 1, vId, 0.0, 5.0])
            try db.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, video_id, start_time, end_time)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: ["/folder/a", 2, vId, 5.0, 10.0])

            // 文件夹 B: 1 视频 1 clip
            try db.execute(sql: """
                INSERT INTO videos (source_folder, source_video_id, file_path, file_name)
                VALUES (?, ?, ?, ?)
                """, arguments: ["/folder/b", 1, "/folder/b/v1.mp4", "v1.mp4"])
            let vIdB = db.lastInsertedRowID

            try db.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, video_id, start_time, end_time)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: ["/folder/b", 1, vIdB, 0.0, 3.0])
        }

        let statsA = try db.read { db in
            try SearchEngine.folderStats(db, folderPath: "/folder/a")
        }
        let statsB = try db.read { db in
            try SearchEngine.folderStats(db, folderPath: "/folder/b")
        }

        XCTAssertEqual(statsA.videoCount, 1)
        XCTAssertEqual(statsA.clipCount, 2)
        XCTAssertEqual(statsB.videoCount, 1)
        XCTAssertEqual(statsB.clipCount, 1)
    }
}
