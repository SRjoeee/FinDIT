import XCTest
@testable import FindItCore

final class FileScannerTests: XCTestCase {

    // MARK: - isVideoFile

    func testIsVideoFileSupported() {
        XCTAssertTrue(FileScanner.isVideoFile("/path/to/video.mp4"))
        XCTAssertTrue(FileScanner.isVideoFile("/path/to/video.MOV"))
        XCTAssertTrue(FileScanner.isVideoFile("/path/to/video.MKV"))
        XCTAssertTrue(FileScanner.isVideoFile("/path/to/video.avi"))
        XCTAssertTrue(FileScanner.isVideoFile("/path/to/video.mxf"))
        XCTAssertTrue(FileScanner.isVideoFile("/path/to/video.webm"))
        XCTAssertTrue(FileScanner.isVideoFile("/path/to/video.m4v"))
        XCTAssertTrue(FileScanner.isVideoFile("/path/to/video.ts"))
        XCTAssertTrue(FileScanner.isVideoFile("/path/to/video.mts"))
    }

    func testIsVideoFileUnsupported() {
        XCTAssertFalse(FileScanner.isVideoFile("/path/to/image.jpg"))
        XCTAssertFalse(FileScanner.isVideoFile("/path/to/audio.wav"))
        XCTAssertFalse(FileScanner.isVideoFile("/path/to/document.pdf"))
        XCTAssertFalse(FileScanner.isVideoFile("/path/to/subtitle.srt"))
        XCTAssertFalse(FileScanner.isVideoFile("/path/to/noextension"))
    }

    func testIsVideoFileCaseInsensitive() {
        XCTAssertTrue(FileScanner.isVideoFile("/path/video.Mp4"))
        XCTAssertTrue(FileScanner.isVideoFile("/path/video.MOV"))
        XCTAssertTrue(FileScanner.isVideoFile("/path/video.Mkv"))
    }

    // MARK: - scanVideoFiles

    func testScanEmptyDirectory() throws {
        let tmpDir = NSTemporaryDirectory() + "findit_test_empty_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let results = try FileScanner.scanVideoFiles(in: tmpDir)
        XCTAssertEqual(results, [])
    }

    func testScanNonExistentDirectory() throws {
        let results = try FileScanner.scanVideoFiles(in: "/nonexistent/path/\(UUID().uuidString)")
        XCTAssertEqual(results, [])
    }

    func testScanFiltersVideoExtensions() throws {
        let tmpDir = NSTemporaryDirectory() + "findit_test_scan_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // 创建混合文件
        FileManager.default.createFile(atPath: (tmpDir as NSString).appendingPathComponent("video.mp4"), contents: nil)
        FileManager.default.createFile(atPath: (tmpDir as NSString).appendingPathComponent("clip.mov"), contents: nil)
        FileManager.default.createFile(atPath: (tmpDir as NSString).appendingPathComponent("photo.jpg"), contents: nil)
        FileManager.default.createFile(atPath: (tmpDir as NSString).appendingPathComponent("readme.txt"), contents: nil)

        let results = try FileScanner.scanVideoFiles(in: tmpDir)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results[0].hasSuffix("clip.mov"))
        XCTAssertTrue(results[1].hasSuffix("video.mp4"))
    }

    func testScanRecursive() throws {
        let tmpDir = NSTemporaryDirectory() + "findit_test_recursive_\(UUID().uuidString)"
        let subDir = (tmpDir as NSString).appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(atPath: subDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        FileManager.default.createFile(atPath: (tmpDir as NSString).appendingPathComponent("root.mp4"), contents: nil)
        FileManager.default.createFile(atPath: (subDir as NSString).appendingPathComponent("nested.mov"), contents: nil)

        let results = try FileScanner.scanVideoFiles(in: tmpDir)
        XCTAssertEqual(results.count, 2)
        // 结果应按路径排序
        XCTAssertTrue(results[0].contains("root.mp4"))
        XCTAssertTrue(results[1].contains("nested.mov"))
    }

    func testScanSkipsHiddenFiles() throws {
        let tmpDir = NSTemporaryDirectory() + "findit_test_hidden_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        FileManager.default.createFile(atPath: (tmpDir as NSString).appendingPathComponent("visible.mp4"), contents: nil)
        FileManager.default.createFile(atPath: (tmpDir as NSString).appendingPathComponent(".hidden.mp4"), contents: nil)

        let results = try FileScanner.scanVideoFiles(in: tmpDir)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].hasSuffix("visible.mp4"))
    }

    func testSupportedExtensionsCount() {
        // 确保扩展名集合不为空且包含主要格式
        XCTAssertTrue(FileScanner.supportedExtensions.count >= 9)
        XCTAssertTrue(FileScanner.supportedExtensions.contains("mp4"))
        XCTAssertTrue(FileScanner.supportedExtensions.contains("mov"))
    }
}
