import XCTest
@testable import FindItCore

final class AVFoundationDecoderTests: XCTestCase {

    // MARK: - Capability

    func testCapability() {
        let decoder = AVFoundationDecoder()

        XCTAssertEqual(decoder.capability.name, "AVFoundation")
        XCTAssertEqual(decoder.capability.priority, 80)
        XCTAssertEqual(decoder.capability.fileExtensions, ["mp4", "mov", "m4v"])
        XCTAssertFalse(decoder.capability.utTypes.isEmpty)
    }

    func testPriorityHigherThanFFmpeg() {
        let avf = AVFoundationDecoder()
        let ffmpeg = FFmpegDecoder()
        XCTAssertGreaterThan(avf.capability.priority, ffmpeg.capability.priority)
    }

    // MARK: - SceneDetectable

    func testNotSceneDetectable() {
        let decoder = AVFoundationDecoder()
        XCTAssertFalse(decoder is SceneDetectable, "AVFoundationDecoder 不应实现 SceneDetectable")
    }

    // MARK: - extractAudio

    func testExtractAudioThrowsNotSupported() async {
        let decoder = AVFoundationDecoder()
        do {
            _ = try await decoder.extractAudio(
                filePath: "/test/video.mp4",
                outputPath: "/tmp/audio.wav",
                sampleRate: 16000
            )
            XCTFail("应该抛出 operationNotSupported")
        } catch let error as MediaError {
            if case .operationNotSupported(let msg) = error {
                XCTAssertTrue(msg.contains("16000"), "错误信息应包含采样率")
            } else {
                XCTFail("应该是 operationNotSupported 错误，实际: \(error)")
            }
        } catch {
            XCTFail("应该抛出 MediaError，实际: \(error)")
        }
    }

    // MARK: - Probe (文件不存在)

    func testProbeNonExistentFile() async throws {
        let decoder = AVFoundationDecoder()
        let result = try await decoder.probe(filePath: "/nonexistent/video.mp4")
        XCTAssertEqual(result.score, 0)
    }
}
