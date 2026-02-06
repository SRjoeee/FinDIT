import XCTest
@testable import FindItCore

final class KeyframeExtractorTests: XCTestCase {

    // MARK: - framesPerScene

    func testFramesPerSceneShort() {
        // 3s → max(1, min(5, 3/5)) = max(1, 0) = 1
        XCTAssertEqual(KeyframeExtractor.framesPerScene(duration: 3.0), 1)
    }

    func testFramesPerSceneMedium() {
        // 15s → max(1, min(5, 15/5)) = max(1, 3) = 3
        XCTAssertEqual(KeyframeExtractor.framesPerScene(duration: 15.0), 3)
    }

    func testFramesPerSceneLong() {
        // 45s → max(1, min(5, 45/5)) = max(1, 5) → 5 (capped)
        XCTAssertEqual(KeyframeExtractor.framesPerScene(duration: 45.0), 5)
    }

    func testFramesPerSceneVeryLong() {
        // 100s → max(1, min(5, 100/5)) = max(1, 5) → 5 (capped)
        XCTAssertEqual(KeyframeExtractor.framesPerScene(duration: 100.0), 5)
    }

    func testFramesPerSceneExact5s() {
        // 5s → max(1, min(5, 5/5)) = max(1, 1) = 1
        XCTAssertEqual(KeyframeExtractor.framesPerScene(duration: 5.0), 1)
    }

    func testFramesPerSceneExact10s() {
        // 10s → max(1, min(5, 10/5)) = max(1, 2) = 2
        XCTAssertEqual(KeyframeExtractor.framesPerScene(duration: 10.0), 2)
    }

    func testFramesPerSceneZero() {
        // 0s → max(1, min(5, 0/5)) = max(1, 0) = 1
        XCTAssertEqual(KeyframeExtractor.framesPerScene(duration: 0), 1)
    }

    // MARK: - frameTimestamps

    func testFrameTimestampsSingleFrame() {
        let segment = SceneSegment(startTime: 10, endTime: 15)
        let timestamps = KeyframeExtractor.frameTimestamps(segment: segment, frameCount: 1)
        XCTAssertEqual(timestamps.count, 1)
        // 中点: 10 + 5/2 = 12.5
        XCTAssertEqual(timestamps[0], 12.5, accuracy: 0.01)
    }

    func testFrameTimestampsThreeFrames() {
        let segment = SceneSegment(startTime: 10, endTime: 25)
        let timestamps = KeyframeExtractor.frameTimestamps(segment: segment, frameCount: 3)
        XCTAssertEqual(timestamps.count, 3)
        // interval = 15/3 = 5, midpoints: 12.5, 17.5, 22.5
        XCTAssertEqual(timestamps[0], 12.5, accuracy: 0.01)
        XCTAssertEqual(timestamps[1], 17.5, accuracy: 0.01)
        XCTAssertEqual(timestamps[2], 22.5, accuracy: 0.01)
    }

    func testFrameTimestampsFromZero() {
        let segment = SceneSegment(startTime: 0, endTime: 10)
        let timestamps = KeyframeExtractor.frameTimestamps(segment: segment, frameCount: 2)
        // interval = 10/2 = 5, midpoints: 2.5, 7.5
        XCTAssertEqual(timestamps[0], 2.5, accuracy: 0.01)
        XCTAssertEqual(timestamps[1], 7.5, accuracy: 0.01)
    }

    func testFrameTimestampsZeroCount() {
        let segment = SceneSegment(startTime: 0, endTime: 10)
        let timestamps = KeyframeExtractor.frameTimestamps(segment: segment, frameCount: 0)
        XCTAssertTrue(timestamps.isEmpty)
    }

    // MARK: - buildExtractArguments

    func testBuildExtractArguments() {
        let args = KeyframeExtractor.buildExtractArguments(
            inputPath: "/video/test.mp4",
            timestamp: 12.5,
            outputPath: "/out/frame.jpg",
            config: .default
        )

        // -ss 在 -i 之前（输入 seek）
        let ssIndex = args.firstIndex(of: "-ss")!
        let iIndex = args.firstIndex(of: "-i")!
        XCTAssertTrue(ssIndex < iIndex, "-ss 应在 -i 之前用于快速 seek")

        XCTAssertTrue(args.contains("-vframes"))
        XCTAssertTrue(args.contains("1"))
        XCTAssertTrue(args.contains("-vf"))
        XCTAssertTrue(args.contains("-y"))
        XCTAssertEqual(args.last, "/out/frame.jpg")

        // 检查 scale filter 包含 512
        if let vfIndex = args.firstIndex(of: "-vf"), vfIndex + 1 < args.count {
            let filter = args[vfIndex + 1]
            XCTAssertTrue(filter.contains("512"), "scale filter 应包含 512px")
            XCTAssertTrue(filter.contains("scale"), "应使用 scale filter")
        }
    }

    func testBuildExtractArgumentsCustomConfig() {
        let config = KeyframeExtractor.Config(thumbnailShortEdge: 256, jpegQuality: 3)
        let args = KeyframeExtractor.buildExtractArguments(
            inputPath: "/v.mp4",
            timestamp: 5.0,
            outputPath: "/o.jpg",
            config: config
        )

        if let vfIndex = args.firstIndex(of: "-vf"), vfIndex + 1 < args.count {
            XCTAssertTrue(args[vfIndex + 1].contains("256"))
        }
        if let qIndex = args.firstIndex(of: "-q:v"), qIndex + 1 < args.count {
            XCTAssertEqual(args[qIndex + 1], "3")
        }
    }

    // MARK: - 输入验证

    func testExtractKeyframesFileNotFound() {
        let segments = [SceneSegment(startTime: 0, endTime: 10)]
        XCTAssertThrowsError(
            try KeyframeExtractor.extractKeyframes(
                inputPath: "/nonexistent/video.mp4",
                segments: segments,
                outputDirectory: "/tmp/out"
            )
        ) { error in
            guard case FFmpegError.inputFileNotFound = error else {
                XCTFail("应抛出 inputFileNotFound，实际: \(error)")
                return
            }
        }
    }

    // MARK: - Config

    func testDefaultConfig() {
        let config = KeyframeExtractor.Config.default
        XCTAssertEqual(config.thumbnailShortEdge, 512)
        XCTAssertEqual(config.jpegQuality, 5)
        XCTAssertEqual(config.maxFramesPerScene, 5)
        XCTAssertEqual(config.frameDurationDivisor, 5.0)
    }
}
