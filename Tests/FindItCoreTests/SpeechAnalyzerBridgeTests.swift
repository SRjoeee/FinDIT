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

    // MARK: - mergeFragmentedSegments

    /// 辅助方法：快速创建 TranscriptSegment
    private func seg(_ index: Int, _ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(index: index, startTime: start, endTime: end, text: text)
    }

    func testMergeSegmentsEmpty() {
        if #available(macOS 26.0, *) {
            let result = SpeechAnalyzerBridge.mergeFragmentedSegments([])
            XCTAssertTrue(result.isEmpty)
        }
    }

    func testMergeSegmentsSingleSegment() {
        if #available(macOS 26.0, *) {
            let input = [seg(1, 0.0, 1.0, "Hello")]
            let result = SpeechAnalyzerBridge.mergeFragmentedSegments(input)
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result[0].text, "Hello")
            XCTAssertEqual(result[0].index, 1)
        }
    }

    func testMergeSegmentsByPunctuation() {
        if #available(macOS 26.0, *) {
            // 日语逐字碎片 → 句末标点断句
            let input = [
                seg(1, 0.0, 0.1, "こ"),
                seg(2, 0.1, 0.2, "れ"),
                seg(3, 0.2, 0.3, "は"),
                seg(4, 0.3, 0.4, "テ"),
                seg(5, 0.4, 0.5, "ス"),
                seg(6, 0.5, 0.6, "ト"),
                seg(7, 0.6, 0.7, "で"),
                seg(8, 0.7, 0.8, "す"),
                seg(9, 0.8, 0.9, "。"),  // 句末标点
                seg(10, 1.0, 1.1, "次"),
                seg(11, 1.1, 1.2, "へ"),
            ]
            let result = SpeechAnalyzerBridge.mergeFragmentedSegments(input)
            XCTAssertEqual(result.count, 2)
            XCTAssertEqual(result[0].text, "これはテストです。")
            XCTAssertEqual(result[0].startTime, 0.0, accuracy: 0.001)
            XCTAssertEqual(result[0].endTime, 0.9, accuracy: 0.001)
            XCTAssertEqual(result[1].text, "次へ")
            XCTAssertEqual(result[1].index, 2)
        }
    }

    func testMergeSegmentsByTimeGap() {
        if #available(macOS 26.0, *) {
            // 间隔 > 1.0s → 强制断句
            let input = [
                seg(1, 0.0, 0.5, "前半"),
                seg(2, 0.5, 1.0, "部分"),
                seg(3, 3.0, 3.5, "後半"),  // 2.0s 间隔
                seg(4, 3.5, 4.0, "部分"),
            ]
            let result = SpeechAnalyzerBridge.mergeFragmentedSegments(input)
            XCTAssertEqual(result.count, 2)
            XCTAssertEqual(result[0].text, "前半部分")
            XCTAssertEqual(result[1].text, "後半部分")
        }
    }

    func testMergeSegmentsMaxDuration() {
        if #available(macOS 26.0, *) {
            // 累积时长 > 15s → 强制断句
            var input: [TranscriptSegment] = []
            for i in 0..<20 {
                let start = Double(i)
                input.append(seg(i + 1, start, start + 0.9, "字"))
            }
            let result = SpeechAnalyzerBridge.mergeFragmentedSegments(input, maxDuration: 15.0)
            // 20 个 1s 段 → 至少 2 个合并段
            XCTAssertGreaterThan(result.count, 1)
            // 每个合并段时长 ≤ 15s + 单段余量
            for seg in result {
                XCTAssertLessThanOrEqual(seg.endTime - seg.startTime, 16.0)
            }
        }
    }

    func testMergeSegmentsAlreadyMergedEnglish() {
        if #available(macOS 26.0, *) {
            // 英语句子级 segments → 几乎不变（无逐字碎片）
            let input = [
                seg(1, 0.0, 2.5, "Hello, how are you?"),
                seg(2, 3.0, 5.0, "I am fine, thank you."),
            ]
            let result = SpeechAnalyzerBridge.mergeFragmentedSegments(input)
            // 间隔 0.5s < 1.0s 但第一段以 ? 结尾 → 应断句
            XCTAssertEqual(result.count, 2)
            XCTAssertEqual(result[0].text, "Hello, how are you?")
            XCTAssertEqual(result[1].text, "I am fine, thank you.")
        }
    }

    func testMergeSegmentsPreservesTimeRange() {
        if #available(macOS 26.0, *) {
            let input = [
                seg(1, 10.0, 10.5, "開"),
                seg(2, 10.5, 11.0, "始"),
            ]
            let result = SpeechAnalyzerBridge.mergeFragmentedSegments(input)
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result[0].startTime, 10.0, accuracy: 0.001)
            XCTAssertEqual(result[0].endTime, 11.0, accuracy: 0.001)
        }
    }

    func testMergeSegmentsReindexes() {
        if #available(macOS 26.0, *) {
            let input = [
                seg(1, 0.0, 0.5, "一。"),
                seg(2, 1.0, 1.5, "二。"),
                seg(3, 2.0, 2.5, "三。"),
            ]
            let result = SpeechAnalyzerBridge.mergeFragmentedSegments(input)
            // 每个都以 。 结尾 → 各成一段
            XCTAssertEqual(result.count, 3)
            XCTAssertEqual(result[0].index, 1)
            XCTAssertEqual(result[1].index, 2)
            XCTAssertEqual(result[2].index, 3)
        }
    }

    func testMergeSegmentsChinesePunctuation() {
        if #available(macOS 26.0, *) {
            let input = [
                seg(1, 0.0, 0.2, "你"),
                seg(2, 0.2, 0.4, "好"),
                seg(3, 0.4, 0.6, "！"),
                seg(4, 0.7, 0.9, "再"),
                seg(5, 0.9, 1.1, "见"),
                seg(6, 1.1, 1.3, "？"),
            ]
            let result = SpeechAnalyzerBridge.mergeFragmentedSegments(input)
            XCTAssertEqual(result.count, 2)
            XCTAssertEqual(result[0].text, "你好！")
            XCTAssertEqual(result[1].text, "再见？")
        }
    }

    func testMergeSegmentsByCharCount() {
        if #available(macOS 26.0, *) {
            // 50 个无标点 CJK 字符 → 应被 maxChars=40 断句
            var input: [TranscriptSegment] = []
            for i in 0..<50 {
                let start = Double(i) * 0.1
                input.append(seg(i + 1, start, start + 0.09, "漢"))
            }
            let result = SpeechAnalyzerBridge.mergeFragmentedSegments(input, maxChars: 40)
            // 50 字 / 40 上限 → 至少 2 段
            XCTAssertGreaterThanOrEqual(result.count, 2, "50 个无标点字符应被字符数上限断句")
            // 每段字符数 ≤ 41（40 上限 + 触发断句的下一个字符归新段）
            for seg in result {
                let charCount = seg.text.unicodeScalars
                    .filter { !$0.properties.isWhitespace }.count
                XCTAssertLessThanOrEqual(charCount, 41)
            }
        }
    }

    func testMergeSegmentsCharCountNoEffectOnShortText() {
        if #available(macOS 26.0, *) {
            // 10 个无标点字符 → 不应被 maxChars=40 断句（短于上限）
            var input: [TranscriptSegment] = []
            for i in 0..<10 {
                let start = Double(i) * 0.1
                input.append(seg(i + 1, start, start + 0.09, "字"))
            }
            let result = SpeechAnalyzerBridge.mergeFragmentedSegments(input, maxChars: 40)
            XCTAssertEqual(result.count, 1, "10 个字符不应被字符数上限断句")
            XCTAssertEqual(result[0].text, "字字字字字字字字字字")
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
