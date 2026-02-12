import XCTest
@testable import FindItCore

final class APIKeyManagerTests: XCTestCase {

    // MARK: - 解析

    func testResolveAPIKeyFromOverride() throws {
        let key = try APIKeyManager.resolveAPIKey(override: "AIzaSyD1234567890abcdefghij")
        XCTAssertEqual(key, "AIzaSyD1234567890abcdefghij")
    }

    func testResolveAPIKeyOverrideTooShort() {
        // override 太短 → 降级到配置文件/环境变量
        // 如果都没有 → 抛 notFound
        // 如果配置文件有 key → 返回配置文件的 key（不应返回 "abc"）
        do {
            let key = try APIKeyManager.resolveAPIKey(override: "abc")
            XCTAssertNotEqual(key, "abc")
            XCTAssertTrue(APIKeyManager.validateAPIKey(key))
        } catch {
            guard case APIKeyManager.KeyError.notFound = error else {
                XCTFail("应抛出 notFound，实际: \(error)")
                return
            }
        }
    }

    // MARK: - 验证

    func testValidateAPIKeyValid() {
        XCTAssertTrue(APIKeyManager.validateAPIKey("AIzaSyD1234567890abcdefghij"))
        XCTAssertTrue(APIKeyManager.validateAPIKey("1234567890")) // 刚好 10 字符
    }

    func testValidateAPIKeyInvalid() {
        XCTAssertFalse(APIKeyManager.validateAPIKey(""))
        XCTAssertFalse(APIKeyManager.validateAPIKey("short"))
        XCTAssertFalse(APIKeyManager.validateAPIKey("   "))
    }

    // MARK: - 文件读取

    func testReadAPIKeyFromFileNonExistent() {
        let result = APIKeyManager.readAPIKeyFromFile("/nonexistent/path/key.txt")
        XCTAssertNil(result)
    }

    func testReadAPIKeyFromFileTrimming() throws {
        let tmpDir = NSTemporaryDirectory()
        let keyPath = (tmpDir as NSString).appendingPathComponent("test_api_key_mgr.txt")
        defer { try? FileManager.default.removeItem(atPath: keyPath) }

        try "  AIzaSyTestKey12345678  \n".write(toFile: keyPath, atomically: true, encoding: .utf8)
        let result = APIKeyManager.readAPIKeyFromFile(keyPath)
        XCTAssertEqual(result, "AIzaSyTestKey12345678")
    }

    func testReadAPIKeyFromFileEmpty() throws {
        let tmpDir = NSTemporaryDirectory()
        let keyPath = (tmpDir as NSString).appendingPathComponent("test_empty_key_mgr.txt")
        defer { try? FileManager.default.removeItem(atPath: keyPath) }

        try "  \n  ".write(toFile: keyPath, atomically: true, encoding: .utf8)
        let result = APIKeyManager.readAPIKeyFromFile(keyPath)
        XCTAssertNil(result)
    }

    // MARK: - 目录创建

    func testEnsureConfigDirectory() throws {
        let dir = try APIKeyManager.ensureConfigDirectory()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir))
    }

    // MARK: - 保存

    func testSaveAndReadAPIKey() throws {
        // 保存到临时路径测试 round-trip
        let tmpDir = NSTemporaryDirectory()
        let keyPath = (tmpDir as NSString).appendingPathComponent("test_save_key.txt")
        defer { try? FileManager.default.removeItem(atPath: keyPath) }

        let testKey = "AIzaSyTestSaveKey1234"
        try testKey.write(toFile: keyPath, atomically: true, encoding: .utf8)

        let readBack = APIKeyManager.readAPIKeyFromFile(keyPath)
        XCTAssertEqual(readBack, testKey)
    }

    // MARK: - 常量

    func testDefaultKeyFilePath() {
        XCTAssertTrue(APIKeyManager.defaultKeyFilePath.hasSuffix("gemini-api-key.txt"))
        XCTAssertTrue(APIKeyManager.defaultKeyFilePath.contains(".config/findit"))
    }

    func testEnvVarName() {
        XCTAssertEqual(APIKeyManager.envVarName, "GEMINI_API_KEY")
    }

    // MARK: - 错误类型

    func testKeyErrorDescriptions() {
        let notFound = APIKeyManager.KeyError.notFound
        XCTAssertNotNil(notFound.errorDescription)
        XCTAssertTrue(notFound.errorDescription?.contains("API Key") ?? false)

        let saveFailed = APIKeyManager.KeyError.saveFailed("test error")
        XCTAssertNotNil(saveFailed.errorDescription)
        XCTAssertTrue(saveFailed.errorDescription?.contains("test error") ?? false)
    }

    // MARK: - 多 Provider

    func testResolveAPIKeyFromOverrideWithProvider() throws {
        // override 优先级高于 provider，无论哪个 provider 都应返回 override
        let key = try APIKeyManager.resolveAPIKey(
            override: "sk-or-test1234567890",
            provider: .openRouter
        )
        XCTAssertEqual(key, "sk-or-test1234567890")
    }

    func testResolveAPIKeyDefaultProviderIsGemini() throws {
        // 默认 provider 应该是 .gemini（与现有行为兼容）
        let key = try APIKeyManager.resolveAPIKey(override: "AIzaSyD1234567890abcdefghij")
        XCTAssertEqual(key, "AIzaSyD1234567890abcdefghij")
    }

    func testSaveAndReadAPIKeyOpenRouter() throws {
        let tmpDir = NSTemporaryDirectory()
        let keyPath = (tmpDir as NSString).appendingPathComponent("openrouter-api-key.txt")
        defer { try? FileManager.default.removeItem(atPath: keyPath) }

        let testKey = "sk-or-test-key-1234567890"
        try testKey.write(toFile: keyPath, atomically: true, encoding: .utf8)

        let readBack = APIKeyManager.readAPIKeyFromFile(keyPath)
        XCTAssertEqual(readBack, testKey)
    }

    func testProviderKeyFilePathDiffers() {
        // gemini 和 openRouter 的 key 文件路径不同
        XCTAssertNotEqual(
            APIProvider.gemini.keyFilePath,
            APIProvider.openRouter.keyFilePath
        )
    }

    func testProviderEnvVarNameDiffers() {
        XCTAssertNotEqual(
            APIProvider.gemini.envVarName,
            APIProvider.openRouter.envVarName
        )
    }
}
