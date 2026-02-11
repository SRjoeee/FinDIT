import Foundation
import NaturalLanguage

// MARK: - QueryPipeline

/// 查询扩展管线
///
/// 检测查询语言，可选翻译，生成跨语言 FTS5 查询。
/// CLIP/TextEmb 路径不受影响（已原生多语言），仅扩展 FTS5 召回。
///
/// 两种调用模式：
/// - `expandSync`: 同步词典翻译，用于 FTS 即时搜索路径 (<1ms)
/// - `expand`: 异步完整翻译，用于向量搜索 debounce 路径 (支持 Apple Translation)
public enum QueryPipeline {

    // MARK: - Types

    /// 扩展后的查询
    public struct ExpandedQuery: Sendable {
        /// 原始解析结果（不变）
        public let parsed: ParsedQuery
        /// 检测到的语言
        public let language: DetectedLanguage
        /// 翻译后的正向文本（nil = 未翻译或已是目标语言）
        public let translatedPositiveText: String?
        /// 翻译后的 FTS5 查询（含 NOT 子句，nil = 无翻译）
        public let translatedFTSQuery: String?

        /// 用于 embedding 的文本（始终使用原始文本，CLIP/TextEmb 原生多语言）
        public var embeddingText: String { parsed.embeddingText }
    }

    /// 检测到的语言
    public struct DetectedLanguage: Sendable, Equatable {
        /// 语言代码 (NLLanguage.rawValue, 如 "zh-Hans", "en", "ja")
        public let code: String
        /// 检测置信度 (0.0~1.0)
        public let confidence: Double
        /// 是否为 CJK（中日韩）语言
        public let isCJK: Bool

        /// 常用语言常量
        public static let english = DetectedLanguage(code: "en", confidence: 1.0, isCJK: false)
        public static let chinese = DetectedLanguage(code: "zh-Hans", confidence: 1.0, isCJK: true)
        public static let unknown = DetectedLanguage(code: "und", confidence: 0.0, isCJK: false)
    }

    // MARK: - Language Detection

    /// 检测文本语言
    ///
    /// 使用 NLLanguageRecognizer，短文本 (<3 字符) 回退到 CJK 字符检测。
    /// 同步调用，<1ms。
    public static func detectLanguage(_ text: String) -> DetectedLanguage {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }

        // 短文本 NLLanguageRecognizer 不可靠，回退到字符检测
        if trimmed.count < 3 {
            let hasCJK = containsCJK(trimmed)
            return DetectedLanguage(
                code: hasCJK ? "zh-Hans" : "en",
                confidence: 0.5,
                isCJK: hasCJK
            )
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)

        guard let dominant = recognizer.dominantLanguage else {
            let hasCJK = containsCJK(trimmed)
            return DetectedLanguage(
                code: hasCJK ? "zh-Hans" : "und",
                confidence: 0.0,
                isCJK: hasCJK
            )
        }

        // 获取置信度
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        let confidence = hypotheses[dominant] ?? 0.0

        let code = dominant.rawValue
        let isCJK = Self.cjkLanguageCodes.contains(code)

        return DetectedLanguage(code: code, confidence: confidence, isCJK: isCJK)
    }

    /// CJK 语言代码集合
    private static let cjkLanguageCodes: Set<String> = [
        "zh-Hans", "zh-Hant", "ja", "ko"
    ]

    // MARK: - Query Expansion

    /// 同步扩展 — FTS 即时路径
    ///
    /// 仅使用词典翻译，<1ms。引号查询不翻译。
    public static func expandSync(
        _ query: String,
        parsed: ParsedQuery,
        dictionary: TranslationDictionary
    ) -> ExpandedQuery {
        let language = detectLanguage(parsed.positiveText)

        // 引号查询 = 精确匹配意图，不翻译
        guard !parsed.hasQuotedPhrase else {
            return ExpandedQuery(
                parsed: parsed,
                language: language,
                translatedPositiveText: nil,
                translatedFTSQuery: nil
            )
        }

        // 确定翻译方向
        let (source, target) = translationDirection(for: language)
        guard let source, let target else {
            return ExpandedQuery(
                parsed: parsed,
                language: language,
                translatedPositiveText: nil,
                translatedFTSQuery: nil
            )
        }

        // 词典翻译正向文本
        let translated = dictionary.translateSync(
            parsed.positiveText, from: source, to: target
        )

        // 跳过无效翻译（翻译结果 = 原文，说明词典没命中）
        guard let translated, translated != parsed.positiveText else {
            return ExpandedQuery(
                parsed: parsed,
                language: language,
                translatedPositiveText: nil,
                translatedFTSQuery: nil
            )
        }

        // 构造翻译后的 FTS 查询（含负向词翻译）
        let translatedFTS = buildTranslatedFTSQuery(
            translatedPositive: translated,
            negativeTerms: parsed.negativeTerms,
            dictionary: dictionary,
            source: source,
            target: target
        )

        return ExpandedQuery(
            parsed: parsed,
            language: language,
            translatedPositiveText: translated,
            translatedFTSQuery: translatedFTS
        )
    }

    /// 异步扩展 — 向量 debounce 路径
    ///
    /// 支持 Apple Translation (macOS 15+)，降级到词典。
    /// 引号查询不翻译。
    public static func expand(
        _ query: String,
        parsed: ParsedQuery,
        translator: (any TranslationService)?
    ) async -> ExpandedQuery {
        let language = detectLanguage(parsed.positiveText)

        // 引号查询不翻译
        guard !parsed.hasQuotedPhrase else {
            return ExpandedQuery(
                parsed: parsed,
                language: language,
                translatedPositiveText: nil,
                translatedFTSQuery: nil
            )
        }

        let (source, target) = translationDirection(for: language)
        guard let source, let target else {
            return ExpandedQuery(
                parsed: parsed,
                language: language,
                translatedPositiveText: nil,
                translatedFTSQuery: nil
            )
        }

        // 尝试翻译器
        var translated: String?
        if let translator, translator.isAvailable {
            translated = try? await translator.translate(
                parsed.positiveText, from: source, to: target
            )
        }

        // 翻译器失败或不可用 → 回退到词典
        if translated == nil || translated == parsed.positiveText {
            translated = TranslationDictionary.shared.translateSync(
                parsed.positiveText, from: source, to: target
            )
        }

        guard let translated, translated != parsed.positiveText else {
            return ExpandedQuery(
                parsed: parsed,
                language: language,
                translatedPositiveText: nil,
                translatedFTSQuery: nil
            )
        }

        // 构造翻译后的 FTS 查询
        let translatedFTS = buildTranslatedFTSQuery(
            translatedPositive: translated,
            negativeTerms: parsed.negativeTerms,
            dictionary: TranslationDictionary.shared,
            source: source,
            target: target
        )

        return ExpandedQuery(
            parsed: parsed,
            language: language,
            translatedPositiveText: translated,
            translatedFTSQuery: translatedFTS
        )
    }

    // MARK: - CJK Segmentation

    /// CJK 分词
    ///
    /// 使用 NLTokenizer(.word) 分词，对中日韩文本效果好。
    /// 英文文本按空格分割。
    public static func segmentCJK(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = trimmed

        var tokens: [String] = []
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let token = String(trimmed[range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                tokens.append(token)
            }
            return true
        }

        return tokens
    }

    // MARK: - Helpers

    /// 确定翻译方向
    ///
    /// CJK → 翻译到英文; 英文 → 翻译到中文; 其他 → 不翻译
    static func translationDirection(
        for language: DetectedLanguage
    ) -> (source: String?, target: String?) {
        if language.isCJK {
            return (language.code, "en")
        }
        if language.code == "en" {
            return ("en", "zh-Hans")
        }
        // 未知或其他语言，不翻译
        return (nil, nil)
    }

    /// 构造翻译后的 FTS5 查询
    ///
    /// 将翻译后的正向文本与（可选翻译的）负向词组合。
    private static func buildTranslatedFTSQuery(
        translatedPositive: String,
        negativeTerms: [String],
        dictionary: TranslationDictionary,
        source: String,
        target: String
    ) -> String {
        if negativeTerms.isEmpty {
            return translatedPositive
        }

        // 翻译负向词
        let translatedNegatives = negativeTerms.compactMap { term -> String? in
            dictionary.translateSync(term, from: source, to: target) ?? term
        }

        let notClauses = translatedNegatives.map { "NOT \($0)" }.joined(separator: " ")
        return "\(translatedPositive) \(notClauses)"
    }

    /// 检测字符串是否包含 CJK 字符
    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3400...0x4DBF).contains(scalar.value) ||
            (0x3040...0x30FF).contains(scalar.value) ||
            (0xAC00...0xD7AF).contains(scalar.value)
        }
    }
}
