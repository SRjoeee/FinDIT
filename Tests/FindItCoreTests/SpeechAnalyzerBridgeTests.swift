import XCTest
@testable import FindItCore

/// SpeechAnalyzerBridge 纯函数测试
///
/// 只测试不需要 macOS 26 运行时的纯函数（语言映射等）。
/// 实际转录需要 macOS 26 + 语音模型，在 E2E 测试中覆盖。
final class SpeechAnalyzerBridgeTests: XCTestCase {

    // MARK: - localeForLanguage

    func testLocaleForLanguageChinese() {
        if #available(macOS 26.0, *) {
            let locale = SpeechAnalyzerBridge.localeForLanguage("zh")
            XCTAssertEqual(locale.identifier, "zh_CN")
        }
    }

    func testLocaleForLanguageJapanese() {
        if #available(macOS 26.0, *) {
            let locale = SpeechAnalyzerBridge.localeForLanguage("ja")
            XCTAssertEqual(locale.identifier, "ja_JP")
        }
    }

    func testLocaleForLanguageEnglish() {
        if #available(macOS 26.0, *) {
            let locale = SpeechAnalyzerBridge.localeForLanguage("en")
            XCTAssertEqual(locale.identifier, "en_US")
        }
    }

    func testLocaleForLanguageKorean() {
        if #available(macOS 26.0, *) {
            let locale = SpeechAnalyzerBridge.localeForLanguage("ko")
            XCTAssertEqual(locale.identifier, "ko_KR")
        }
    }

    func testLocaleForLanguageNil() {
        if #available(macOS 26.0, *) {
            let locale = SpeechAnalyzerBridge.localeForLanguage(nil)
            XCTAssertEqual(locale.identifier, "en_US", "nil 应默认英语")
        }
    }

    func testLocaleForLanguageUnknown() {
        if #available(macOS 26.0, *) {
            let locale = SpeechAnalyzerBridge.localeForLanguage("xx")
            XCTAssertEqual(locale.identifier, "en_US", "未知语言应降级到英语")
        }
    }

    func testLocaleForLanguageCaseInsensitive() {
        if #available(macOS 26.0, *) {
            let locale = SpeechAnalyzerBridge.localeForLanguage("JA")
            XCTAssertEqual(locale.identifier, "ja_JP", "应忽略大小写")
        }
    }

    // MARK: - NLLanguage rawValue 兼容

    func testLocaleForLanguageNLRawValueZhHans() {
        if #available(macOS 26.0, *) {
            let locale = SpeechAnalyzerBridge.localeForLanguage("zh-Hans")
            XCTAssertEqual(locale.identifier, "zh_CN", "NLLanguage zh-Hans 应映射到 zh_CN")
        }
    }

    func testLocaleForLanguageNLRawValueZhHant() {
        if #available(macOS 26.0, *) {
            let locale = SpeechAnalyzerBridge.localeForLanguage("zh-Hant")
            XCTAssertEqual(locale.identifier, "zh_CN", "NLLanguage zh-Hant 应映射到中文")
        }
    }

    // MARK: - languageToLocale coverage

    func testLanguageToLocaleHasAllExpected() {
        if #available(macOS 26.0, *) {
            // 非英语语言不应映射到 en_US
            let nonEnglish = ["zh", "ja", "ko", "fr", "de", "es", "it", "pt", "ru"]
            for lang in nonEnglish {
                let locale = SpeechAnalyzerBridge.localeForLanguage(lang)
                XCTAssertNotEqual(
                    locale.identifier, "en_US",
                    "\(lang) 不应降级到默认英语"
                )
            }
            // en 应映射到 en_US
            let enLocale = SpeechAnalyzerBridge.localeForLanguage("en")
            XCTAssertEqual(enLocale.identifier, "en_US")
        }
    }

    // MARK: - extractSegments

    func testExtractSegmentsFromEmptyAttributedString() {
        if #available(macOS 26.0, *) {
            let empty = AttributedString("")
            let segments = SpeechAnalyzerBridge.extractSegments(from: empty)
            XCTAssertTrue(segments.isEmpty)
        }
    }

    func testExtractSegmentsFromPlainText() {
        if #available(macOS 26.0, *) {
            // 无 audioTimeRange 属性的纯文本 → 无片段（无时间戳）
            let plain = AttributedString("Hello world")
            let segments = SpeechAnalyzerBridge.extractSegments(from: plain)
            XCTAssertTrue(segments.isEmpty, "无 audioTimeRange 属性应返回空")
        }
    }

    // MARK: - isAvailable

    func testIsAvailableReturnsResult() async {
        if #available(macOS 26.0, *) {
            // 只验证不崩溃，不断言结果（取决于系统环境）
            let _ = await SpeechAnalyzerBridge.isAvailable(language: "en")
            let _ = await SpeechAnalyzerBridge.isAvailable(language: nil)
        }
    }
}
