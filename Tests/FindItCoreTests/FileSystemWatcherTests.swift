import XCTest
@testable import FindItCore
import CoreServices

final class FileSystemWatcherTests: XCTestCase {

    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("findit-fswatcher-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - classifyEvent 单元测试（无 FSEvents 依赖）

    func testClassifyEvent_createdFlagAndFileExists_returnsAdded() {
        let path = tempDir.appendingPathComponent("new.mp4").path
        FileManager.default.createFile(atPath: path, contents: Data([0x00]))

        let kind = FileSystemWatcher.classifyEvent(
            flags: UInt32(kFSEventStreamEventFlagItemCreated),
            path: path
        )
        XCTAssertEqual(kind, .added)
    }

    func testClassifyEvent_renamedFlagAndFileExists_returnsAdded() {
        let path = tempDir.appendingPathComponent("moved-in.mov").path
        FileManager.default.createFile(atPath: path, contents: Data([0x00]))

        let kind = FileSystemWatcher.classifyEvent(
            flags: UInt32(kFSEventStreamEventFlagItemRenamed),
            path: path
        )
        XCTAssertEqual(kind, .added)
    }

    func testClassifyEvent_renamedFlagAndFileGone_returnsRemoved() {
        let path = tempDir.appendingPathComponent("moved-out.mov").path
        // 文件不存在

        let kind = FileSystemWatcher.classifyEvent(
            flags: UInt32(kFSEventStreamEventFlagItemRenamed),
            path: path
        )
        XCTAssertEqual(kind, .removed)
    }

    func testClassifyEvent_removedFlagAndFileGone_returnsRemoved() {
        let path = tempDir.appendingPathComponent("deleted.mp4").path

        let kind = FileSystemWatcher.classifyEvent(
            flags: UInt32(kFSEventStreamEventFlagItemRemoved),
            path: path
        )
        XCTAssertEqual(kind, .removed)
    }

    func testClassifyEvent_modifiedFlagAndFileExists_returnsModified() {
        let path = tempDir.appendingPathComponent("edited.mp4").path
        FileManager.default.createFile(atPath: path, contents: Data([0x00]))

        let kind = FileSystemWatcher.classifyEvent(
            flags: UInt32(kFSEventStreamEventFlagItemModified),
            path: path
        )
        XCTAssertEqual(kind, .modified)
    }

    func testClassifyEvent_inodeMetaModFlag_returnsModified() {
        let path = tempDir.appendingPathComponent("meta.mp4").path
        FileManager.default.createFile(atPath: path, contents: Data([0x00]))

        let kind = FileSystemWatcher.classifyEvent(
            flags: UInt32(kFSEventStreamEventFlagItemInodeMetaMod),
            path: path
        )
        XCTAssertEqual(kind, .modified)
    }

    func testClassifyEvent_noRelevantFlags_fileGone_returnsNil() {
        let path = tempDir.appendingPathComponent("ghost.mp4").path

        // kFSEventStreamEventFlagItemIsFile 不在 changeMask 中
        let kind = FileSystemWatcher.classifyEvent(
            flags: UInt32(kFSEventStreamEventFlagItemIsFile),
            path: path
        )
        XCTAssertNil(kind)
    }

    func testClassifyEvent_noRelevantFlags_fileExists_returnsModified() {
        let path = tempDir.appendingPathComponent("exists.mp4").path
        FileManager.default.createFile(atPath: path, contents: Data([0x00]))

        // 文件存在但无明确变更标志 → 安全起见报告 modified
        let kind = FileSystemWatcher.classifyEvent(
            flags: UInt32(kFSEventStreamEventFlagItemIsFile),
            path: path
        )
        XCTAssertEqual(kind, .modified)
    }

    // MARK: - deduplicateEvents 单元测试

    func testDeduplicateEvents_samePathMultipleEvents_keepsLast() {
        let events = [
            FileChangeEvent(path: "/a/b.mp4", kind: .added, folderPath: "/a"),
            FileChangeEvent(path: "/a/b.mp4", kind: .modified, folderPath: "/a"),
        ]
        let result = FileSystemWatcher.deduplicateEvents(events)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].kind, .modified)
    }

    func testDeduplicateEvents_differentPaths_keepsAll() {
        let events = [
            FileChangeEvent(path: "/a/x.mp4", kind: .added, folderPath: "/a"),
            FileChangeEvent(path: "/a/y.mov", kind: .removed, folderPath: "/a"),
        ]
        let result = FileSystemWatcher.deduplicateEvents(events)
        XCTAssertEqual(result.count, 2)
    }

    func testDeduplicateEvents_preservesOrder() {
        let events = [
            FileChangeEvent(path: "/a/first.mp4", kind: .added, folderPath: "/a"),
            FileChangeEvent(path: "/a/second.mov", kind: .removed, folderPath: "/a"),
            FileChangeEvent(path: "/a/third.mkv", kind: .modified, folderPath: "/a"),
        ]
        let result = FileSystemWatcher.deduplicateEvents(events)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].path, "/a/first.mp4")
        XCTAssertEqual(result[1].path, "/a/second.mov")
        XCTAssertEqual(result[2].path, "/a/third.mkv")
    }

    func testDeduplicateEvents_overwritePreservesPosition() {
        let events = [
            FileChangeEvent(path: "/a/x.mp4", kind: .added, folderPath: "/a"),
            FileChangeEvent(path: "/a/y.mov", kind: .removed, folderPath: "/a"),
            FileChangeEvent(path: "/a/x.mp4", kind: .modified, folderPath: "/a"),
        ]
        let result = FileSystemWatcher.deduplicateEvents(events)
        XCTAssertEqual(result.count, 2)
        // x.mp4 保持原位置（index 0），但 kind 被覆盖为 modified
        XCTAssertEqual(result[0].path, "/a/x.mp4")
        XCTAssertEqual(result[0].kind, .modified)
        XCTAssertEqual(result[1].path, "/a/y.mov")
    }

    func testDeduplicateEvents_empty_returnsEmpty() {
        let result = FileSystemWatcher.deduplicateEvents([])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - FileChangeEvent 模型测试

    func testFileChangeEventEquatable() {
        let a = FileChangeEvent(path: "/test.mp4", kind: .added, folderPath: "/")
        let b = FileChangeEvent(path: "/test.mp4", kind: .added, folderPath: "/")
        let c = FileChangeEvent(path: "/test.mp4", kind: .removed, folderPath: "/")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testFileChangeEventKindRawValue() {
        XCTAssertEqual(FileChangeEvent.Kind.added.rawValue, "added")
        XCTAssertEqual(FileChangeEvent.Kind.removed.rawValue, "removed")
        XCTAssertEqual(FileChangeEvent.Kind.rescanNeeded.rawValue, "rescanNeeded")
        XCTAssertEqual(FileChangeEvent.Kind.modified.rawValue, "modified")
    }

    // MARK: - Watch/Unwatch 生命周期测试

    func testWatchAndUnwatch_lifecycle() {
        let watcher = FileSystemWatcher(latency: 0.3) { _ in }

        XCTAssertFalse(watcher.isMonitoring)
        XCTAssertTrue(watcher.watchedPaths.isEmpty)

        watcher.watch(tempDir.path)
        XCTAssertTrue(watcher.isMonitoring)
        XCTAssertEqual(watcher.watchedPaths, [tempDir.path])

        watcher.unwatch(tempDir.path)
        XCTAssertFalse(watcher.isMonitoring)
        XCTAssertTrue(watcher.watchedPaths.isEmpty)
    }

    func testWatchDuplicate_ignored() {
        let watcher = FileSystemWatcher(latency: 0.3) { _ in }
        watcher.watch(tempDir.path)
        watcher.watch(tempDir.path) // 重复 watch 不应崩溃
        XCTAssertEqual(watcher.watchedPaths.count, 1)
        watcher.stopAll()
    }

    func testUnwatchNonexistent_noOp() {
        let watcher = FileSystemWatcher(latency: 0.3) { _ in }
        watcher.unwatch("/nonexistent/path") // 不应崩溃
        XCTAssertFalse(watcher.isMonitoring)
    }

    func testStopAll_clearsAllStreams() {
        let dir2 = tempDir.appendingPathComponent("sub")
        try! FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)

        let watcher = FileSystemWatcher(latency: 0.3) { _ in }
        watcher.watch(tempDir.path)
        watcher.watch(dir2.path)
        XCTAssertEqual(watcher.watchedPaths.count, 2)

        watcher.stopAll()
        XCTAssertFalse(watcher.isMonitoring)
        XCTAssertTrue(watcher.watchedPaths.isEmpty)
    }

    func testMultipleFolders_watchedPaths() {
        let dir2 = tempDir.appendingPathComponent("another")
        try! FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)

        let watcher = FileSystemWatcher(latency: 0.3) { _ in }
        watcher.watch(tempDir.path)
        watcher.watch(dir2.path)

        XCTAssertEqual(watcher.watchedPaths.count, 2)
        XCTAssertTrue(watcher.watchedPaths.contains(tempDir.path))
        XCTAssertTrue(watcher.watchedPaths.contains(dir2.path))

        watcher.unwatch(tempDir.path)
        XCTAssertEqual(watcher.watchedPaths, [dir2.path])

        watcher.stopAll()
    }

    // MARK: - FSEvents 实时检测测试

    func testDetectsNewVideoFile() {
        let expectation = expectation(description: "detect new video file")
        var receivedEvents: [FileChangeEvent] = []

        let watcher = FileSystemWatcher(latency: 0.3, callbackQueue: .main) { events in
            receivedEvents.append(contentsOf: events)
            if receivedEvents.contains(where: { $0.kind == .added && $0.path.hasSuffix("new-video.mp4") }) {
                expectation.fulfill()
            }
        }
        watcher.watch(tempDir.path)

        // 延迟创建文件，确保 watcher 已就绪
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let videoPath = self.tempDir.appendingPathComponent("new-video.mp4").path
            FileManager.default.createFile(atPath: videoPath, contents: Data(repeating: 0x00, count: 64))
        }

        waitForExpectations(timeout: 5)
        let matched = receivedEvents.first { $0.path.hasSuffix("new-video.mp4") }
        XCTAssertNotNil(matched)
        XCTAssertEqual(matched?.kind, .added)
        XCTAssertEqual(matched?.folderPath, tempDir.path)

        watcher.stopAll()
    }

    func testIgnoresNonVideoFile() {
        let expectation = expectation(description: "no events for txt")
        expectation.isInverted = true

        let watcher = FileSystemWatcher(latency: 0.3, callbackQueue: .main) { events in
            if events.contains(where: { $0.path.hasSuffix(".txt") }) {
                expectation.fulfill()
            }
        }
        watcher.watch(tempDir.path)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            let txtPath = self.tempDir.appendingPathComponent("readme.txt").path
            FileManager.default.createFile(atPath: txtPath, contents: Data([0x00]))
        }

        waitForExpectations(timeout: 3)
        watcher.stopAll()
    }

    func testDetectsFileRemoval() {
        // 预先创建文件
        let videoPath = tempDir.appendingPathComponent("to-delete.mov").path
        FileManager.default.createFile(atPath: videoPath, contents: Data(repeating: 0x00, count: 64))

        let expectation = expectation(description: "detect file removal")
        var receivedEvents: [FileChangeEvent] = []

        let watcher = FileSystemWatcher(latency: 0.3, callbackQueue: .main) { events in
            receivedEvents.append(contentsOf: events)
            if events.contains(where: { $0.kind == .removed && $0.path.hasSuffix("to-delete.mov") }) {
                expectation.fulfill()
            }
        }
        watcher.watch(tempDir.path)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            try? FileManager.default.removeItem(atPath: videoPath)
        }

        waitForExpectations(timeout: 5)
        let matched = receivedEvents.first { $0.kind == .removed && $0.path.hasSuffix("to-delete.mov") }
        XCTAssertNotNil(matched)

        watcher.stopAll()
    }

    func testDetectsFileModification() {
        // 预先创建文件
        let videoPath = tempDir.appendingPathComponent("edit-me.mp4").path
        FileManager.default.createFile(atPath: videoPath, contents: Data(repeating: 0x00, count: 64))

        let expectation = expectation(description: "detect file modification")
        var receivedEvents: [FileChangeEvent] = []

        let watcher = FileSystemWatcher(latency: 0.3, callbackQueue: .main) { events in
            receivedEvents.append(contentsOf: events)
            // 修改可能产生 .modified 或 .added（FSEvents flag 组合不确定）
            if events.contains(where: { $0.path.hasSuffix("edit-me.mp4") }) {
                expectation.fulfill()
            }
        }
        watcher.watch(tempDir.path)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            // 追加数据触发 modified 事件
            let handle = FileHandle(forWritingAtPath: videoPath)
            handle?.seekToEndOfFile()
            handle?.write(Data(repeating: 0xFF, count: 128))
            handle?.closeFile()
        }

        waitForExpectations(timeout: 5)
        let matched = receivedEvents.first { $0.path.hasSuffix("edit-me.mp4") }
        XCTAssertNotNil(matched)

        watcher.stopAll()
    }

    func testIgnoresClipIndexDirectory() {
        // 创建 .clip-index 子目录
        let clipIndexDir = tempDir.appendingPathComponent(".clip-index")
        try! FileManager.default.createDirectory(at: clipIndexDir, withIntermediateDirectories: true)

        let expectation = expectation(description: "no events for .clip-index")
        expectation.isInverted = true

        let watcher = FileSystemWatcher(latency: 0.3, callbackQueue: .main) { events in
            if events.contains(where: { $0.path.contains("/.clip-index/") }) {
                expectation.fulfill()
            }
        }
        watcher.watch(tempDir.path)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            let insidePath = clipIndexDir.appendingPathComponent("thumb.mp4").path
            FileManager.default.createFile(atPath: insidePath, contents: Data([0x00]))
        }

        waitForExpectations(timeout: 3)
        watcher.stopAll()
    }

    func testUnwatchStopsEvents() {
        let expectation = expectation(description: "no events after unwatch")
        expectation.isInverted = true

        let watcher = FileSystemWatcher(latency: 0.3, callbackQueue: .main) { events in
            if events.contains(where: { $0.path.hasSuffix("after-unwatch.mp4") }) {
                expectation.fulfill()
            }
        }
        watcher.watch(tempDir.path)
        watcher.unwatch(tempDir.path)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            let path = self.tempDir.appendingPathComponent("after-unwatch.mp4").path
            FileManager.default.createFile(atPath: path, contents: Data([0x00]))
        }

        waitForExpectations(timeout: 3)
    }

    func testDetectsEventInSubdirectory() {
        let subDir = tempDir.appendingPathComponent("footage/day1")
        try! FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let expectation = expectation(description: "detect file in subdirectory")

        let watcher = FileSystemWatcher(latency: 0.3, callbackQueue: .main) { events in
            if events.contains(where: { $0.path.hasSuffix("deep.mkv") }) {
                expectation.fulfill()
            }
        }
        watcher.watch(tempDir.path)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let path = subDir.appendingPathComponent("deep.mkv").path
            FileManager.default.createFile(atPath: path, contents: Data([0x00]))
        }

        waitForExpectations(timeout: 5)
        watcher.stopAll()
    }

    func testRewatchCycle_worksAfterUnwatch() {
        let expectation = expectation(description: "events after re-watch")

        let watcher = FileSystemWatcher(latency: 0.3, callbackQueue: .main) { events in
            if events.contains(where: { $0.path.hasSuffix("rewatch.mp4") }) {
                expectation.fulfill()
            }
        }

        // watch → unwatch → watch 循环
        watcher.watch(tempDir.path)
        watcher.unwatch(tempDir.path)
        XCTAssertFalse(watcher.isMonitoring)

        watcher.watch(tempDir.path)
        XCTAssertTrue(watcher.isMonitoring)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let path = self.tempDir.appendingPathComponent("rewatch.mp4").path
            FileManager.default.createFile(atPath: path, contents: Data([0x00]))
        }

        waitForExpectations(timeout: 5)
        watcher.stopAll()
    }

    func testFolderPathInEvent_matchesWatchedFolder() {
        let expectation = expectation(description: "folderPath matches")
        var captured: FileChangeEvent?

        let watcher = FileSystemWatcher(latency: 0.3, callbackQueue: .main) { events in
            if let event = events.first(where: { $0.path.hasSuffix("check-folder.mp4") }) {
                captured = event
                expectation.fulfill()
            }
        }
        watcher.watch(tempDir.path)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let path = self.tempDir.appendingPathComponent("check-folder.mp4").path
            FileManager.default.createFile(atPath: path, contents: Data([0x00]))
        }

        waitForExpectations(timeout: 5)
        XCTAssertEqual(captured?.folderPath, tempDir.path)
        watcher.stopAll()
    }
}
