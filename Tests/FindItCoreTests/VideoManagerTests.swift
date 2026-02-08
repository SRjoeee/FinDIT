import XCTest
import GRDB
@testable import FindItCore

final class VideoManagerTests: XCTestCase {

    private var folderDB: DatabaseQueue!
    private var globalDB: DatabaseQueue!
    private let folderPath = "/Volumes/素材盘/项目A"

    override func setUpWithError() throws {
        folderDB = try DatabaseManager.makeFolderInMemoryDatabase()
        globalDB = try DatabaseManager.makeGlobalInMemoryDatabase()
    }

    override func tearDownWithError() throws {
        folderDB = nil
        globalDB = nil
    }

    // MARK: - Helper

    /// 在文件夹库中插入视频 + clips，同步到全局库
    private func seedAndSync(videoCount: Int = 1, clipsPerVideo: Int = 2) throws {
        try folderDB.write { db in
            var folder = WatchedFolder(folderPath: folderPath)
            try folder.insert(db)

            for v in 1...videoCount {
                var video = Video(
                    folderId: folder.folderId,
                    filePath: "\(folderPath)/video\(v).mp4",
                    fileName: "video\(v).mp4",
                    duration: Double(v * 60),
                    fileSize: Int64(v * 1_000_000)
                )
                video.srtPath = "/Library/Application Support/FindIt/srt/video\(v).srt"
                try video.insert(db)

                for c in 0..<clipsPerVideo {
                    var clip = Clip(
                        videoId: video.videoId,
                        startTime: Double(c * 5),
                        endTime: Double((c + 1) * 5),
                        scene: "场景\(v)-\(c + 1)",
                        clipDescription: "视频\(v)的第\(c + 1)个片段"
                    )
                    clip.setTags(["标签\(v)", "片段\(c + 1)"])
                    try clip.insert(db)
                }
            }
        }

        _ = try SyncEngine.sync(
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )
    }

    private func folderVideoCount() throws -> Int {
        try folderDB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM videos") ?? 0
        }
    }

    private func folderClipCount() throws -> Int {
        try folderDB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips") ?? 0
        }
    }

    private func globalVideoCount() throws -> Int {
        try globalDB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM videos") ?? 0
        }
    }

    private func globalClipCount() throws -> Int {
        try globalDB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips") ?? 0
        }
    }

    // MARK: - removeVideo 单视频删除

    func testRemoveVideo_existingVideo_returnsTrue() throws {
        try seedAndSync(videoCount: 1, clipsPerVideo: 2)

        let result = try VideoManager.removeVideo(
            videoPath: "\(folderPath)/video1.mp4",
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        XCTAssertTrue(result)
    }

    func testRemoveVideo_deletesFromFolderDB() throws {
        try seedAndSync(videoCount: 2, clipsPerVideo: 2)
        XCTAssertEqual(try folderVideoCount(), 2)
        XCTAssertEqual(try folderClipCount(), 4)

        try VideoManager.removeVideo(
            videoPath: "\(folderPath)/video1.mp4",
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        XCTAssertEqual(try folderVideoCount(), 1)
        // CASCADE: clips 也被删除
        XCTAssertEqual(try folderClipCount(), 2)
    }

    func testRemoveVideo_deletesFromGlobalDB() throws {
        try seedAndSync(videoCount: 2, clipsPerVideo: 2)
        XCTAssertEqual(try globalVideoCount(), 2)
        XCTAssertEqual(try globalClipCount(), 4)

        try VideoManager.removeVideo(
            videoPath: "\(folderPath)/video1.mp4",
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        XCTAssertEqual(try globalVideoCount(), 1)
        XCTAssertEqual(try globalClipCount(), 2)
    }

    func testRemoveVideo_nonexistentPath_returnsFalse() throws {
        try seedAndSync(videoCount: 1, clipsPerVideo: 2)

        let result = try VideoManager.removeVideo(
            videoPath: "\(folderPath)/nonexistent.mp4",
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        XCTAssertFalse(result)
        // 原有数据不受影响
        XCTAssertEqual(try folderVideoCount(), 1)
        XCTAssertEqual(try globalVideoCount(), 1)
    }

    func testRemoveVideo_withoutGlobalDB_onlyDeletesFolderDB() throws {
        try seedAndSync(videoCount: 1, clipsPerVideo: 2)

        let result = try VideoManager.removeVideo(
            videoPath: "\(folderPath)/video1.mp4",
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: nil  // 不传全局库
        )

        XCTAssertTrue(result)
        XCTAssertEqual(try folderVideoCount(), 0)
        XCTAssertEqual(try folderClipCount(), 0)
        // 全局库不受影响
        XCTAssertEqual(try globalVideoCount(), 1)
        XCTAssertEqual(try globalClipCount(), 2)
    }

    func testRemoveVideo_cascadeDeletesAllClips() throws {
        try seedAndSync(videoCount: 1, clipsPerVideo: 5)
        XCTAssertEqual(try folderClipCount(), 5)
        XCTAssertEqual(try globalClipCount(), 5)

        try VideoManager.removeVideo(
            videoPath: "\(folderPath)/video1.mp4",
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        XCTAssertEqual(try folderClipCount(), 0)
        XCTAssertEqual(try globalClipCount(), 0)
    }

    // MARK: - removeVideos 批量删除

    func testRemoveVideos_deletesMultiple() throws {
        try seedAndSync(videoCount: 3, clipsPerVideo: 2)
        XCTAssertEqual(try folderVideoCount(), 3)

        let count = try VideoManager.removeVideos(
            videoPaths: [
                "\(folderPath)/video1.mp4",
                "\(folderPath)/video2.mp4"
            ],
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        XCTAssertEqual(count, 2)
        XCTAssertEqual(try folderVideoCount(), 1)
        XCTAssertEqual(try folderClipCount(), 2)
        XCTAssertEqual(try globalVideoCount(), 1)
        XCTAssertEqual(try globalClipCount(), 2)
    }

    func testRemoveVideos_emptyList_returnsZero() throws {
        try seedAndSync(videoCount: 1, clipsPerVideo: 2)

        let count = try VideoManager.removeVideos(
            videoPaths: [],
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        XCTAssertEqual(count, 0)
        XCTAssertEqual(try folderVideoCount(), 1)
    }

    func testRemoveVideos_mixedExistingAndNonexistent() throws {
        try seedAndSync(videoCount: 2, clipsPerVideo: 1)

        let count = try VideoManager.removeVideos(
            videoPaths: [
                "\(folderPath)/video1.mp4",      // 存在
                "\(folderPath)/nonexistent.mp4",  // 不存在
                "\(folderPath)/video2.mp4"        // 存在
            ],
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        XCTAssertEqual(count, 2)
        XCTAssertEqual(try folderVideoCount(), 0)
    }

    // MARK: - 边界情况

    func testRemoveVideo_videoWithNoClips() throws {
        // 创建只有视频没有 clips 的数据
        try folderDB.write { db in
            var folder = WatchedFolder(folderPath: folderPath)
            try folder.insert(db)

            var video = Video(
                folderId: folder.folderId,
                filePath: "\(folderPath)/empty.mp4",
                fileName: "empty.mp4",
                duration: 10,
                fileSize: 1000
            )
            try video.insert(db)
        }
        _ = try SyncEngine.sync(
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        let result = try VideoManager.removeVideo(
            videoPath: "\(folderPath)/empty.mp4",
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        XCTAssertTrue(result)
        XCTAssertEqual(try folderVideoCount(), 0)
        XCTAssertEqual(try globalVideoCount(), 0)
    }

    func testRemoveVideo_globalDBNotSynced_stillDeletesFolderDB() throws {
        // 只在文件夹库插入，不同步到全局库
        try folderDB.write { db in
            var folder = WatchedFolder(folderPath: folderPath)
            try folder.insert(db)

            var video = Video(
                folderId: folder.folderId,
                filePath: "\(folderPath)/unsynced.mp4",
                fileName: "unsynced.mp4",
                duration: 30,
                fileSize: 5000
            )
            try video.insert(db)
        }

        let result = try VideoManager.removeVideo(
            videoPath: "\(folderPath)/unsynced.mp4",
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB  // 全局库中无此记录
        )

        XCTAssertTrue(result)
        XCTAssertEqual(try folderVideoCount(), 0)
    }
}
