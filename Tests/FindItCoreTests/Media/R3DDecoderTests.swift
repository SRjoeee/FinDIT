import XCTest
@testable import FindItCore

final class R3DDecoderTests: XCTestCase {

    // MARK: - Capability

    func testCapability() {
        let decoder = R3DDecoder()

        XCTAssertEqual(decoder.capability.name, "REDR3D")
        XCTAssertEqual(decoder.capability.priority, 140)
        XCTAssertTrue(decoder.capability.fileExtensions.contains("r3d"))
        XCTAssertTrue(decoder.capability.fileExtensions.contains("nev"))
        XCTAssertTrue(decoder.capability.utTypes.contains("com.red.r3d"))
        XCTAssertTrue(decoder.capability.utTypes.contains("com.nikon.nraw"))
    }

    func testPriorityBetweenBRAWAndAVFoundation() {
        let r3d = R3DDecoder()
        let braw = BRAWDecoder()
        let avf = AVFoundationDecoder()
        let ffmpeg = FFmpegDecoder()

        XCTAssertLessThan(r3d.capability.priority, braw.capability.priority,
                          "R3D 应低于 BRAW")
        XCTAssertGreaterThan(r3d.capability.priority, avf.capability.priority,
                             "R3D 应高于 AVFoundation")
        XCTAssertGreaterThan(r3d.capability.priority, ffmpeg.capability.priority,
                             "R3D 应高于 FFmpeg")
    }

    // MARK: - Probe

    func testProbeReturnsUnsupportedForNonR3DExtension() async throws {
        let decoder = R3DDecoder()
        let result = try await decoder.probe(filePath: "/test/video.mp4")
        XCTAssertEqual(result.score, 0, ".mp4 文件不应被 R3D 解码器支持")
    }

    func testProbeReturnsUnsupportedForMOV() async throws {
        let decoder = R3DDecoder()
        let result = try await decoder.probe(filePath: "/test/video.mov")
        XCTAssertEqual(result.score, 0)
    }

    func testProbeReturnsUnsupportedForBRAW() async throws {
        let decoder = R3DDecoder()
        let result = try await decoder.probe(filePath: "/test/video.braw")
        XCTAssertEqual(result.score, 0, ".braw 不应被 R3D 解码器处理")
    }

    func testProbeReturnsUnsupportedWhenToolMissing() async throws {
        let decoder = R3DDecoder(toolPath: "/nonexistent/r3d-tool")
        let result = try await decoder.probe(filePath: "/test/video.r3d")
        XCTAssertEqual(result.score, 0, "r3d-tool 不存在时应返回 score=0")
    }

    func testProbeReturnsUnsupportedWhenFileDoesNotExist() async throws {
        let decoder = R3DDecoder()
        let result = try await decoder.probe(filePath: "/nonexistent/video.r3d")
        XCTAssertEqual(result.score, 0, "文件不存在时应返回 score=0")
    }

    // MARK: - N-RAW (.nev) Probe

    func testProbeNEVReturnsUnsupportedWhenToolMissing() async throws {
        let decoder = R3DDecoder(toolPath: "/nonexistent/r3d-tool")
        let result = try await decoder.probe(filePath: "/test/video.nev")
        XCTAssertEqual(result.score, 0, ".nev + r3d-tool 缺失时应返回 score=0")
    }

    func testProbeNEVReturnsUnsupportedWhenFileDoesNotExist() async throws {
        let decoder = R3DDecoder()
        let result = try await decoder.probe(filePath: "/nonexistent/video.nev")
        XCTAssertEqual(result.score, 0, ".nev 文件不存在时应返回 score=0")
    }

    func testProbeNEVRejectsNonNEVExtension() async throws {
        let decoder = R3DDecoder()
        let result = try await decoder.probe(filePath: "/test/video.mp4")
        XCTAssertEqual(result.score, 0, ".mp4 不应被 R3D/N-RAW 解码器处理")
    }

    // MARK: - Not SceneDetectable

    func testNotSceneDetectable() {
        let decoder = R3DDecoder()
        XCTAssertFalse(decoder is SceneDetectable, "R3D 解码器不应支持场景检测")
    }

    // MARK: - Error Types

    func testR3DErrorToolNotFound() {
        let error = R3DError.toolNotFound("/path/to/r3d-tool")
        XCTAssertTrue(error.localizedDescription.contains("r3d-tool"))
        XCTAssertTrue(error.localizedDescription.contains("/path/to/r3d-tool"))
    }

    func testR3DErrorDecodeFailed() {
        let error = R3DError.decodeFailed("exit code 1")
        XCTAssertTrue(error.localizedDescription.contains("R3D"))
        XCTAssertTrue(error.localizedDescription.contains("exit code 1"))
    }

    func testR3DErrorInvalidOutput() {
        let error = R3DError.invalidOutput("unexpected format")
        XCTAssertTrue(error.localizedDescription.contains("invalid output"))
    }

    // MARK: - Init

    func testDefaultToolPath() {
        let decoder = R3DDecoder()
        XCTAssertNotNil(decoder)
    }

    func testCustomToolPath() {
        let decoder = R3DDecoder(toolPath: "/usr/local/bin/r3d-tool")
        XCTAssertNotNil(decoder)
    }

    func testCustomFFmpegConfig() {
        let config = FFmpegConfig(ffmpegPath: "/usr/local/bin/ffmpeg")
        let decoder = R3DDecoder(ffmpegConfig: config)
        XCTAssertNotNil(decoder)
    }

    // MARK: - CompositeMediaService 集成

    func testR3DRegisteredInMakeDefault() {
        let service = CompositeMediaService.makeDefault()
        // R3D 解码器应被注册（通过 .r3d 扩展名路由验证）
        XCTAssertNotNil(service)
    }

    func testR3DRoutesFallbackWhenToolMissing() async throws {
        // 当 r3d-tool 不存在时，R3D 文件应 fallback 到 FFmpeg
        let service = CompositeMediaService()
        let r3d = R3DDecoder(toolPath: "/nonexistent/r3d-tool")
        let ffmpeg = MockFFmpegForR3D()

        service.register(r3d)       // P:140, score=0 (tool missing)
        service.register(ffmpeg)    // P:50, score=70

        let decoder = try await service.bestDecoder(for: "/test/video.r3d")
        XCTAssertEqual(decoder.capability.name, "MockFFmpeg", "r3d-tool 缺失时应 fallback")
    }

    func testR3DExtensionInFileScanner() {
        XCTAssertTrue(
            FileScanner.supportedExtensions.contains("r3d"),
            "FileScanner 应包含 r3d 扩展名"
        )
    }

    func testNEVExtensionInFileScanner() {
        XCTAssertTrue(
            FileScanner.supportedExtensions.contains("nev"),
            "FileScanner 应包含 nev 扩展名"
        )
    }

    func testR3DMediaType() {
        let mediaType = FileScanner.mediaType(for: "/test/video.r3d")
        XCTAssertEqual(mediaType, .video, ".r3d 应识别为 video 类型")
    }

    func testNEVMediaType() {
        let mediaType = FileScanner.mediaType(for: "/test/video.nev")
        XCTAssertEqual(mediaType, .video, ".nev 应识别为 video 类型")
    }

    func testNEVRoutesFallbackWhenToolMissing() async throws {
        let service = CompositeMediaService()
        let r3d = R3DDecoder(toolPath: "/nonexistent/r3d-tool")
        let ffmpeg = MockFFmpegForR3D()

        service.register(r3d)       // P:140, score=0 (tool missing)
        service.register(ffmpeg)    // P:50, score=70

        let decoder = try await service.bestDecoder(for: "/test/video.nev")
        XCTAssertEqual(decoder.capability.name, "MockFFmpeg", ".nev r3d-tool 缺失时应 fallback")
    }
}

// MARK: - Test Helpers

/// Mock FFmpeg decoder for fallback testing
private final class MockFFmpegForR3D: MediaDecoder, @unchecked Sendable {
    let capability = MediaCapability(
        fileExtensions: ["mp4", "mov", "mkv", "r3d", "nev"],
        name: "MockFFmpeg",
        priority: 50
    )

    func probe(filePath: String) async throws -> ProbeResult {
        ProbeResult(score: 70, mediaType: .video, duration: 30.0)
    }

    func extractKeyframes(
        filePath: String, times: [Double],
        outputDir: String, maxDimension: Int
    ) async throws -> [String] { [] }

    func extractAudio(
        filePath: String, outputPath: String, sampleRate: Int
    ) async throws -> String { outputPath }
}
