import XCTest
@testable import FindItCore

final class FixedIntervalFallbackTests: XCTestCase {

    // MARK: - 基本分段

    func testFixedInterval120Seconds() {
        let segments = LayeredIndexer.fixedIntervalSegments(duration: 120.0)
        XCTAssertEqual(segments.count, 12, "120s / 10s = 12 segments")

        // 验证首段
        XCTAssertEqual(segments[0].startTime, 0.0, accuracy: 0.001)
        XCTAssertEqual(segments[0].endTime, 10.0, accuracy: 0.001)

        // 验证末段
        XCTAssertEqual(segments[11].startTime, 110.0, accuracy: 0.001)
        XCTAssertEqual(segments[11].endTime, 120.0, accuracy: 0.001)
    }

    func testFixedIntervalShortVideo() {
        let segments = LayeredIndexer.fixedIntervalSegments(duration: 5.0)
        XCTAssertEqual(segments.count, 1, "5s 视频应只有 1 段")
        XCTAssertEqual(segments[0].startTime, 0.0, accuracy: 0.001)
        XCTAssertEqual(segments[0].endTime, 5.0, accuracy: 0.001)
    }

    func testFixedIntervalExactMultiple() {
        let segments = LayeredIndexer.fixedIntervalSegments(duration: 30.0)
        XCTAssertEqual(segments.count, 3, "30s / 10s = 3 segments")

        for (i, seg) in segments.enumerated() {
            XCTAssertEqual(seg.startTime, Double(i) * 10.0, accuracy: 0.001)
            XCTAssertEqual(seg.endTime, Double(i + 1) * 10.0, accuracy: 0.001)
        }
    }

    func testFixedIntervalNonExactMultiple() {
        let segments = LayeredIndexer.fixedIntervalSegments(duration: 25.0)
        XCTAssertEqual(segments.count, 3, "ceil(25/10) = 3 segments")

        XCTAssertEqual(segments[0].startTime, 0.0, accuracy: 0.001)
        XCTAssertEqual(segments[0].endTime, 10.0, accuracy: 0.001)

        XCTAssertEqual(segments[1].startTime, 10.0, accuracy: 0.001)
        XCTAssertEqual(segments[1].endTime, 20.0, accuracy: 0.001)

        // 最后一段较短
        XCTAssertEqual(segments[2].startTime, 20.0, accuracy: 0.001)
        XCTAssertEqual(segments[2].endTime, 25.0, accuracy: 0.001)
    }

    // MARK: - 边界情况

    func testFixedIntervalZeroDuration() {
        let segments = LayeredIndexer.fixedIntervalSegments(duration: 0.0)
        XCTAssertTrue(segments.isEmpty, "duration=0 不应产生分段")
    }

    func testFixedIntervalNegativeDuration() {
        let segments = LayeredIndexer.fixedIntervalSegments(duration: -10.0)
        XCTAssertTrue(segments.isEmpty, "负 duration 不应产生分段")
    }

    func testFixedIntervalVeryShort() {
        let segments = LayeredIndexer.fixedIntervalSegments(duration: 0.5)
        XCTAssertEqual(segments.count, 1, "0.5s 视频应有 1 段")
        XCTAssertEqual(segments[0].startTime, 0.0, accuracy: 0.001)
        XCTAssertEqual(segments[0].endTime, 0.5, accuracy: 0.001)
    }

    func testFixedIntervalExactlyTen() {
        let segments = LayeredIndexer.fixedIntervalSegments(duration: 10.0)
        XCTAssertEqual(segments.count, 1, "正好 10s 应有 1 段")
        XCTAssertEqual(segments[0].startTime, 0.0, accuracy: 0.001)
        XCTAssertEqual(segments[0].endTime, 10.0, accuracy: 0.001)
    }

    func testFixedIntervalSlightlyOverTen() {
        let segments = LayeredIndexer.fixedIntervalSegments(duration: 10.001)
        XCTAssertEqual(segments.count, 2, "10.001s 应有 2 段")
        XCTAssertEqual(segments[1].endTime, 10.001, accuracy: 0.001)
    }

    // MARK: - 自定义间隔

    func testCustomInterval5Seconds() {
        let segments = LayeredIndexer.fixedIntervalSegments(
            duration: 30.0, interval: 5.0
        )
        XCTAssertEqual(segments.count, 6, "30s / 5s = 6 segments")
    }

    func testCustomInterval30Seconds() {
        let segments = LayeredIndexer.fixedIntervalSegments(
            duration: 120.0, interval: 30.0
        )
        XCTAssertEqual(segments.count, 4, "120s / 30s = 4 segments")
    }

    func testZeroIntervalReturnsEmpty() {
        let segments = LayeredIndexer.fixedIntervalSegments(
            duration: 120.0, interval: 0.0
        )
        XCTAssertTrue(segments.isEmpty, "interval=0 不应产生分段")
    }

    func testNegativeIntervalReturnsEmpty() {
        let segments = LayeredIndexer.fixedIntervalSegments(
            duration: 120.0, interval: -5.0
        )
        XCTAssertTrue(segments.isEmpty, "负 interval 不应产生分段")
    }

    // MARK: - 长视频

    func testFixedIntervalLongVideo() {
        // 模拟 27 分钟 BRAW 素材
        let segments = LayeredIndexer.fixedIntervalSegments(duration: 1620.0)
        XCTAssertEqual(segments.count, 162, "1620s / 10s = 162 segments")

        // 验证连续性（无间隙）
        for i in 1..<segments.count {
            XCTAssertEqual(
                segments[i].startTime, segments[i - 1].endTime,
                accuracy: 0.001,
                "段 \(i) 应紧接前一段"
            )
        }

        // 验证首段从 0 开始
        XCTAssertEqual(segments[0].startTime, 0.0, accuracy: 0.001)

        // 验证末段在 duration 结束
        XCTAssertEqual(segments.last!.endTime, 1620.0, accuracy: 0.001)
    }

    // MARK: - 段属性

    func testSegmentDurations() {
        let segments = LayeredIndexer.fixedIntervalSegments(duration: 25.0)
        XCTAssertEqual(segments.count, 3)

        // 前 2 段应为 10s
        XCTAssertEqual(segments[0].duration, 10.0, accuracy: 0.001)
        XCTAssertEqual(segments[1].duration, 10.0, accuracy: 0.001)

        // 最后 1 段应为 5s
        XCTAssertEqual(segments[2].duration, 5.0, accuracy: 0.001)
    }

    func testAllSegmentsNonOverlapping() {
        let segments = LayeredIndexer.fixedIntervalSegments(duration: 75.0)
        for i in 0..<segments.count - 1 {
            XCTAssertLessThanOrEqual(
                segments[i].endTime, segments[i + 1].startTime + 0.001,
                "段不应重叠"
            )
        }
    }
}
