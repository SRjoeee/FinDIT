import XCTest
@testable import FindItCore

final class FindItCoreTests: XCTestCase {

    func testVersionExists() {
        XCTAssertFalse(FindIt.version.isEmpty, "版本号不应为空")
    }

    func testVersionFormat() {
        // 版本号应为 semver 格式: x.y.z
        let parts = FindIt.version.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "版本号应为 x.y.z 格式")
    }
}
