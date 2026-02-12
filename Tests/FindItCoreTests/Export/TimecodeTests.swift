import XCTest
@testable import FindItCore

final class TimecodeTests: XCTestCase {

    // MARK: - Non-drop frame 基础

    func testZeroSeconds() {
        let tc = Timecode(seconds: 0, fps: 24)
        XCTAssertEqual(tc.hours, 0)
        XCTAssertEqual(tc.minutes, 0)
        XCTAssertEqual(tc.seconds, 0)
        XCTAssertEqual(tc.frames, 0)
        XCTAssertEqual(tc.description, "00:00:00:00")
    }

    func testNegativeClampedToZero() {
        let tc = Timecode(seconds: -5.0, fps: 24)
        XCTAssertEqual(tc.description, "00:00:00:00")
    }

    func testOneSecondAt24fps() {
        let tc = Timecode(seconds: 1.0, fps: 24)
        XCTAssertEqual(tc.hours, 0)
        XCTAssertEqual(tc.minutes, 0)
        XCTAssertEqual(tc.seconds, 1)
        XCTAssertEqual(tc.frames, 0)
        XCTAssertEqual(tc.description, "00:00:01:00")
    }

    func testFractionalSecondAt24fps() {
        // 0.5s * 24fps = 12 frames
        let tc = Timecode(seconds: 0.5, fps: 24)
        XCTAssertEqual(tc.frames, 12)
        XCTAssertEqual(tc.description, "00:00:00:12")
    }

    func testOneMinuteAt24fps() {
        let tc = Timecode(seconds: 60.0, fps: 24)
        XCTAssertEqual(tc.description, "00:01:00:00")
    }

    func testOneHourAt24fps() {
        let tc = Timecode(seconds: 3600.0, fps: 24)
        XCTAssertEqual(tc.description, "01:00:00:00")
    }

    func testComplexTimecodeAt24fps() {
        // 1h 23m 45s 12f = 5025.5 seconds
        let seconds = 3600.0 + 23 * 60.0 + 45.0 + 12.0 / 24.0
        let tc = Timecode(seconds: seconds, fps: 24)
        XCTAssertEqual(tc.hours, 1)
        XCTAssertEqual(tc.minutes, 23)
        XCTAssertEqual(tc.seconds, 45)
        XCTAssertEqual(tc.frames, 12)
        XCTAssertEqual(tc.description, "01:23:45:12")
    }

    func testAt25fps() {
        let tc = Timecode(seconds: 1.0, fps: 25)
        XCTAssertEqual(tc.description, "00:00:01:00")

        let tc2 = Timecode(seconds: 0.04, fps: 25)  // 1 frame
        XCTAssertEqual(tc2.frames, 1)
    }

    func testAt30fps() {
        let tc = Timecode(seconds: 1.0, fps: 30)
        XCTAssertEqual(tc.frames, 0)
        XCTAssertEqual(tc.seconds, 1)
    }

    // MARK: - Drop frame (29.97fps)

    func testDropFrameZero() {
        let tc = Timecode(seconds: 0, fps: 29.97, dropFrame: true)
        XCTAssertEqual(tc.description, "00:00:00;00")
    }

    func testDropFrameSeparator() {
        let tc = Timecode(seconds: 5.0, fps: 29.97, dropFrame: true)
        XCTAssertTrue(tc.description.contains(";"))
    }

    func testDropFrameOneMinute() {
        // 60 real seconds at 29.97fps = 1798 frames = 00:00:59;28 (not 01:00 because 29.97 < 30)
        // TC minute boundary at 29.97 DF occurs at ~60.06s
        let tc = Timecode(seconds: 60.0, fps: 29.97, dropFrame: true)
        XCTAssertEqual(tc.hours, 0)
        XCTAssertEqual(tc.minutes, 0)
        XCTAssertEqual(tc.seconds, 59)
        XCTAssertEqual(tc.frames, 28)

        // Verify the actual TC minute boundary (1800 frames ÷ 29.97 ≈ 60.06s)
        let tcAtMinute = Timecode(seconds: 60.06, fps: 29.97, dropFrame: true)
        XCTAssertEqual(tcAtMinute.minutes, 1)
        // At minute boundary with DF, frames skip :00 and :01 → starts at :02
        XCTAssertEqual(tcAtMinute.frames, 2)
    }

    func testDropFrameTenMinutes() {
        // 600 real seconds at 29.97fps = 17982 frames → 00:10:00;00
        let tc = Timecode(seconds: 600.0, fps: 29.97, dropFrame: true)
        XCTAssertEqual(tc.hours, 0)
        XCTAssertEqual(tc.minutes, 10)
        XCTAssertEqual(tc.seconds, 0)
        XCTAssertEqual(tc.frames, 0)
    }

    func testDropFrameIgnoredForNonDropRate() {
        // 24fps ignores dropFrame flag
        let tc = Timecode(seconds: 60.0, fps: 24, dropFrame: true)
        XCTAssertFalse(tc.dropFrame)
        XCTAssertEqual(tc.description, "00:01:00:00")
    }

    func testIsDropFrameRate() {
        XCTAssertTrue(Timecode.isDropFrameRate(29.97))
        XCTAssertTrue(Timecode.isDropFrameRate(59.94))
        XCTAssertFalse(Timecode.isDropFrameRate(24))
        XCTAssertFalse(Timecode.isDropFrameRate(25))
        XCTAssertFalse(Timecode.isDropFrameRate(30))
    }

    // MARK: - Init from components

    func testInitFromComponents() {
        let tc = Timecode(hours: 1, minutes: 30, seconds: 45, frames: 12, fps: 24)
        XCTAssertEqual(tc.hours, 1)
        XCTAssertEqual(tc.minutes, 30)
        XCTAssertEqual(tc.seconds, 45)
        XCTAssertEqual(tc.frames, 12)
    }

    func testComponentsClamped() {
        let tc = Timecode(hours: -1, minutes: 99, seconds: 99, frames: 99, fps: 24)
        XCTAssertEqual(tc.hours, 0)
        XCTAssertEqual(tc.minutes, 59)
        XCTAssertEqual(tc.seconds, 59)
        XCTAssertEqual(tc.frames, 23) // max frame for 24fps = 23
    }

    // MARK: - Parse from string

    func testParseNonDropFrame() {
        let tc = Timecode(string: "01:23:45:12", fps: 24)
        XCTAssertNotNil(tc)
        XCTAssertEqual(tc?.hours, 1)
        XCTAssertEqual(tc?.minutes, 23)
        XCTAssertEqual(tc?.seconds, 45)
        XCTAssertEqual(tc?.frames, 12)
        XCTAssertFalse(tc?.dropFrame ?? true)
    }

    func testParseDropFrame() {
        let tc = Timecode(string: "00:01:00;02", fps: 29.97)
        XCTAssertNotNil(tc)
        XCTAssertTrue(tc?.dropFrame ?? false)
    }

    func testParseInvalid() {
        XCTAssertNil(Timecode(string: "invalid", fps: 24))
        XCTAssertNil(Timecode(string: "12:34", fps: 24))
        XCTAssertNil(Timecode(string: "", fps: 24))
    }

    // MARK: - Round-trip

    func testTotalSecondsRoundTrip() {
        let original = 5025.5  // 1h 23m 45s 12f at 24fps
        let tc = Timecode(seconds: original, fps: 24)
        XCTAssertEqual(tc.totalSeconds, original, accuracy: 0.05)
    }

    func testTotalFrames() {
        let tc = Timecode(seconds: 1.0, fps: 24)
        XCTAssertEqual(tc.totalFrames, 24)

        let tc2 = Timecode(seconds: 0.5, fps: 24)
        XCTAssertEqual(tc2.totalFrames, 12)
    }

    func testTotalFramesAt30fps() {
        let tc = Timecode(seconds: 2.0, fps: 30)
        XCTAssertEqual(tc.totalFrames, 60)
    }

    // MARK: - Equatable

    func testEquatable() {
        let tc1 = Timecode(seconds: 5.0, fps: 24)
        let tc2 = Timecode(seconds: 5.0, fps: 24)
        XCTAssertEqual(tc1, tc2)
    }

    func testNotEqual() {
        let tc1 = Timecode(seconds: 5.0, fps: 24)
        let tc2 = Timecode(seconds: 6.0, fps: 24)
        XCTAssertNotEqual(tc1, tc2)
    }
}
