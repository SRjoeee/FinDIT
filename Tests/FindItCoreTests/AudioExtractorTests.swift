import XCTest
@testable import FindItCore

final class AudioExtractorTests: XCTestCase {

    // MARK: - 命令参数构造（纯单元测试）

    func testBuildArguments() {
        let args = AudioExtractor.buildArguments(
            inputPath: "/video/test.mp4",
            outputPath: "/audio/test.wav"
        )
        XCTAssertEqual(args[0], "-i")
        XCTAssertEqual(args[1], "/video/test.mp4")
        XCTAssertTrue(args.contains("-vn"), "应禁用视频流")
        XCTAssertTrue(args.contains("-acodec"), "应指定音频编码")
        XCTAssertTrue(args.contains("pcm_s16le"), "应使用 16-bit PCM")
        XCTAssertTrue(args.contains("-ar"), "应指定采样率")
        XCTAssertTrue(args.contains("16000"), "采样率应为 16000")
        XCTAssertTrue(args.contains("-ac"), "应指定声道数")
        XCTAssertTrue(args.contains("1"), "应为单声道")
        XCTAssertTrue(args.contains("-y"), "应允许覆盖")
        XCTAssertEqual(args.last, "/audio/test.wav", "最后参数应为输出路径")
    }

    func testBuildArgumentsWithChinesePath() {
        let args = AudioExtractor.buildArguments(
            inputPath: "/素材/海滩日落.mp4",
            outputPath: "/输出/音频.wav"
        )
        XCTAssertEqual(args[1], "/素材/海滩日落.mp4")
        XCTAssertEqual(args.last, "/输出/音频.wav")
    }

    // MARK: - 输入验证

    func testExtractAudioFileNotFound() {
        XCTAssertThrowsError(
            try AudioExtractor.extractAudio(
                inputPath: "/nonexistent/video.mp4",
                outputPath: "/tmp/out.wav"
            )
        ) { error in
            guard case FFmpegError.inputFileNotFound = error else {
                XCTFail("应抛出 inputFileNotFound，实际: \(error)")
                return
            }
        }
    }
}
