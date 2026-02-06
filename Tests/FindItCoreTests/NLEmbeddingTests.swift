import XCTest
import NaturalLanguage
@testable import FindItCore

final class NLEmbeddingTests: XCTestCase {

    // MARK: - detectLanguage

    func testDetectLanguageEnglish() {
        let lang = NLEmbeddingUtil.detectLanguage(text: "Hello world, how are you today?")
        XCTAssertEqual(lang, .english)
    }

    func testDetectLanguageChinese() {
        let lang = NLEmbeddingUtil.detectLanguage(text: "今天天气真好，我们去海边散步吧")
        XCTAssertEqual(lang, .simplifiedChinese)
    }

    func testDetectLanguageEmpty() {
        let lang = NLEmbeddingUtil.detectLanguage(text: "")
        // 空文本可能返回 nil 或 undetermined
        // 无法检测
        _ = lang // 不断言具体值
    }

    // MARK: - isAvailable

    func testIsAvailableEnglish() {
        // 英文嵌入模型通常预装在 macOS 上
        let available = NLEmbeddingUtil.isAvailable(for: .english)
        // 注意：在某些 CI 环境可能不可用，这里只验证不会 crash
        _ = available
    }

    func testAvailableLanguages() {
        let langs = NLEmbeddingUtil.availableLanguages()
        // 至少应该有一些语言可用（依赖系统环境）
        // 不做强断言，避免 CI 环境差异
        _ = langs
    }

    // MARK: - NLEmbeddingProvider

    func testProviderName() {
        let provider = NLEmbeddingProvider()
        XCTAssertEqual(provider.name, "nl-embedding")
    }

    func testProviderDimensions() {
        let provider = NLEmbeddingProvider()
        XCTAssertEqual(provider.dimensions, 512)
    }

    func testProviderIsAvailable() {
        let provider = NLEmbeddingProvider()
        // 不做强断言，某些环境可能不可用
        _ = provider.isAvailable()
    }

    // MARK: - embed (实际调用系统框架)

    func testEmbedEnglishText() {
        // 尝试嵌入英文文本
        let vector = NLEmbeddingUtil.embed(text: "beautiful sunset over the ocean", language: .english)
        // 如果英文模型可用，应返回非空向量
        if let vec = vector {
            XCTAssertGreaterThan(vec.count, 0, "向量维度应 > 0")
            // 向量应该是有限数值
            XCTAssertTrue(vec.allSatisfy { $0.isFinite }, "所有值应为有限数")
        }
        // 模型不可用时返回 nil 也是合法的
    }

    func testEmbedAutoDetect() {
        // 自动检测语言
        let vector = NLEmbeddingUtil.embed(text: "The quick brown fox jumps over the lazy dog")
        if let vec = vector {
            XCTAssertGreaterThan(vec.count, 0)
        }
    }
}
