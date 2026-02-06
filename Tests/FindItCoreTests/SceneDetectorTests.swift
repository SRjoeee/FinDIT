import XCTest
@testable import FindItCore

final class SceneDetectorTests: XCTestCase {

    // MARK: - parseTimestamps

    func testParseTimestampsBasic() {
        let stderr = """
        [Parsed_showinfo_1 @ 0x14f604080] n:   0 pts:   5000 pts_time:5       duration:1 duration_time:0.04
        [Parsed_showinfo_1 @ 0x14f604080] n:   1 pts:  12500 pts_time:12.5     duration:1 duration_time:0.04
        [Parsed_showinfo_1 @ 0x14f604080] n:   2 pts:  45000 pts_time:45       duration:1 duration_time:0.04
        """
        let timestamps = SceneDetector.parseTimestamps(from: stderr)
        XCTAssertEqual(timestamps, [5.0, 12.5, 45.0])
    }

    func testParseTimestampsWithDecimal() {
        let stderr = "[Parsed_showinfo_1 @ 0x...] n:0 pts:0 pts_time:0.500 duration:1"
        let timestamps = SceneDetector.parseTimestamps(from: stderr)
        XCTAssertEqual(timestamps, [0.5])
    }

    func testParseTimestampsEmpty() {
        let timestamps = SceneDetector.parseTimestamps(from: "")
        XCTAssertTrue(timestamps.isEmpty)
    }

    func testParseTimestampsNoMatch() {
        let stderr = "Stream #0:0: Video: h264, yuv420p, 1920x1080, 25 fps"
        let timestamps = SceneDetector.parseTimestamps(from: stderr)
        XCTAssertTrue(timestamps.isEmpty)
    }

    func testParseTimestampsSorted() {
        let stderr = """
        [showinfo] pts_time:20
        [showinfo] pts_time:5
        [showinfo] pts_time:10
        """
        let timestamps = SceneDetector.parseTimestamps(from: stderr)
        XCTAssertEqual(timestamps, [5.0, 10.0, 20.0])
    }

    // MARK: - filterByMinGap

    func testFilterByMinGapRemovesClose() {
        // 0.5 和 0.8 间距 0.3s，小于 2.0s，应只保留 0.5
        let timestamps = [0.5, 0.8, 5.0, 12.5, 12.9, 45.0]
        let filtered = SceneDetector.filterByMinGap(timestamps, minGap: 2.0)
        XCTAssertEqual(filtered, [0.5, 5.0, 12.5, 45.0])
    }

    func testFilterByMinGapKeepsSpread() {
        let timestamps = [5.0, 15.0, 30.0, 60.0]
        let filtered = SceneDetector.filterByMinGap(timestamps, minGap: 2.0)
        XCTAssertEqual(filtered, [5.0, 15.0, 30.0, 60.0])
    }

    func testFilterByMinGapSingle() {
        let filtered = SceneDetector.filterByMinGap([10.0], minGap: 2.0)
        XCTAssertEqual(filtered, [10.0])
    }

    func testFilterByMinGapEmpty() {
        let filtered = SceneDetector.filterByMinGap([], minGap: 2.0)
        XCTAssertTrue(filtered.isEmpty)
    }

    func testFilterByMinGapAllClose() {
        let timestamps = [1.0, 1.5, 1.8, 2.1]
        let filtered = SceneDetector.filterByMinGap(timestamps, minGap: 2.0)
        // 只保留第一个，因为 2.1-1.0=1.1 < 2.0
        XCTAssertEqual(filtered, [1.0])
    }

    // MARK: - segmentsFromCutPoints

    func testSegmentsBasic() {
        let segments = SceneDetector.segmentsFromCutPoints([5.0, 12.5, 45.0], videoDuration: 120.0)
        XCTAssertEqual(segments.count, 4)
        XCTAssertEqual(segments[0], SceneSegment(startTime: 0, endTime: 5.0))
        XCTAssertEqual(segments[1], SceneSegment(startTime: 5.0, endTime: 12.5))
        XCTAssertEqual(segments[2], SceneSegment(startTime: 12.5, endTime: 45.0))
        XCTAssertEqual(segments[3], SceneSegment(startTime: 45.0, endTime: 120.0))
    }

    func testSegmentsNoCutPoints() {
        let segments = SceneDetector.segmentsFromCutPoints([], videoDuration: 60.0)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0], SceneSegment(startTime: 0, endTime: 60.0))
    }

    func testSegmentsSingleCutPoint() {
        let segments = SceneDetector.segmentsFromCutPoints([30.0], videoDuration: 60.0)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0], SceneSegment(startTime: 0, endTime: 30.0))
        XCTAssertEqual(segments[1], SceneSegment(startTime: 30.0, endTime: 60.0))
    }

    func testSegmentsCutAtStart() {
        // 切点在 0.001 附近（几乎是开头），不产生极短的首片段
        let segments = SceneDetector.segmentsFromCutPoints([0.005, 10.0], videoDuration: 30.0)
        // 0.005 > 0.01 为 false, 所以不产生 0-0.005 的片段
        XCTAssertTrue(segments.count >= 2)
    }

    // MARK: - mergeShortSegments

    func testMergeShortLeading() {
        let segments = [
            SceneSegment(startTime: 0, endTime: 1),     // 1s - 太短
            SceneSegment(startTime: 1, endTime: 10),     // 9s - OK
            SceneSegment(startTime: 10, endTime: 20),    // 10s - OK
        ]
        let merged = SceneDetector.mergeShortSegments(segments, minDuration: 2.0)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0], SceneSegment(startTime: 0, endTime: 10))
        XCTAssertEqual(merged[1], SceneSegment(startTime: 10, endTime: 20))
    }

    func testMergeShortConsecutive() {
        let segments = [
            SceneSegment(startTime: 0, endTime: 0.5),   // 太短
            SceneSegment(startTime: 0.5, endTime: 1.2),  // 太短
            SceneSegment(startTime: 1.2, endTime: 10),    // 连续合并后 OK
        ]
        let merged = SceneDetector.mergeShortSegments(segments, minDuration: 2.0)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0], SceneSegment(startTime: 0, endTime: 10))
    }

    func testMergeNothingToMerge() {
        let segments = [
            SceneSegment(startTime: 0, endTime: 5),
            SceneSegment(startTime: 5, endTime: 15),
        ]
        let merged = SceneDetector.mergeShortSegments(segments, minDuration: 2.0)
        XCTAssertEqual(merged.count, 2)
    }

    func testMergeSingleSegment() {
        let segments = [SceneSegment(startTime: 0, endTime: 1)]
        let merged = SceneDetector.mergeShortSegments(segments, minDuration: 2.0)
        XCTAssertEqual(merged.count, 1)
    }

    // MARK: - splitLongSegments

    func testSplitLongBasic() {
        let segments = [SceneSegment(startTime: 0, endTime: 45)]
        let split = SceneDetector.splitLongSegments(segments, maxDuration: 30, interval: 15)
        // 45s 按 15s 拆 → [0-15, 15-30, 30-45]
        XCTAssertEqual(split.count, 3)
        XCTAssertEqual(split[0].startTime, 0, accuracy: 0.01)
        XCTAssertEqual(split[0].endTime, 15, accuracy: 0.01)
        XCTAssertEqual(split[1].startTime, 15, accuracy: 0.01)
        XCTAssertEqual(split[1].endTime, 30, accuracy: 0.01)
        XCTAssertEqual(split[2].startTime, 30, accuracy: 0.01)
        XCTAssertEqual(split[2].endTime, 45, accuracy: 0.01)
    }

    func testSplitLongMergesShortTail() {
        // 35s 按 15s: [0-15, 15-35]（尾部 5s < 7.5s = 15*0.5，合并到上一段）
        let segments = [SceneSegment(startTime: 0, endTime: 35)]
        let split = SceneDetector.splitLongSegments(segments, maxDuration: 30, interval: 15)
        XCTAssertEqual(split.count, 2)
        XCTAssertEqual(split[0].endTime, 15, accuracy: 0.01)
        XCTAssertEqual(split[1].endTime, 35, accuracy: 0.01)
    }

    func testSplitNoSplitNeeded() {
        let segments = [
            SceneSegment(startTime: 0, endTime: 10),
            SceneSegment(startTime: 10, endTime: 25),
        ]
        let split = SceneDetector.splitLongSegments(segments, maxDuration: 30, interval: 15)
        XCTAssertEqual(split.count, 2)
    }

    func testSplitExactlyAtMax() {
        let segments = [SceneSegment(startTime: 0, endTime: 30)]
        let split = SceneDetector.splitLongSegments(segments, maxDuration: 30, interval: 15)
        // 30s == maxDuration，不拆
        XCTAssertEqual(split.count, 1)
    }

    func testSplitMixedSegments() {
        let segments = [
            SceneSegment(startTime: 0, endTime: 5),      // 短，不拆
            SceneSegment(startTime: 5, endTime: 50),      // 45s > 30s，拆
            SceneSegment(startTime: 50, endTime: 60),     // 短，不拆
        ]
        let split = SceneDetector.splitLongSegments(segments, maxDuration: 30, interval: 15)
        // 第一个 5s，第二个拆为 [5-20, 20-35, 35-50]，第三个 10s
        XCTAssertTrue(split.count >= 4)
        XCTAssertEqual(split.first!.startTime, 0, accuracy: 0.01)
        XCTAssertEqual(split.last!.endTime, 60, accuracy: 0.01)
    }

    // MARK: - buildDetectionArguments

    func testBuildDetectionArguments() {
        let args = SceneDetector.buildDetectionArguments(
            inputPath: "/video/test.mp4",
            threshold: 0.3
        )
        XCTAssertEqual(args[0], "-i")
        XCTAssertEqual(args[1], "/video/test.mp4")
        XCTAssertTrue(args.contains("-fps_mode"))
        XCTAssertTrue(args.contains("vfr"))
        XCTAssertTrue(args.contains("-f"))
        XCTAssertTrue(args.contains("null"))

        // -vf 参数应包含阈值
        if let vfIndex = args.firstIndex(of: "-vf"), vfIndex + 1 < args.count {
            let vfValue = args[vfIndex + 1]
            XCTAssertTrue(vfValue.contains("scene,0.3"), "应包含场景阈值")
            XCTAssertTrue(vfValue.contains("showinfo"), "应包含 showinfo")
        } else {
            XCTFail("未找到 -vf 参数")
        }
    }

    // MARK: - SceneSegment

    func testSceneSegmentDuration() {
        let segment = SceneSegment(startTime: 5.0, endTime: 15.0)
        XCTAssertEqual(segment.duration, 10.0, accuracy: 0.01)
    }

    func testSceneSegmentEquality() {
        let a = SceneSegment(startTime: 0, endTime: 10)
        let b = SceneSegment(startTime: 0, endTime: 10)
        XCTAssertEqual(a, b)
    }

    // MARK: - 完整流水线（模拟 FFmpeg 输出）

    func testFullPipelineNoSceneChanges() {
        // 无场景变化 → 整个视频为一个场景（可能被长镜头拆分）
        let timestamps: [Double] = []
        let filtered = SceneDetector.filterByMinGap(timestamps, minGap: 2.0)
        var segments = SceneDetector.segmentsFromCutPoints(filtered, videoDuration: 120.0)
        segments = SceneDetector.mergeShortSegments(segments, minDuration: 2.0)
        segments = SceneDetector.splitLongSegments(segments, maxDuration: 30.0, interval: 15.0)

        // 120s 无切点 → [0-15, 15-30, 30-45, 45-60, 60-75, 75-90, 90-105, 105-120]
        XCTAssertTrue(segments.count > 1, "长视频应被拆分")
        XCTAssertEqual(segments.first!.startTime, 0, accuracy: 0.01)
        XCTAssertEqual(segments.last!.endTime, 120, accuracy: 0.01)
    }

    func testFullPipelineTypicalVideo() {
        // 模拟 60s 视频，3 个场景变化
        let stderr = """
        [Parsed_showinfo_1 @ 0x...] pts_time:10.5
        [Parsed_showinfo_1 @ 0x...] pts_time:25.0
        [Parsed_showinfo_1 @ 0x...] pts_time:42.0
        """
        let timestamps = SceneDetector.parseTimestamps(from: stderr)
        let filtered = SceneDetector.filterByMinGap(timestamps, minGap: 2.0)
        var segments = SceneDetector.segmentsFromCutPoints(filtered, videoDuration: 60.0)
        segments = SceneDetector.mergeShortSegments(segments, minDuration: 2.0)
        segments = SceneDetector.splitLongSegments(segments, maxDuration: 30.0, interval: 15.0)

        // 切点 [10.5, 25, 42] → 4 片段 [0-10.5, 10.5-25, 25-42, 42-60]
        // 所有片段都 < 30s，不需要拆分
        XCTAssertEqual(segments.count, 4)
        XCTAssertEqual(segments[0].startTime, 0, accuracy: 0.01)
        XCTAssertEqual(segments[0].endTime, 10.5, accuracy: 0.01)
        XCTAssertEqual(segments[3].startTime, 42, accuracy: 0.01)
        XCTAssertEqual(segments[3].endTime, 60, accuracy: 0.01)
    }
}
