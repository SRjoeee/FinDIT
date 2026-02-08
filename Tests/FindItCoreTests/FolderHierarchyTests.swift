import XCTest
@testable import FindItCore

final class FolderHierarchyTests: XCTestCase {

    // MARK: - relationship

    func testRelationshipParent() {
        XCTAssertEqual(
            FolderHierarchy.relationship("/A", "/A/B"),
            .parent,
            "A 包含 A/B → parent"
        )
    }

    func testRelationshipChild() {
        XCTAssertEqual(
            FolderHierarchy.relationship("/A/B", "/A"),
            .child,
            "A/B 被 A 包含 → child"
        )
    }

    func testRelationshipUnrelated() {
        XCTAssertEqual(
            FolderHierarchy.relationship("/A", "/C"),
            .unrelated
        )
    }

    func testRelationshipDuplicate() {
        XCTAssertEqual(
            FolderHierarchy.relationship("/A/B", "/A/B"),
            .duplicate
        )
    }

    func testRelationshipTrailingSlash() {
        XCTAssertEqual(
            FolderHierarchy.relationship("/A/", "/A"),
            .duplicate,
            "尾部 / 应被规范化"
        )
        XCTAssertEqual(
            FolderHierarchy.relationship("/A/", "/A/B"),
            .parent
        )
    }

    func testRelationshipDeepNesting() {
        XCTAssertEqual(
            FolderHierarchy.relationship("/A", "/A/B/C/D"),
            .parent,
            "多级嵌套仍为 parent"
        )
        XCTAssertEqual(
            FolderHierarchy.relationship("/A/B/C/D", "/A"),
            .child
        )
    }

    func testRelationshipSimilarPrefix() {
        // "/A/Bx" 不是 "/A/B" 的子级
        XCTAssertEqual(
            FolderHierarchy.relationship("/A/B", "/A/Bx"),
            .unrelated,
            "路径前缀相似但不是子级"
        )
    }

    // MARK: - resolveAddition

    func testResolveAdditionNormally() {
        let plan = FolderHierarchy.resolveAddition(
            newPath: "/C",
            existingPaths: ["/A", "/B"]
        )
        XCTAssertEqual(plan.action, .addNormally)
    }

    func testResolveAdditionDuplicate() {
        let plan = FolderHierarchy.resolveAddition(
            newPath: "/A",
            existingPaths: ["/A", "/B"]
        )
        XCTAssertEqual(plan.action, .duplicate)
    }

    func testResolveAdditionAsParent() {
        let plan = FolderHierarchy.resolveAddition(
            newPath: "/A",
            existingPaths: ["/A/B", "/A/C"]
        )
        XCTAssertEqual(
            plan.action,
            .addAsParent(existingChildren: ["/A/B", "/A/C"]),
            "添加父级时应返回所有已注册子文件夹"
        )
    }

    func testResolveAdditionAsSubfolderBookmark() {
        let plan = FolderHierarchy.resolveAddition(
            newPath: "/A/B",
            existingPaths: ["/A"]
        )
        XCTAssertEqual(
            plan.action,
            .addAsSubfolderBookmark(parentFolder: "/A")
        )
    }

    func testResolveAdditionEmptyExisting() {
        let plan = FolderHierarchy.resolveAddition(
            newPath: "/A",
            existingPaths: []
        )
        XCTAssertEqual(plan.action, .addNormally)
    }

    func testResolveAdditionMultiLevelParent() {
        // 新路径有多层已注册子文件夹
        let plan = FolderHierarchy.resolveAddition(
            newPath: "/A",
            existingPaths: ["/A/B", "/A/B/C", "/D"]
        )
        XCTAssertEqual(
            plan.action,
            .addAsParent(existingChildren: ["/A/B", "/A/B/C"]),
            "应发现所有层级的子文件夹"
        )
    }

    func testResolveAdditionNearestParent() {
        // 有多个可能的父级时，选择最近的
        let plan = FolderHierarchy.resolveAddition(
            newPath: "/A/B/C",
            existingPaths: ["/A", "/A/B"]
        )
        XCTAssertEqual(
            plan.action,
            .addAsSubfolderBookmark(parentFolder: "/A/B"),
            "应选择最近的父文件夹"
        )
    }

    // MARK: - findChildren

    func testFindChildren() {
        let children = FolderHierarchy.findChildren(
            of: "/A",
            in: ["/A/B", "/A/C", "/D", "/A/B/E"]
        )
        XCTAssertEqual(children, ["/A/B", "/A/B/E", "/A/C"])
    }

    func testFindChildrenNoMatch() {
        let children = FolderHierarchy.findChildren(
            of: "/X",
            in: ["/A", "/B"]
        )
        XCTAssertEqual(children, [])
    }

    func testFindChildrenSimilarPrefix() {
        let children = FolderHierarchy.findChildren(
            of: "/A/B",
            in: ["/A/Bx", "/A/B/C"]
        )
        XCTAssertEqual(children, ["/A/B/C"], "不应匹配仅前缀相似的路径")
    }

    // MARK: - findParent

    func testFindParent() {
        let parent = FolderHierarchy.findParent(
            of: "/A/B/C",
            in: ["/A", "/A/B", "/D"]
        )
        XCTAssertEqual(parent, "/A/B", "应返回最近的父级")
    }

    func testFindParentNoMatch() {
        let parent = FolderHierarchy.findParent(
            of: "/X",
            in: ["/A", "/B"]
        )
        XCTAssertNil(parent)
    }

    func testFindParentSingleLevel() {
        let parent = FolderHierarchy.findParent(
            of: "/A/B",
            in: ["/A"]
        )
        XCTAssertEqual(parent, "/A")
    }

    // MARK: - normalize

    func testNormalize() {
        XCTAssertEqual(FolderHierarchy.normalize("/A/B/"), "/A/B")
        XCTAssertEqual(FolderHierarchy.normalize("/A/B"), "/A/B")
        XCTAssertEqual(FolderHierarchy.normalize("/"), "/")
        XCTAssertEqual(FolderHierarchy.normalize("/A///"), "/A")
    }

    // MARK: - FileScanner excluding

    func testScanExcludingSubfolders() throws {
        let tmpDir = NSTemporaryDirectory() + "findit_test_exclude_\(UUID().uuidString)"
        let subDir = (tmpDir as NSString).appendingPathComponent("sub")
        let subSubDir = (subDir as NSString).appendingPathComponent("deep")
        try FileManager.default.createDirectory(atPath: subSubDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // 根目录文件
        FileManager.default.createFile(atPath: (tmpDir as NSString).appendingPathComponent("root.mp4"), contents: nil)
        // 子目录文件（应被排除）
        FileManager.default.createFile(atPath: (subDir as NSString).appendingPathComponent("sub.mp4"), contents: nil)
        // 深层子目录文件（也应被排除）
        FileManager.default.createFile(atPath: (subSubDir as NSString).appendingPathComponent("deep.mp4"), contents: nil)

        let results = try FileScanner.scanVideoFiles(in: tmpDir, excluding: [subDir])
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].hasSuffix("root.mp4"))
    }

    func testScanEmptyExclusions() throws {
        let tmpDir = NSTemporaryDirectory() + "findit_test_no_excl_\(UUID().uuidString)"
        let subDir = (tmpDir as NSString).appendingPathComponent("sub")
        try FileManager.default.createDirectory(atPath: subDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        FileManager.default.createFile(atPath: (tmpDir as NSString).appendingPathComponent("root.mp4"), contents: nil)
        FileManager.default.createFile(atPath: (subDir as NSString).appendingPathComponent("sub.mp4"), contents: nil)

        let results = try FileScanner.scanVideoFiles(in: tmpDir, excluding: [])
        XCTAssertEqual(results.count, 2, "空排除集应返回全部文件")
    }

    func testScanMultipleExclusions() throws {
        let tmpDir = NSTemporaryDirectory() + "findit_test_multi_excl_\(UUID().uuidString)"
        let sub1 = (tmpDir as NSString).appendingPathComponent("subA")
        let sub2 = (tmpDir as NSString).appendingPathComponent("subB")
        let sub3 = (tmpDir as NSString).appendingPathComponent("subC")
        try FileManager.default.createDirectory(atPath: sub1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: sub2, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: sub3, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        FileManager.default.createFile(atPath: (tmpDir as NSString).appendingPathComponent("root.mp4"), contents: nil)
        FileManager.default.createFile(atPath: (sub1 as NSString).appendingPathComponent("a.mp4"), contents: nil)
        FileManager.default.createFile(atPath: (sub2 as NSString).appendingPathComponent("b.mp4"), contents: nil)
        FileManager.default.createFile(atPath: (sub3 as NSString).appendingPathComponent("c.mp4"), contents: nil)

        let results = try FileScanner.scanVideoFiles(in: tmpDir, excluding: [sub1, sub2])
        XCTAssertEqual(results.count, 2, "排除 subA 和 subB 后应只有 root.mp4 和 subC/c.mp4")
        XCTAssertTrue(results.contains { $0.hasSuffix("root.mp4") })
        XCTAssertTrue(results.contains { $0.hasSuffix("c.mp4") })
    }
}
