import XCTest
@testable import FindItCore

final class MediaTypesTests: XCTestCase {

    // MARK: - MediaType

    func testMediaTypeRawValues() {
        XCTAssertEqual(MediaType.video.rawValue, "video")
        XCTAssertEqual(MediaType.photo.rawValue, "photo")
        XCTAssertEqual(MediaType.audio.rawValue, "audio")
    }

    func testMediaTypeCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let original = MediaType.video
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(MediaType.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - MediaCapability

    func testMediaCapabilityInit() {
        let cap = MediaCapability(
            fileExtensions: ["mp4", "mov"],
            utTypes: ["public.mpeg-4"],
            name: "TestDecoder",
            priority: 80
        )
        XCTAssertEqual(cap.fileExtensions, ["mp4", "mov"])
        XCTAssertEqual(cap.utTypes, ["public.mpeg-4"])
        XCTAssertEqual(cap.name, "TestDecoder")
        XCTAssertEqual(cap.priority, 80)
    }

    func testMediaCapabilityHashable() {
        let cap1 = MediaCapability(
            fileExtensions: ["mp4"], name: "A", priority: 50
        )
        let cap2 = MediaCapability(
            fileExtensions: ["mp4"], name: "A", priority: 50
        )
        let cap3 = MediaCapability(
            fileExtensions: ["mkv"], name: "B", priority: 40
        )

        XCTAssertEqual(cap1, cap2)
        XCTAssertNotEqual(cap1, cap3)

        var set = Set<MediaCapability>()
        set.insert(cap1)
        set.insert(cap2)
        XCTAssertEqual(set.count, 1)
    }

    func testMediaCapabilityDefaultUtTypes() {
        let cap = MediaCapability(
            fileExtensions: ["mp4"], name: "Test", priority: 50
        )
        XCTAssertTrue(cap.utTypes.isEmpty)
    }

    // MARK: - ProbeResult

    func testProbeResultInit() {
        let result = ProbeResult(
            score: 90,
            mediaType: .video,
            containerFormat: "mp4",
            codec: "h264",
            duration: 120.5,
            resolution: (width: 1920, height: 1080),
            fps: 30.0
        )
        XCTAssertEqual(result.score, 90)
        XCTAssertEqual(result.mediaType, .video)
        XCTAssertEqual(result.containerFormat, "mp4")
        XCTAssertEqual(result.codec, "h264")
        XCTAssertEqual(result.duration, 120.5)
        XCTAssertEqual(result.resolution?.width, 1920)
        XCTAssertEqual(result.resolution?.height, 1080)
        XCTAssertEqual(result.fps, 30.0)
    }

    func testProbeResultDefaults() {
        let result = ProbeResult(score: 50, mediaType: .video)
        XCTAssertNil(result.containerFormat)
        XCTAssertNil(result.codec)
        XCTAssertNil(result.duration)
        XCTAssertNil(result.resolution)
        XCTAssertNil(result.fps)
    }

    func testProbeResultUnsupported() {
        let result = ProbeResult.unsupported()
        XCTAssertEqual(result.score, 0)
        XCTAssertEqual(result.mediaType, .video)
    }

    func testProbeResultUnsupportedWithType() {
        let result = ProbeResult.unsupported(mediaType: .audio)
        XCTAssertEqual(result.score, 0)
        XCTAssertEqual(result.mediaType, .audio)
    }

    // MARK: - FormatSupportLevel

    func testFormatSupportLevelCases() {
        // 确保所有 case 都存在
        let levels: [FormatSupportLevel] = [.fullDecode, .metadataOnly, .unsupported]
        XCTAssertEqual(levels.count, 3)
    }

    // MARK: - MediaError

    func testMediaErrorNoDecoderAvailable() {
        let error = MediaError.noDecoderAvailable(path: "/test/video.r3d")
        XCTAssertTrue(error.localizedDescription.contains("/test/video.r3d"))
    }

    func testMediaErrorOperationNotSupported() {
        let error = MediaError.operationNotSupported("16kHz mono WAV")
        XCTAssertTrue(error.localizedDescription.contains("16kHz mono WAV"))
    }

    func testMediaErrorProbeFailed() {
        let underlying = NSError(domain: "test", code: 42)
        let error = MediaError.probeFailed(path: "/test.mp4", underlying: underlying)
        XCTAssertTrue(error.localizedDescription.contains("/test.mp4"))
    }

    func testMediaErrorDecodeFailed() {
        let underlying = NSError(domain: "test", code: 42)
        let error = MediaError.decodeFailed(path: "/test.mp4", underlying: underlying)
        XCTAssertTrue(error.localizedDescription.contains("/test.mp4"))
    }
}
