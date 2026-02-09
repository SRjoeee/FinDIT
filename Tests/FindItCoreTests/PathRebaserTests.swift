import XCTest
import GRDB
@testable import FindItCore

final class PathRebaserTests: XCTestCase {

    private var folderDB: DatabaseQueue!
    private let oldPath = "/Users/alice/Videos"
    private let newPath = "/Users/bob/Media"

    override func setUpWithError() throws {
        folderDB = try DatabaseManager.makeFolderInMemoryDatabase()
    }

    override func tearDownWithError() throws {
        folderDB = nil
    }

    // MARK: - Helper

    /// 在文件夹库中创建完整的测试数据
    private func seedFolder(
        folderPath: String,
        videoCount: Int = 2,
        clipsPerVideo: Int = 2,
        withSrtInFolder: Bool = true,
        withFallbackSrt: Bool = true
    ) throws {
        try folderDB.write { db in
            var folder = WatchedFolder(folderPath: folderPath)
            try folder.insert(db)

            for v in 1...videoCount {
                var video = Video(
                    folderId: folder.folderId,
                    filePath: "\(folderPath)/sub/video\(v).mp4",
                    fileName: "video\(v).mp4",
                    duration: Double(v * 60),
                    fileSize: Int64(v * 1_000_000)
                )

                // 第一个视频用文件夹内 SRT，第二个用 fallback
                if v == 1 && withSrtInFolder {
                    video.srtPath = "\(folderPath)/sub/video\(v).srt"
                } else if v == 2 && withFallbackSrt {
                    video.srtPath = "/Users/alice/Library/Application Support/FindIt/srt/abc123.srt"
                }

                try video.insert(db)

                for c in 0..<clipsPerVideo {
                    var clip = Clip(
                        videoId: video.videoId,
                        startTime: Double(c * 5),
                        endTime: Double((c + 1) * 5),
                        scene: "场景\(v)-\(c + 1)",
                        clipDescription: "视频\(v)的第\(c + 1)个片段"
                    )
                    clip.thumbnailPath = "\(folderPath)/.clip-index/thumbnails/video_\(video.videoId!)/scene_00\(c)_frame_00.jpg"
                    try clip.insert(db)
                }
            }
        }
    }

    // MARK: - detectMismatch

    func testDetectMismatch_samePathReturnsNil() throws {
        try seedFolder(folderPath: oldPath)

        let result = try PathRebaser.detectMismatch(folderDB: folderDB, newPath: oldPath)
        XCTAssertNil(result)
    }

    func testDetectMismatch_differentPathReturnsOldPath() throws {
        try seedFolder(folderPath: oldPath)

        let result = try PathRebaser.detectMismatch(folderDB: folderDB, newPath: newPath)
        XCTAssertEqual(result, oldPath)
    }

    func testDetectMismatch_emptyDBReturnsNil() throws {
        // 空库（无 WatchedFolder 记录）
        let result = try PathRebaser.detectMismatch(folderDB: folderDB, newPath: newPath)
        XCTAssertNil(result)
    }

    // MARK: - rebase: watched_folders

    func testRebase_updatesWatchedFolderPath() throws {
        try seedFolder(folderPath: oldPath)

        _ = try PathRebaser.rebase(folderDB: folderDB, oldPath: oldPath, newPath: newPath)

        let storedPath = try folderDB.read { db in
            try String.fetchOne(db, sql:
                "SELECT folder_path FROM watched_folders LIMIT 1")
        }
        XCTAssertEqual(storedPath, newPath)
    }

    // MARK: - rebase: videos.file_path

    func testRebase_updatesVideoFilePaths() throws {
        try seedFolder(folderPath: oldPath)

        let result = try PathRebaser.rebase(folderDB: folderDB, oldPath: oldPath, newPath: newPath)

        XCTAssertEqual(result.rebasedVideos, 2)

        let paths = try folderDB.read { db in
            try String.fetchAll(db, sql: "SELECT file_path FROM videos ORDER BY video_id")
        }
        XCTAssertEqual(paths[0], "\(newPath)/sub/video1.mp4")
        XCTAssertEqual(paths[1], "\(newPath)/sub/video2.mp4")
    }

    // MARK: - rebase: videos.srt_path

    func testRebase_updatesSrtPathInFolder() throws {
        try seedFolder(folderPath: oldPath)

        _ = try PathRebaser.rebase(folderDB: folderDB, oldPath: oldPath, newPath: newPath)

        let srtPath = try folderDB.read { db in
            try String.fetchOne(db, sql:
                "SELECT srt_path FROM videos WHERE video_id = 1")
        }
        XCTAssertEqual(srtPath, "\(newPath)/sub/video1.srt")
    }

    func testRebase_skipsAppSupportSrtPaths() throws {
        try seedFolder(folderPath: oldPath)

        _ = try PathRebaser.rebase(folderDB: folderDB, oldPath: oldPath, newPath: newPath)

        // 第二个视频的 SRT 路径在 ~/Library，不应被改动
        let srtPath = try folderDB.read { db in
            try String.fetchOne(db, sql:
                "SELECT srt_path FROM videos WHERE video_id = 2")
        }
        XCTAssertEqual(srtPath, "/Users/alice/Library/Application Support/FindIt/srt/abc123.srt")
    }

    // MARK: - rebase: clips.thumbnail_path

    func testRebase_updatesThumbnailPaths() throws {
        try seedFolder(folderPath: oldPath)

        let result = try PathRebaser.rebase(folderDB: folderDB, oldPath: oldPath, newPath: newPath)

        XCTAssertEqual(result.rebasedClips, 4)  // 2 videos × 2 clips

        let paths = try folderDB.read { db in
            try String.fetchAll(db, sql:
                "SELECT thumbnail_path FROM clips ORDER BY clip_id")
        }
        for path in paths {
            XCTAssertTrue(path.hasPrefix(newPath), "缩略图路径应以新路径开头: \(path)")
            XCTAssertTrue(path.contains("/.clip-index/thumbnails/"), "路径结构应保留: \(path)")
        }
    }

    // MARK: - rebase: NULL 处理

    func testRebase_skipsNullPaths() throws {
        // 创建无 SRT 和无缩略图的数据
        try folderDB.write { db in
            var folder = WatchedFolder(folderPath: oldPath)
            try folder.insert(db)

            var video = Video(
                folderId: folder.folderId,
                filePath: "\(oldPath)/video.mp4",
                fileName: "video.mp4"
            )
            // srt_path 为 nil
            try video.insert(db)

            var clip = Clip(
                videoId: video.videoId,
                startTime: 0,
                endTime: 5,
                scene: "场景",
                clipDescription: "描述"
            )
            // thumbnail_path 为 nil
            try clip.insert(db)
        }

        let result = try PathRebaser.rebase(folderDB: folderDB, oldPath: oldPath, newPath: newPath)

        XCTAssertTrue(result.didRebase)
        // NULL 路径不应报错
        let srtPath = try folderDB.read { db in
            try Row.fetchOne(db, sql: "SELECT srt_path FROM videos LIMIT 1")?["srt_path"] as String?
        }
        XCTAssertNil(srtPath)

        let thumbPath = try folderDB.read { db in
            try Row.fetchOne(db, sql: "SELECT thumbnail_path FROM clips LIMIT 1")?["thumbnail_path"] as String?
        }
        XCTAssertNil(thumbPath)
    }

    // MARK: - rebase: 返回值

    func testRebase_returnsCorrectCounts() throws {
        try seedFolder(folderPath: oldPath, videoCount: 3, clipsPerVideo: 2)

        let result = try PathRebaser.rebase(folderDB: folderDB, oldPath: oldPath, newPath: newPath)

        XCTAssertEqual(result.oldPath, oldPath)
        XCTAssertEqual(result.newPath, newPath)
        XCTAssertEqual(result.rebasedVideos, 3)
        XCTAssertEqual(result.rebasedClips, 6)
        XCTAssertTrue(result.didRebase)
    }

    // MARK: - rebaseIfNeeded

    func testRebaseIfNeeded_samePathNoOp() throws {
        try seedFolder(folderPath: oldPath)

        let result = try PathRebaser.rebaseIfNeeded(folderDB: folderDB, newPath: oldPath)

        XCTAssertFalse(result.didRebase)
        XCTAssertEqual(result.rebasedVideos, 0)
        XCTAssertEqual(result.rebasedClips, 0)
    }

    func testRebaseIfNeeded_differentPathRebases() throws {
        try seedFolder(folderPath: oldPath)

        let result = try PathRebaser.rebaseIfNeeded(folderDB: folderDB, newPath: newPath)

        XCTAssertTrue(result.didRebase)
        XCTAssertEqual(result.oldPath, oldPath)
        XCTAssertEqual(result.newPath, newPath)
        XCTAssertEqual(result.rebasedVideos, 2)
        XCTAssertEqual(result.rebasedClips, 4)
    }

    // MARK: - 中文路径

    func testRebase_chineseCharactersInPath() throws {
        let cnOldPath = "/Volumes/素材盘/项目A/剪辑素材"
        let cnNewPath = "/Volumes/新硬盘/工作/素材库"

        try seedFolder(folderPath: cnOldPath)

        let result = try PathRebaser.rebase(folderDB: folderDB, oldPath: cnOldPath, newPath: cnNewPath)

        XCTAssertTrue(result.didRebase)
        XCTAssertEqual(result.rebasedVideos, 2)

        let paths = try folderDB.read { db in
            try String.fetchAll(db, sql: "SELECT file_path FROM videos ORDER BY video_id")
        }
        XCTAssertTrue(paths[0].hasPrefix(cnNewPath))
        XCTAssertTrue(paths[0].hasSuffix("/sub/video1.mp4"))
    }

    // MARK: - 尾斜杠处理

    func testRebase_trailingSlashNormalization() throws {
        try seedFolder(folderPath: oldPath)

        // 新路径带尾斜杠 → 应自动标准化
        let result = try PathRebaser.rebaseIfNeeded(
            folderDB: folderDB,
            newPath: newPath + "/"
        )

        XCTAssertTrue(result.didRebase)
        XCTAssertEqual(result.newPath, newPath)  // 尾斜杠被移除
    }

    // MARK: - 深层嵌套

    func testRebase_deeplyNestedSubpaths() throws {
        let deepOld = "/Users/alice/Projects/2024/Q3/VideoEditing/素材"
        let deepNew = "/Volumes/外接盘/归档/素材"

        try seedFolder(folderPath: deepOld)

        let result = try PathRebaser.rebase(folderDB: folderDB, oldPath: deepOld, newPath: deepNew)

        XCTAssertTrue(result.didRebase)

        let folderStoredPath = try folderDB.read { db in
            try String.fetchOne(db, sql: "SELECT folder_path FROM watched_folders LIMIT 1")
        }
        XCTAssertEqual(folderStoredPath, deepNew)

        let thumbPaths = try folderDB.read { db in
            try String.fetchAll(db, sql: "SELECT thumbnail_path FROM clips WHERE thumbnail_path IS NOT NULL")
        }
        for path in thumbPaths {
            XCTAssertTrue(path.hasPrefix(deepNew), "深层路径应正确替换: \(path)")
        }
    }
}
