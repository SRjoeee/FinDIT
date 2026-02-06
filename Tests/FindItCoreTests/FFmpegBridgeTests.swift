import XCTest
@testable import FindItCore

final class FFmpegBridgeTests: XCTestCase {

    // MARK: - FFmpegConfig

    func testDefaultConfig() {
        let config = FFmpegConfig.default
        XCTAssertTrue(config.ffmpegPath.hasSuffix(".local/bin/ffmpeg"))
        XCTAssertEqual(config.defaultTimeout, 300)
    }

    func testCustomConfig() {
        let config = FFmpegConfig(ffmpegPath: "/usr/local/bin/ffmpeg", defaultTimeout: 60)
        XCTAssertEqual(config.ffmpegPath, "/usr/local/bin/ffmpeg")
        XCTAssertEqual(config.defaultTimeout, 60)
    }

    // MARK: - Duration 解析（纯单元测试）

    func testParseDurationBasic() {
        let stderr = """
        Input #0, mov,mp4,m4a,3gp,3g2,mj2, from '/path/video.mp4':
          Duration: 00:02:30.50, start: 0.000000, bitrate: 5000 kb/s
        """
        let duration = FFmpegBridge.parseDuration(from: stderr)
        XCTAssertNotNil(duration)
        XCTAssertEqual(duration!, 150.50, accuracy: 0.01)
    }

    func testParseDurationHours() {
        let stderr = "  Duration: 01:30:00.00, start: 0.000000"
        let duration = FFmpegBridge.parseDuration(from: stderr)
        XCTAssertEqual(duration!, 5400.0, accuracy: 0.01)
    }

    func testParseDurationShort() {
        let stderr = "  Duration: 00:00:05.25, start: 0.000000"
        let duration = FFmpegBridge.parseDuration(from: stderr)
        XCTAssertEqual(duration!, 5.25, accuracy: 0.01)
    }

    func testParseDurationNotFound() {
        let stderr = "No duration info here"
        let duration = FFmpegBridge.parseDuration(from: stderr)
        XCTAssertNil(duration)
    }

    func testParseDurationEmpty() {
        let duration = FFmpegBridge.parseDuration(from: "")
        XCTAssertNil(duration)
    }

    // MARK: - validateExecutable（集成测试）

    func testValidateExecutableDefault() throws {
        // 默认路径应该存在（~/.local/bin/ffmpeg）
        try FFmpegBridge.validateExecutable()
    }

    func testValidateExecutableInvalidPath() {
        let config = FFmpegConfig(ffmpegPath: "/nonexistent/ffmpeg")
        XCTAssertThrowsError(try FFmpegBridge.validateExecutable(config: config)) { error in
            guard case FFmpegError.executableNotFound = error else {
                XCTFail("应抛出 executableNotFound，实际: \(error)")
                return
            }
        }
    }

    // MARK: - version（集成测试）

    func testVersion() throws {
        let version = try FFmpegBridge.version()
        XCTAssertTrue(version.contains("ffmpeg"), "版本信息应包含 'ffmpeg'")
    }

    // MARK: - run（集成测试）

    func testRunWithInvalidArgs() {
        XCTAssertThrowsError(try FFmpegBridge.run(arguments: ["-invalid_flag_xyz"])) { error in
            guard case FFmpegError.processExitedWithError = error else {
                XCTFail("应抛出 processExitedWithError，实际: \(error)")
                return
            }
        }
    }

    func testRunCapturesStdout() throws {
        let result = try FFmpegBridge.run(arguments: ["-version"])
        XCTAssertFalse(result.stdout.isEmpty, "stdout 不应为空")
        XCTAssertEqual(result.exitCode, 0)
    }

    // MARK: - FFmpegError

    func testErrorDescriptions() {
        let errors: [FFmpegError] = [
            .executableNotFound(path: "/path"),
            .inputFileNotFound(path: "/video.mp4"),
            .processExitedWithError(exitCode: 1, stderr: "error info"),
            .timeout(seconds: 300),
            .outputParsingFailed(detail: "no data"),
            .outputFileNotCreated(path: "/out.wav"),
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "\(error) 应有描述")
        }
    }
}
