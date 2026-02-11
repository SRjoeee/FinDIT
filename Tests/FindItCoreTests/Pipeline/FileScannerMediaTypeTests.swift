import XCTest
@testable import FindItCore

final class FileScannerMediaTypeTests: XCTestCase {

    // MARK: - Video 扩展名

    func testVideoExtensions() {
        let videoExts = ["mp4", "mov", "mkv", "avi", "mxf", "webm", "m4v", "ts", "mts", "braw", "r3d"]
        for ext in videoExts {
            let result = FileScanner.mediaType(for: "/test/file.\(ext)")
            XCTAssertEqual(result, .video, "扩展名 .\(ext) 应该识别为 video")
        }
    }

    // MARK: - Photo 扩展名

    func testPhotoExtensions() {
        let photoExts = ["jpg", "jpeg", "png", "heic", "tiff", "webp", "raw", "dng"]
        for ext in photoExts {
            let result = FileScanner.mediaType(for: "/test/file.\(ext)")
            XCTAssertEqual(result, .photo, "扩展名 .\(ext) 应该识别为 photo")
        }
    }

    // MARK: - Audio 扩展名

    func testAudioExtensions() {
        let audioExts = ["mp3", "wav", "aac", "flac", "m4a", "aiff"]
        for ext in audioExts {
            let result = FileScanner.mediaType(for: "/test/file.\(ext)")
            XCTAssertEqual(result, .audio, "扩展名 .\(ext) 应该识别为 audio")
        }
    }

    // MARK: - 未知扩展名

    func testUnknownExtension() {
        XCTAssertNil(FileScanner.mediaType(for: "/test/file.txt"))
        XCTAssertNil(FileScanner.mediaType(for: "/test/file.pdf"))
        XCTAssertNil(FileScanner.mediaType(for: "/test/file.doc"))
        XCTAssertNil(FileScanner.mediaType(for: "/test/noext"))
    }

    // MARK: - 大小写不敏感

    func testCaseInsensitive() {
        XCTAssertEqual(FileScanner.mediaType(for: "/test/file.MP4"), .video)
        XCTAssertEqual(FileScanner.mediaType(for: "/test/file.JPG"), .photo)
        XCTAssertEqual(FileScanner.mediaType(for: "/test/file.MP3"), .audio)
        XCTAssertEqual(FileScanner.mediaType(for: "/test/file.MoV"), .video)
    }

    // MARK: - allSupportedExtensions

    func testAllSupportedExtensionsCoverage() {
        let all = FileScanner.allSupportedExtensions
        // video (11) + photo (8) + audio (6) = 25
        XCTAssertEqual(all.count, 25)
        XCTAssertTrue(all.isSuperset(of: FileScanner.supportedExtensions))
        XCTAssertTrue(all.isSuperset(of: FileScanner.photoExtensions))
        XCTAssertTrue(all.isSuperset(of: FileScanner.audioExtensions))
    }

    // MARK: - photoExtensions 集合

    func testPhotoExtensionsSet() {
        XCTAssertEqual(FileScanner.photoExtensions.count, 8)
    }

    // MARK: - audioExtensions 集合

    func testAudioExtensionsSet() {
        XCTAssertEqual(FileScanner.audioExtensions.count, 6)
    }
}
