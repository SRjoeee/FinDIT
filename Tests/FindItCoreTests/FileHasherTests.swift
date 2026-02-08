import XCTest
import GRDB
@testable import FindItCore

final class FileHasherTests: XCTestCase {

    // MARK: - 临时文件辅助

    private var tmpDir: String!

    override func setUp() {
        super.setUp()
        tmpDir = NSTemporaryDirectory() + "findit_test_hasher_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpDir)
        super.tearDown()
    }

    private func createFile(_ name: String, content: Data) -> String {
        let path = (tmpDir as NSString).appendingPathComponent(name)
        FileManager.default.createFile(atPath: path, contents: content)
        return path
    }

    // MARK: - hash128 基础

    func testDeterministicHash() throws {
        let content = Data("hello xxHash3-128 test".utf8)
        let path = createFile("test.bin", content: content)

        let hash1 = try FileHasher.hash128(filePath: path)
        let hash2 = try FileHasher.hash128(filePath: path)

        XCTAssertEqual(hash1, hash2, "同一文件多次哈希结果应一致")
    }

    func testDifferentFilesProduceDifferentHashes() throws {
        let path1 = createFile("file1.bin", content: Data("content A".utf8))
        let path2 = createFile("file2.bin", content: Data("content B".utf8))

        let hash1 = try FileHasher.hash128(filePath: path1)
        let hash2 = try FileHasher.hash128(filePath: path2)

        XCTAssertNotEqual(hash1, hash2, "不同内容的文件应产生不同哈希")
    }

    func testHexFormat() throws {
        let path = createFile("hex.bin", content: Data("format check".utf8))
        let hash = try FileHasher.hash128(filePath: path)

        XCTAssertEqual(hash.count, 32, "128 位哈希应为 32 字符 hex string")
        let hexChars = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(
            hash.unicodeScalars.allSatisfy { hexChars.contains($0) },
            "哈希应仅包含小写十六进制字符"
        )
    }

    func testEmptyFile() throws {
        let path = createFile("empty.bin", content: Data())
        let hash = try FileHasher.hash128(filePath: path)

        XCTAssertEqual(hash.count, 32, "空文件也应产生有效的 32 字符哈希")
    }

    func testSmallFile() throws {
        // 小于 1 字节的边界
        let path = createFile("tiny.bin", content: Data([0x42]))
        let hash = try FileHasher.hash128(filePath: path)

        XCTAssertEqual(hash.count, 32)
        // 确保非全零
        XCTAssertNotEqual(hash, String(repeating: "0", count: 32))
    }

    func testLargeFile() throws {
        // 创建 > 1MB 文件，验证流式处理跨 buffer 边界
        let chunkSize = 1_048_576 // 1 MB
        var largeData = Data(count: chunkSize + 512) // 1MB + 512 bytes
        // 填充非零数据以确保哈希有意义
        for i in 0..<largeData.count {
            largeData[i] = UInt8(i % 256)
        }
        let path = createFile("large.bin", content: largeData)

        let hash = try FileHasher.hash128(filePath: path)
        XCTAssertEqual(hash.count, 32)

        // 验证确定性（跨 buffer 边界仍一致）
        let hash2 = try FileHasher.hash128(filePath: path)
        XCTAssertEqual(hash, hash2)
    }

    func testNonExistentFileThrows() {
        let fakePath = (tmpDir as NSString).appendingPathComponent("nonexistent.bin")
        XCTAssertThrowsError(try FileHasher.hash128(filePath: fakePath))
    }

    // MARK: - verify

    func testVerifyValid() throws {
        let path = createFile("valid.bin", content: Data("integrity check".utf8))
        let hash = try FileHasher.hash128(filePath: path)

        let status = FileHasher.verify(filePath: path, expectedHash: hash)
        XCTAssertEqual(status, .valid)
    }

    func testVerifyModified() throws {
        let path = createFile("modify.bin", content: Data("original".utf8))
        let hash = try FileHasher.hash128(filePath: path)

        // 修改文件内容
        try Data("modified content".utf8).write(to: URL(fileURLWithPath: path))

        let status = FileHasher.verify(filePath: path, expectedHash: hash)
        XCTAssertEqual(status, .modified)
    }

    func testVerifyMissing() {
        let status = FileHasher.verify(
            filePath: "/nonexistent/\(UUID().uuidString)/file.bin",
            expectedHash: "0000000000000000ffffffffffffffff"
        )
        XCTAssertEqual(status, .missing)
    }

    // MARK: - 并发安全

    func testConcurrentHashing() throws {
        // 创建多个文件
        var paths: [String] = []
        for i in 0..<8 {
            let path = createFile("concurrent_\(i).bin", content: Data("file \(i) data".utf8))
            paths.append(path)
        }

        // 串行预计算期望哈希
        var expectedHashes: [String] = []
        for path in paths {
            expectedHashes.append(try FileHasher.hash128(filePath: path))
        }

        // 并发哈希
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        var results = [String?](repeating: nil, count: paths.count)
        let lock = NSLock()

        for i in 0..<paths.count {
            group.enter()
            queue.async {
                let hash = try? FileHasher.hash128(filePath: paths[i])
                lock.lock()
                results[i] = hash
                lock.unlock()
                group.leave()
            }
        }

        group.wait()

        // 验证并发结果与串行一致
        for i in 0..<paths.count {
            XCTAssertEqual(results[i], expectedHashes[i], "并发哈希结果应与串行一致 (file \(i))")
        }
    }

    // MARK: - 迁移测试

    func testFolderMigrationFileHashIndex() throws {
        let db = try DatabaseManager.makeFolderInMemoryDatabase()

        let hasIndex = try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM pragma_index_list('videos')")
                .contains { row in
                    let indexName: String = row["name"]
                    let columns = try Row.fetchAll(db, sql: "PRAGMA index_info('\(indexName)')")
                        .map { $0["name"] as String }
                    return columns.contains("file_hash")
                }
        }
        XCTAssertTrue(hasIndex, "文件夹库 videos 表应有 file_hash 索引")
    }

    func testGlobalMigrationFileHashColumn() throws {
        let db = try DatabaseManager.makeGlobalInMemoryDatabase()

        let columns = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(videos)")
        }.map { $0["name"] as String }

        XCTAssertTrue(columns.contains("file_hash"), "全局库 videos 表应包含 file_hash 列")
    }
}
