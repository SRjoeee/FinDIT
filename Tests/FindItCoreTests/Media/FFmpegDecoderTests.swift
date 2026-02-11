import XCTest
@testable import FindItCore

final class FFmpegDecoderTests: XCTestCase {

    // MARK: - Capability

    func testCapability() {
        let decoder = FFmpegDecoder()

        XCTAssertEqual(decoder.capability.name, "FFmpeg")
        XCTAssertEqual(decoder.capability.priority, 50)
        XCTAssertEqual(decoder.capability.fileExtensions.count, 9)

        // 验证所有 9 种格式
        let expected: Set<String> = ["mp4", "mov", "mkv", "avi", "mxf", "webm", "m4v", "ts", "mts"]
        XCTAssertEqual(decoder.capability.fileExtensions, expected)
    }

    func testSceneDetectableConformance() {
        let decoder = FFmpegDecoder()
        XCTAssertTrue(decoder is SceneDetectable)
    }

    // MARK: - Probe 输出解析

    func testParseDuration() {
        let decoder = FFmpegDecoder()
        let stderr = """
        Input #0, mov,mp4,m4a,3gp, from '/test/video.mp4':
          Duration: 00:05:23.45, start: 0.000000, bitrate: 12345 kb/s
            Stream #0:0: Video: h264 (High), 1920x1080, 30 fps
        """
        let result = decoder.parseProbeOutput(stderr, filePath: "/test/video.mp4")
        XCTAssertEqual(result.score, 70)
        XCTAssertEqual(result.mediaType, .video)
        XCTAssertEqual(result.duration!, 323.45, accuracy: 0.01)
    }

    func testParseVideoStream() {
        let decoder = FFmpegDecoder()
        let stderr = """
        Input #0, matroska,webm, from '/test/video.mkv':
          Duration: 01:30:00.00, start: 0.0, bitrate: 5000 kb/s
            Stream #0:0: Video: hevc (Main), 3840x2160 [SAR 1:1 DAR 16:9], 24 fps
            Stream #0:1: Audio: aac, 48000 Hz, stereo
        """
        let result = decoder.parseProbeOutput(stderr, filePath: "/test/video.mkv")
        XCTAssertEqual(result.score, 70)
        XCTAssertEqual(result.codec, "hevc")
        XCTAssertEqual(result.resolution?.width, 3840)
        XCTAssertEqual(result.resolution?.height, 2160)
        XCTAssertEqual(result.fps, 24.0)
        XCTAssertEqual(result.duration!, 5400.0, accuracy: 0.01)
    }

    func testParseContainerFormat() {
        let decoder = FFmpegDecoder()
        let stderr = """
        Input #0, avi, from '/test/video.avi':
          Duration: 00:01:00.00
            Stream #0:0: Video: mpeg4, 720x480, 29.97 fps
        """
        let result = decoder.parseProbeOutput(stderr, filePath: "/test/video.avi")
        XCTAssertEqual(result.containerFormat, "avi")
    }

    func testParseFractionalFps() {
        let decoder = FFmpegDecoder()
        let stderr = """
        Input #0, mov, from '/test/video.mov':
          Duration: 00:00:10.00
            Stream #0:0: Video: prores, 1920x1080, 29.97 fps
        """
        let result = decoder.parseProbeOutput(stderr, filePath: "/test/video.mov")
        XCTAssertEqual(result.fps!, 29.97, accuracy: 0.01)
    }

    func testParseTbrFps() {
        let decoder = FFmpegDecoder()
        let stderr = """
        Input #0, mpegts, from '/test/video.ts':
          Duration: 00:00:30.00
            Stream #0:0: Video: h264, 1280x720, 25 tbr
        """
        let result = decoder.parseProbeOutput(stderr, filePath: "/test/video.ts")
        XCTAssertEqual(result.fps, 25.0)
    }

    func testParseInvalidOutput() {
        let decoder = FFmpegDecoder()
        let stderr = "Not a valid ffmpeg output"
        let result = decoder.parseProbeOutput(stderr, filePath: "/test/file.bin")
        XCTAssertEqual(result.score, 0)
    }

    func testParseEmptyOutput() {
        let decoder = FFmpegDecoder()
        let result = decoder.parseProbeOutput("", filePath: "/test/file.bin")
        XCTAssertEqual(result.score, 0)
    }

    // MARK: - Probe (文件不存在)

    func testProbeNonExistentFile() async throws {
        let decoder = FFmpegDecoder()
        let result = try await decoder.probe(filePath: "/nonexistent/video.mp4")
        XCTAssertEqual(result.score, 0)
    }

    // MARK: - Init with config

    func testInitWithConfig() {
        let config = FFmpegConfig(ffmpegPath: "/usr/local/bin/ffmpeg")
        let decoder = FFmpegDecoder(config: config)
        XCTAssertEqual(decoder.capability.priority, 50)
    }
}
