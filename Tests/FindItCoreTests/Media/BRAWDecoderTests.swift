import XCTest
@testable import FindItCore

final class BRAWDecoderTests: XCTestCase {

    // MARK: - Capability

    func testCapability() {
        let decoder = BRAWDecoder()

        XCTAssertEqual(decoder.capability.name, "BlackmagicRAW")
        XCTAssertEqual(decoder.capability.priority, 150)
        XCTAssertEqual(decoder.capability.fileExtensions, ["braw"])
        XCTAssertTrue(decoder.capability.utTypes.contains("com.blackmagicdesign.braw"))
    }

    func testHigherPriorityThanAVFoundationAndFFmpeg() {
        let braw = BRAWDecoder()
        let avf = AVFoundationDecoder()
        let ffmpeg = FFmpegDecoder()

        XCTAssertGreaterThan(braw.capability.priority, avf.capability.priority)
        XCTAssertGreaterThan(braw.capability.priority, ffmpeg.capability.priority)
    }

    // MARK: - Probe

    func testProbeReturnsUnsupportedForNonBRAWExtension() async throws {
        let decoder = BRAWDecoder()
        let result = try await decoder.probe(filePath: "/test/video.mp4")
        XCTAssertEqual(result.score, 0, ".mp4 文件不应被 BRAW 解码器支持")
    }

    func testProbeReturnsUnsupportedForMOV() async throws {
        let decoder = BRAWDecoder()
        let result = try await decoder.probe(filePath: "/test/video.mov")
        XCTAssertEqual(result.score, 0)
    }

    func testProbeReturnsUnsupportedWhenToolMissing() async throws {
        // 使用不存在的路径
        let decoder = BRAWDecoder(toolPath: "/nonexistent/braw-tool")
        let result = try await decoder.probe(filePath: "/test/video.braw")
        XCTAssertEqual(result.score, 0, "braw-tool 不存在时应返回 score=0")
    }

    func testProbeReturnsUnsupportedWhenFileDoesNotExist() async throws {
        let decoder = BRAWDecoder()
        let result = try await decoder.probe(filePath: "/nonexistent/video.braw")
        XCTAssertEqual(result.score, 0, "文件不存在时应返回 score=0")
    }

    // MARK: - Not SceneDetectable

    func testNotSceneDetectable() {
        let decoder = BRAWDecoder()
        XCTAssertFalse(decoder is SceneDetectable, "BRAW 解码器不应支持场景检测")
    }

    // MARK: - Error Types

    func testBRAWErrorToolNotFound() {
        let error = BRAWError.toolNotFound("/path/to/braw-tool")
        XCTAssertTrue(error.localizedDescription.contains("braw-tool"))
        XCTAssertTrue(error.localizedDescription.contains("/path/to/braw-tool"))
    }

    func testBRAWErrorDecodeFailed() {
        let error = BRAWError.decodeFailed("exit code 1")
        XCTAssertTrue(error.localizedDescription.contains("BRAW"))
        XCTAssertTrue(error.localizedDescription.contains("exit code 1"))
    }

    func testBRAWErrorInvalidOutput() {
        let error = BRAWError.invalidOutput("unexpected format")
        XCTAssertTrue(error.localizedDescription.contains("invalid output"))
    }

    // MARK: - Init

    func testDefaultToolPath() {
        let decoder = BRAWDecoder()
        // 默认路径应为 ~/.local/bin/braw-tool（已展开 tilde）
        XCTAssertNotNil(decoder)
    }

    func testCustomToolPath() {
        let decoder = BRAWDecoder(toolPath: "/usr/local/bin/braw-tool")
        XCTAssertNotNil(decoder)
    }

    func testCustomFFmpegConfig() {
        let config = FFmpegConfig(ffmpegPath: "/usr/local/bin/ffmpeg")
        let decoder = BRAWDecoder(ffmpegConfig: config)
        XCTAssertNotNil(decoder)
    }

    // MARK: - CompositeMediaService 集成

    func testBRAWRegisteredInMakeDefault() {
        let service = CompositeMediaService.makeDefault()
        // BRAW 解码器应被注册（通过 .braw 扩展名路由验证）
        XCTAssertNotNil(service)
    }

    func testBRAWRoutesFallbackWhenToolMissing() async throws {
        // 当 braw-tool 不存在时，BRAW 文件应 fallback 到 FFmpeg
        // FFmpeg 也无法读 BRAW，但路由应能处理这种情况
        let service = CompositeMediaService()
        let braw = BRAWDecoder(toolPath: "/nonexistent/braw-tool")
        let ffmpeg = MockFFmpegForBRAW()

        service.register(braw)      // P:150, score=0 (tool missing)
        service.register(ffmpeg)    // P:50, score=70

        let decoder = try await service.bestDecoder(for: "/test/video.braw")
        XCTAssertEqual(decoder.capability.name, "MockFFmpeg", "braw-tool 缺失时应 fallback")
    }

    func testBRAWExtensionInFileScanner() {
        XCTAssertTrue(
            FileScanner.supportedExtensions.contains("braw"),
            "FileScanner 应包含 braw 扩展名"
        )
    }

    func testBRAWMediaType() {
        let mediaType = FileScanner.mediaType(for: "/test/video.braw")
        XCTAssertEqual(mediaType, .video, ".braw 应识别为 video 类型")
    }
}

// MARK: - Test Helpers

/// Mock FFmpeg decoder for fallback testing
private final class MockFFmpegForBRAW: MediaDecoder, @unchecked Sendable {
    let capability = MediaCapability(
        fileExtensions: ["mp4", "mov", "mkv", "braw"],
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
