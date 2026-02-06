import XCTest
import GRDB
@testable import FindItCore

final class ModelsTests: XCTestCase {

    // MARK: - WatchedFolder

    func testWatchedFolderInsertAndFetch() throws {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()

        var folder = WatchedFolder(folderPath: "/Volumes/SSD/素材")
        try db.write { db in
            try folder.insert(db)
        }

        // didInsert 应回写主键
        XCTAssertNotNil(folder.folderId)

        // 读取验证
        let fetched = try db.read { db in
            try WatchedFolder.fetchOne(db, key: folder.folderId)
        }
        XCTAssertEqual(fetched?.folderPath, "/Volumes/SSD/素材")
        XCTAssertEqual(fetched?.isAvailable, true)
        XCTAssertEqual(fetched?.totalFiles, 0)
        XCTAssertEqual(fetched?.indexedFiles, 0)
    }

    func testWatchedFolderWithAllFields() throws {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()

        var folder = WatchedFolder(
            folderPath: "/Volumes/外接盘/项目A",
            volumeName: "外接盘",
            volumeUuid: "ABC-123",
            isAvailable: false,
            lastSeenAt: "2025-01-15 10:00:00",
            totalFiles: 42,
            indexedFiles: 10
        )
        try db.write { db in
            try folder.insert(db)
        }

        let fetched = try db.read { db in
            try WatchedFolder.fetchOne(db, key: folder.folderId)
        }
        XCTAssertEqual(fetched?.volumeName, "外接盘")
        XCTAssertEqual(fetched?.volumeUuid, "ABC-123")
        XCTAssertEqual(fetched?.isAvailable, false)
        XCTAssertEqual(fetched?.totalFiles, 42)
        XCTAssertEqual(fetched?.indexedFiles, 10)
    }

    // MARK: - Video

    func testVideoInsertAndFetch() throws {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()

        // 先插入 folder（外键依赖）
        var folder = WatchedFolder(folderPath: "/test")
        try db.write { db in
            try folder.insert(db)
        }

        var video = Video(
            folderId: folder.folderId,
            filePath: "/test/beach.mp4",
            fileName: "beach.mp4",
            duration: 120.5,
            fileSize: 1_048_576
        )
        try db.write { db in
            try video.insert(db)
        }

        XCTAssertNotNil(video.videoId)

        let fetched = try db.read { db in
            try Video.fetchOne(db, key: video.videoId)
        }
        XCTAssertEqual(fetched?.filePath, "/test/beach.mp4")
        XCTAssertEqual(fetched?.fileName, "beach.mp4")
        XCTAssertEqual(fetched?.duration, 120.5)
        XCTAssertEqual(fetched?.fileSize, 1_048_576)
        XCTAssertEqual(fetched?.indexStatus, "pending")
        XCTAssertEqual(fetched?.priority, 0)
    }

    func testVideoDefaultIndexStatus() throws {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()

        var folder = WatchedFolder(folderPath: "/test")
        try db.write { db in
            try folder.insert(db)
        }

        var video = Video(folderId: folder.folderId, filePath: "/test/v.mp4", fileName: "v.mp4")
        try db.write { db in
            try video.insert(db)
        }

        let fetched = try db.read { db in
            try Video.fetchOne(db, key: video.videoId)
        }
        XCTAssertEqual(fetched?.indexStatus, "pending")
    }

    // MARK: - Clip

    func testClipInsertAndFetch() throws {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()

        var folder = WatchedFolder(folderPath: "/test")
        try db.write { db in try folder.insert(db) }

        var video = Video(folderId: folder.folderId, filePath: "/test/v.mp4", fileName: "v.mp4")
        try db.write { db in try video.insert(db) }

        var clip = Clip(
            videoId: video.videoId,
            startTime: 0.0,
            endTime: 5.5,
            scene: "海滩日落",
            clipDescription: "金色夕阳照射下的沙滩，海浪轻拍岸边"
        )
        try db.write { db in
            try clip.insert(db)
        }

        XCTAssertNotNil(clip.clipId)

        let fetched = try db.read { db in
            try Clip.fetchOne(db, key: clip.clipId)
        }
        XCTAssertEqual(fetched?.startTime, 0.0)
        XCTAssertEqual(fetched?.endTime, 5.5)
        XCTAssertEqual(fetched?.scene, "海滩日落")
        XCTAssertEqual(fetched?.clipDescription, "金色夕阳照射下的沙滩，海浪轻拍岸边")
        XCTAssertNotNil(fetched?.createdAt)
    }

    func testClipTagsJsonRoundTrip() throws {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()

        var folder = WatchedFolder(folderPath: "/test")
        try db.write { db in try folder.insert(db) }

        var video = Video(folderId: folder.folderId, filePath: "/test/v.mp4", fileName: "v.mp4")
        try db.write { db in try video.insert(db) }

        var clip = Clip(videoId: video.videoId, startTime: 0, endTime: 3)
        clip.setTags(["海滩", "户外", "全景", "暖色调"])
        try db.write { db in
            try clip.insert(db)
        }

        let fetched = try db.read { db in
            try Clip.fetchOne(db, key: clip.clipId)
        }!
        XCTAssertEqual(fetched.tagsArray, ["海滩", "户外", "全景", "暖色调"])
    }

    func testClipEmptyTagsArray() throws {
        var clip = Clip(startTime: 0, endTime: 1)
        XCTAssertEqual(clip.tagsArray, [])

        clip.setTags([])
        XCTAssertNil(clip.tags, "空数组应设置 tags 为 nil")
    }

    func testClipEmbeddingBlob() throws {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()

        var folder = WatchedFolder(folderPath: "/test")
        try db.write { db in try folder.insert(db) }

        var video = Video(folderId: folder.folderId, filePath: "/test/v.mp4", fileName: "v.mp4")
        try db.write { db in try video.insert(db) }

        // 模拟一个 4 维 float32 向量（实际使用 1024 维）
        var floats: [Float] = [0.1, 0.2, 0.3, 0.4]
        let data = Data(bytes: &floats, count: floats.count * MemoryLayout<Float>.stride)

        var clip = Clip(videoId: video.videoId, startTime: 0, endTime: 1, embedding: data)
        try db.write { db in
            try clip.insert(db)
        }

        let fetched = try db.read { db in
            try Clip.fetchOne(db, key: clip.clipId)
        }!
        XCTAssertEqual(fetched.embedding, data)
    }

    // MARK: - 外键级联删除

    func testCascadeDeleteFolderRemovesVideos() throws {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()

        var folder = WatchedFolder(folderPath: "/test")
        try db.write { db in try folder.insert(db) }

        var video = Video(folderId: folder.folderId, filePath: "/test/v.mp4", fileName: "v.mp4")
        try db.write { db in try video.insert(db) }

        // 删除 folder
        try db.write { db in
            _ = try WatchedFolder.deleteAll(db)
        }

        let videoCount = try db.read { db in
            try Video.fetchCount(db)
        }
        XCTAssertEqual(videoCount, 0, "删除 folder 应级联删除关联 video")
    }

    func testCascadeDeleteVideoRemovesClips() throws {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()

        var folder = WatchedFolder(folderPath: "/test")
        try db.write { db in try folder.insert(db) }

        var video = Video(folderId: folder.folderId, filePath: "/test/v.mp4", fileName: "v.mp4")
        try db.write { db in try video.insert(db) }

        var clip = Clip(videoId: video.videoId, startTime: 0, endTime: 1)
        try db.write { db in try clip.insert(db) }

        // 删除 video
        try db.write { db in
            _ = try Video.deleteAll(db)
        }

        let clipCount = try db.read { db in
            try Clip.fetchCount(db)
        }
        XCTAssertEqual(clipCount, 0, "删除 video 应级联删除关联 clip")
    }
}
