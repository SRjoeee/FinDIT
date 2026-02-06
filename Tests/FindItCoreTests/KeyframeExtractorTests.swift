import XCTest
@testable import FindItCore

final class KeyframeExtractorTests: XCTestCase {

    // MARK: - framesPerScene

    func testFramesPerSceneShort() {
        // 3s → max(1, min(3, 3/5)) = max(1, 0) = 1
        XCTAssertEqual(KeyframeExtractor.framesPerScene(duration: 3.0), 1)
    }

    func testFramesPerSceneMedium() {
        // 15s → max(1, min(3, 15/5)) = max(1, 3) = 3 (capped)
        XCTAssertEqual(KeyframeExtractor.framesPerScene(duration: 15.0), 3)
    }

    func testFramesPerSceneLong() {
        // 45s → max(1, min(3, 45/5)) = max(1, 3) → 3 (capped)
        XCTAssertEqual(KeyframeExtractor.framesPerScene(duration: 45.0), 3)
    }

    func testFramesPerSceneVeryLong() {
        // 100s → max(1, min(3, 100/5)) = max(1, 3) → 3 (capped)
        XCTAssertEqual(KeyframeExtractor.framesPerScene(duration: 100.0), 3)
    }

    func testFramesPerSceneExact5s() {
        // 5s → max(1, min(3, 5/5)) = max(1, 1) = 1
        XCTAssertEqual(KeyframeExtractor.framesPerScene(duration: 5.0), 1)
    }

    func testFramesPerSceneExact10s() {
        // 10s → max(1, min(3, 10/5)) = max(1, 2) = 2
        XCTAssertEqual(KeyframeExtractor.framesPerScene(duration: 10.0), 2)
    }

    func testFramesPerSceneZero() {
        // 0s → max(1, min(3, 0/5)) = max(1, 0) = 1
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

    // MARK: - buildBatchExtractArguments (相对时间戳)

    func testBatchExtractUsesRelativeTimestamps() {
        // 场景 [10.0, 25.0], 绝对时间戳 [12.5, 17.5, 22.5]
        // -ss 10.0 使 FFmpeg t 从 ~0 开始，select 必须用相对时间戳
        let segment = SceneSegment(startTime: 10.0, endTime: 25.0)
        let timestamps = [12.5, 17.5, 22.5]  // 绝对
        let args = KeyframeExtractor.buildBatchExtractArguments(
            inputPath: "/video.mp4",
            segment: segment,
            timestamps: timestamps,
            outputPattern: "/out/scene_%02d.jpg",
            config: .default
        )

        // 找到 -vf 参数中的 select 表达式
        guard let vfIndex = args.firstIndex(of: "-vf"),
              vfIndex + 1 < args.count else {
            XCTFail("应包含 -vf 参数")
            return
        }
        let filter = args[vfIndex + 1]

        // 应使用相对时间戳: 12.5-10.0=2.5, 17.5-10.0=7.5, 22.5-10.0=12.5
        XCTAssertTrue(filter.contains("2.500"), "应包含相对时间戳 2.500 (12.5-10.0)")
        XCTAssertTrue(filter.contains("7.500"), "应包含相对时间戳 7.500 (17.5-10.0)")
        XCTAssertTrue(filter.contains("12.500"), "应包含相对时间戳 12.500 (22.5-10.0)")

        // 不应包含原始绝对时间戳 17.500 或 22.500（注意 12.500 碰巧与相对值重合）
        // 验证没有 17.500 和 22.500（这些是绝对值）
        // 但 17.500 不应出现因为 17.5-10=7.5
        XCTAssertFalse(filter.contains("17.500"), "不应包含绝对时间戳 17.500")
        XCTAssertFalse(filter.contains("22.500"), "不应包含绝对时间戳 22.500")
    }

    func testBatchExtractFromZeroStartTime() {
        // 场景 [0, 15], 时间戳 [2.5, 7.5, 12.5]
        // startTime=0 时绝对 == 相对
        let segment = SceneSegment(startTime: 0, endTime: 15.0)
        let timestamps = [2.5, 7.5, 12.5]
        let args = KeyframeExtractor.buildBatchExtractArguments(
            inputPath: "/video.mp4",
            segment: segment,
            timestamps: timestamps,
            outputPattern: "/out/scene_%02d.jpg",
            config: .default
        )

        guard let vfIndex = args.firstIndex(of: "-vf"),
              vfIndex + 1 < args.count else {
            XCTFail("应包含 -vf 参数")
            return
        }
        let filter = args[vfIndex + 1]

        // startTime=0，相对值 == 绝对值
        XCTAssertTrue(filter.contains("2.500"))
        XCTAssertTrue(filter.contains("7.500"))
        XCTAssertTrue(filter.contains("12.500"))
    }

    func testBatchExtractSelectTolerance() {
        let segment = SceneSegment(startTime: 5.0, endTime: 20.0)
        let timestamps = [7.5, 12.5]
        let args = KeyframeExtractor.buildBatchExtractArguments(
            inputPath: "/video.mp4",
            segment: segment,
            timestamps: timestamps,
            outputPattern: "/out/%02d.jpg",
            config: .default
        )

        guard let vfIndex = args.firstIndex(of: "-vf"),
              vfIndex + 1 < args.count else {
            XCTFail("应包含 -vf 参数")
            return
        }
        let filter = args[vfIndex + 1]

        // 验证 0.05s 容差存在
        XCTAssertTrue(filter.contains("0.05"), "select 表达式应包含 0.05s 容差")
        // 验证使用相对时间戳: 7.5-5.0=2.5, 12.5-5.0=7.5
        XCTAssertTrue(filter.contains("2.500"), "应包含相对时间戳 2.500")
        XCTAssertTrue(filter.contains("7.500"), "应包含相对时间戳 7.500")
    }

    func testBatchExtractHasCorrectStructure() {
        let segment = SceneSegment(startTime: 30.0, endTime: 60.0)
        let timestamps = [35.0, 45.0, 55.0]
        let args = KeyframeExtractor.buildBatchExtractArguments(
            inputPath: "/video.mp4",
            segment: segment,
            timestamps: timestamps,
            outputPattern: "/out/%02d.jpg",
            config: .default
        )

        // -ss 在 -i 之前
        let ssIndex = args.firstIndex(of: "-ss")!
        let iIndex = args.firstIndex(of: "-i")!
        XCTAssertTrue(ssIndex < iIndex, "-ss 应在 -i 之前")

        // -to 在 -i 之前
        let toIndex = args.firstIndex(of: "-to")!
        XCTAssertTrue(toIndex < iIndex, "-to 应在 -i 之前")

        // 包含 -fps_mode vfr
        XCTAssertTrue(args.contains("-fps_mode"))
        XCTAssertTrue(args.contains("vfr"))

        // -ss 值应为 segment.startTime
        XCTAssertEqual(args[ssIndex + 1], "30.000")
        // -to 值应为 segment.endTime
        XCTAssertEqual(args[toIndex + 1], "60.000")
    }

    // MARK: - Config

    func testDefaultConfig() {
        let config = KeyframeExtractor.Config.default
        XCTAssertEqual(config.thumbnailShortEdge, 512)
        XCTAssertEqual(config.jpegQuality, 5)
        XCTAssertEqual(config.maxFramesPerScene, 3)
        XCTAssertEqual(config.frameDurationDivisor, 5.0)
    }
}
