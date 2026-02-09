import XCTest
import GRDB
@testable import FindItCore

final class IndexingSchedulerTests: XCTestCase {

    // MARK: - 初始化

    func testDefaultInit() async {
        let scheduler = IndexingScheduler(mode: .balanced)
        let info = await scheduler.concurrencyInfo()
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let expected = max(1, cores / 2)
        XCTAssertEqual(info.max, expected)
        XCTAssertEqual(info.available, expected)
        XCTAssertEqual(info.waiting, 0)
    }

    func testCustomConcurrencyInit() async {
        let scheduler = IndexingScheduler(concurrency: 3)
        let info = await scheduler.concurrencyInfo()
        XCTAssertEqual(info.max, 3)
        XCTAssertEqual(info.available, 3)
    }

    func testMinimumConcurrency() async {
        let scheduler = IndexingScheduler(concurrency: 0)
        let info = await scheduler.concurrencyInfo()
        XCTAssertEqual(info.max, 1, "最小并发数应为 1")
    }

    // MARK: - 模式切换

    func testUpdateMode() async {
        let scheduler = IndexingScheduler(mode: .balanced)
        let infoBefore = await scheduler.concurrencyInfo()

        await scheduler.updateMode(.background)
        let infoAfter = await scheduler.concurrencyInfo()

        // 后台模式并发数应 <= 平衡模式
        XCTAssertLessThanOrEqual(infoAfter.max, infoBefore.max,
            "后台模式并发数应不高于平衡模式")
        XCTAssertGreaterThanOrEqual(infoAfter.max, 1,
            "并发数最小为 1")
    }

    // MARK: - 空视频列表

    func testProcessEmptyVideoList() async {
        let scheduler = IndexingScheduler(concurrency: 2)
        actor Flags {
            var progressCalled = false
            var completeCalled = false
            func markProgress() { progressCalled = true }
            func markComplete() { completeCalled = true }
        }
        let flags = Flags()

        _ = await scheduler.processVideos(
            [],
            folderPath: "/tmp/test",
            folderDB: try! DatabaseManager.openFolderDatabase(at: NSTemporaryDirectory()),
            onProgress: { _ in Task { await flags.markProgress() } },
            onComplete: { _ in Task { await flags.markComplete() } }
        )

        let progressCalled = await flags.progressCalled
        let completeCalled = await flags.completeCalled
        XCTAssertFalse(progressCalled, "空列表不应触发回调")
        XCTAssertFalse(completeCalled, "空列表不应触发回调")
    }

    // MARK: - PerformanceMode

    func testPerformanceModeProperties() {
        XCTAssertEqual(PerformanceMode.fullSpeed.rawValue, "full_speed")
        XCTAssertEqual(PerformanceMode.balanced.rawValue, "balanced")
        XCTAssertEqual(PerformanceMode.background.rawValue, "background")

        XCTAssertEqual(PerformanceMode.fullSpeed.displayName, "全速")
        XCTAssertEqual(PerformanceMode.balanced.displayName, "平衡")
        XCTAssertEqual(PerformanceMode.background.displayName, "后台")

        XCTAssertEqual(PerformanceMode.fullSpeed.taskPriority, .high)
        XCTAssertEqual(PerformanceMode.balanced.taskPriority, .medium)
        XCTAssertEqual(PerformanceMode.background.taskPriority, .low)
    }

    func testPerformanceModeCodable() throws {
        let encoded = try JSONEncoder().encode(PerformanceMode.balanced)
        let decoded = try JSONDecoder().decode(PerformanceMode.self, from: encoded)
        XCTAssertEqual(decoded, .balanced)
    }

    func testPerformanceModeAllCases() {
        XCTAssertEqual(PerformanceMode.allCases.count, 3)
    }

    // MARK: - VideoOutcome

    func testVideoOutcomeSuccess() {
        let outcome = IndexingScheduler.VideoOutcome.success(
            videoPath: "/test.mp4",
            clipsCreated: 5,
            clipsAnalyzed: 3,
            clipsEmbedded: 5,
            sttSkippedNoAudio: true
        )
        XCTAssertTrue(outcome.success)
        XCTAssertNil(outcome.errorMessage)
        XCTAssertEqual(outcome.clipsCreated, 5)
        XCTAssertTrue(outcome.sttSkippedNoAudio)
    }

    func testVideoOutcomeFailure() {
        let outcome = IndexingScheduler.VideoOutcome.failure(
            videoPath: "/test.mp4",
            error: "测试错误"
        )
        XCTAssertFalse(outcome.success)
        XCTAssertEqual(outcome.errorMessage, "测试错误")
        XCTAssertEqual(outcome.clipsCreated, 0)
        XCTAssertFalse(outcome.sttSkippedNoAudio)
    }

    func testVideoOutcomeSkipped() {
        let outcome = IndexingScheduler.VideoOutcome.skipped(videoPath: "/test.mp4")
        XCTAssertFalse(outcome.success)
        XCTAssertEqual(outcome.errorMessage, "cancelled")
        XCTAssertFalse(outcome.sttSkippedNoAudio)
    }

    func testProcessVideos_forceSyncsAfterOrphanRecovery() async throws {
        let fm = FileManager.default
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("findit-scheduler-\(UUID().uuidString)")
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }

        let newPath = (root as NSString).appendingPathComponent("renamed.mp4")
        _ = fm.createFile(atPath: newPath, contents: Data("shared-hash-content".utf8))
        let sharedHash = try FileHasher.hash128(filePath: newPath)

        let oldPath = (root as NSString).appendingPathComponent("old.mp4")
        let folderDB = try DatabaseManager.makeFolderInMemoryDatabase()
        let globalDB = try DatabaseManager.makeGlobalInMemoryDatabase()

        try await folderDB.write { db in
            var folder = WatchedFolder(folderPath: root)
            try folder.insert(db)

            var video = Video(
                folderId: folder.folderId,
                filePath: oldPath,
                fileName: "old.mp4",
                fileHash: sharedHash,
                indexStatus: "completed"
            )
            try video.insert(db)

            var clip = Clip(
                videoId: video.videoId,
                startTime: 0,
                endTime: 5,
                scene: "scene"
            )
            try clip.insert(db)
        }

        // 首次同步推进 sync_meta 游标
        _ = try SyncEngine.sync(folderPath: root, folderDB: folderDB, globalDB: globalDB)

        // 标记 orphaned 并从全局库删除
        _ = try OrphanRecovery.markOrphaned(
            videoPath: oldPath,
            folderPath: root,
            folderDB: folderDB,
            globalDB: globalDB
        )
        let globalCountAfterOrphan = try await globalDB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM videos") ?? 0
        }
        XCTAssertEqual(globalCountAfterOrphan, 0)

        let scheduler = IndexingScheduler(concurrency: 1)
        let syncResult = await scheduler.processVideos(
            [newPath],
            folderPath: root,
            folderDB: folderDB,
            globalDB: globalDB,
            skipStt: true
        )

        XCTAssertNotNil(syncResult)
        let globalVideoCount = try await globalDB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM videos") ?? 0
        }
        let globalClipCount = try await globalDB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips") ?? 0
        }
        XCTAssertEqual(globalVideoCount, 1, "恢复后应重新回填到全局库")
        XCTAssertEqual(globalClipCount, 1, "恢复后应重新回填 clip")
    }
}
