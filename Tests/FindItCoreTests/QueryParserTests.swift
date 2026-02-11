import XCTest
@testable import FindItCore

// MARK: - QueryParser Tests

final class QueryParserTests: XCTestCase {

    // MARK: - Basic Parsing

    func testParseSimpleQuery() {
        let result = QueryParser.parse("海滩 日落")
        XCTAssertEqual(result.positiveText, "海滩 日落")
        XCTAssertTrue(result.negativeTerms.isEmpty)
        XCTAssertFalse(result.hasQuotedPhrase)
        XCTAssertEqual(result.rawQuery, "海滩 日落")
    }

    func testParseEmptyQuery() {
        let result = QueryParser.parse("")
        XCTAssertEqual(result.positiveText, "")
        XCTAssertTrue(result.negativeTerms.isEmpty)
        XCTAssertTrue(result.isEmpty)
    }

    func testParseWhitespaceOnly() {
        let result = QueryParser.parse("   ")
        XCTAssertEqual(result.positiveText, "")
        XCTAssertTrue(result.isEmpty)
    }

    func testParseSingleWord() {
        let result = QueryParser.parse("海滩")
        XCTAssertEqual(result.positiveText, "海滩")
        XCTAssertTrue(result.negativeTerms.isEmpty)
    }

    // MARK: - Negative Query: Dash Syntax

    func testParseDashNegative() {
        let result = QueryParser.parse("海滩 -雨天")
        XCTAssertEqual(result.positiveText, "海滩")
        XCTAssertEqual(result.negativeTerms, ["雨天"])
    }

    func testParseMultipleDashNegatives() {
        let result = QueryParser.parse("海滩 日落 -雨天 -夜晚")
        XCTAssertEqual(result.positiveText, "海滩 日落")
        XCTAssertEqual(result.negativeTerms, ["雨天", "夜晚"])
    }

    func testParseDashAloneNotNegative() {
        // 单独的 `-` 不应被视为负向词
        let result = QueryParser.parse("海滩 - 日落")
        XCTAssertEqual(result.positiveText, "海滩 - 日落")
        XCTAssertTrue(result.negativeTerms.isEmpty)
    }

    // MARK: - Negative Query: NOT Syntax

    func testParseNOTNegative() {
        let result = QueryParser.parse("海滩 NOT 夜晚")
        XCTAssertEqual(result.positiveText, "海滩")
        XCTAssertEqual(result.negativeTerms, ["夜晚"])
    }

    func testParseNOTAtEnd() {
        // NOT 在末尾没有后续词，应保留为正向
        let result = QueryParser.parse("海滩 NOT")
        XCTAssertEqual(result.positiveText, "海滩 NOT")
        XCTAssertTrue(result.negativeTerms.isEmpty)
    }

    func testParseNOTCaseSensitive() {
        // 只识别大写 NOT，小写 not 视为普通关键词
        let result = QueryParser.parse("海滩 not 夜晚")
        XCTAssertEqual(result.positiveText, "海滩 not 夜晚")
        XCTAssertTrue(result.negativeTerms.isEmpty)
    }

    func testParseMixedNegatives() {
        let result = QueryParser.parse("海滩 -雨天 NOT 夜晚 日落")
        XCTAssertEqual(result.positiveText, "海滩 日落")
        XCTAssertEqual(result.negativeTerms, ["雨天", "夜晚"])
    }

    // MARK: - Quoted Phrases

    func testParseQuotedPhrase() {
        let result = QueryParser.parse("\"红色跑车\"")
        XCTAssertEqual(result.positiveText, "\"红色跑车\"")
        XCTAssertTrue(result.hasQuotedPhrase)
    }

    func testParseQuotedWithNegative() {
        let result = QueryParser.parse("\"红色跑车\" -卡车")
        XCTAssertEqual(result.positiveText, "\"红色跑车\"")
        XCTAssertEqual(result.negativeTerms, ["卡车"])
        XCTAssertTrue(result.hasQuotedPhrase)
    }

    func testParseQuotedPhraseWithSurrounding() {
        let result = QueryParser.parse("城市 \"日落余晖\" 海滩")
        XCTAssertEqual(result.positiveText, "城市 \"日落余晖\" 海滩")
        XCTAssertTrue(result.hasQuotedPhrase)
    }

    // MARK: - FTS Query Generation

    func testFtsQueryNoNegatives() {
        let result = QueryParser.parse("海滩 日落")
        XCTAssertEqual(result.ftsQuery, "海滩 日落")
    }

    func testFtsQueryWithNegatives() {
        let result = QueryParser.parse("海滩 -雨天 -夜晚")
        XCTAssertEqual(result.ftsQuery, "海滩 NOT 雨天 NOT 夜晚")
    }

    func testFtsQueryMixed() {
        let result = QueryParser.parse("海滩 日落 NOT 雨天")
        XCTAssertEqual(result.ftsQuery, "海滩 日落 NOT 雨天")
    }

    // MARK: - Embedding Text

    func testEmbeddingTextExcludesNegatives() {
        let result = QueryParser.parse("海滩 日落 -雨天 NOT 夜晚")
        XCTAssertEqual(result.embeddingText, "海滩 日落")
    }

    func testEmbeddingTextPreservesQuotes() {
        let result = QueryParser.parse("\"海滩日落\" -雨天")
        XCTAssertEqual(result.embeddingText, "\"海滩日落\"")
    }

    // MARK: - English Queries

    func testParseEnglishNegative() {
        let result = QueryParser.parse("beach sunset -rain")
        XCTAssertEqual(result.positiveText, "beach sunset")
        XCTAssertEqual(result.negativeTerms, ["rain"])
    }

    func testParseEnglishNOT() {
        let result = QueryParser.parse("beach NOT night")
        XCTAssertEqual(result.positiveText, "beach")
        XCTAssertEqual(result.negativeTerms, ["night"])
    }

    // MARK: - Equatable

    func testParsedQueryEquatable() {
        let a = QueryParser.parse("海滩 -雨天")
        let b = QueryParser.parse("海滩 -雨天")
        XCTAssertEqual(a, b)
    }

    func testParsedQueryNotEqual() {
        let a = QueryParser.parse("海滩")
        let b = QueryParser.parse("海滩 -雨天")
        XCTAssertNotEqual(a, b)
    }
}

// MARK: - SearchQuery Tests

final class SearchQueryTests: XCTestCase {

    func testTextQueryProperties() {
        let q = SearchQuery.text("海滩")
        XCTAssertEqual(q.textQuery, "海滩")
        XCTAssertNil(q.imageData)
        XCTAssertTrue(q.hasText)
        XCTAssertFalse(q.hasImage)
    }

    func testImageQueryProperties() {
        let data = Data([0x01, 0x02, 0x03])
        let q = SearchQuery.image(data)
        XCTAssertNil(q.textQuery)
        XCTAssertEqual(q.imageData, data)
        XCTAssertFalse(q.hasText)
        XCTAssertTrue(q.hasImage)
    }

    func testTextWithImageQueryProperties() {
        let data = Data([0x01, 0x02, 0x03])
        let q = SearchQuery.textWithImage("海滩", data)
        XCTAssertEqual(q.textQuery, "海滩")
        XCTAssertEqual(q.imageData, data)
        XCTAssertTrue(q.hasText)
        XCTAssertTrue(q.hasImage)
    }
}

// MARK: - Tokenizer Tests

final class QueryTokenizerTests: XCTestCase {

    func testTokenizeSimple() {
        let tokens = QueryParser.tokenize("hello world")
        XCTAssertEqual(tokens, ["hello", "world"])
    }

    func testTokenizeQuotedPhrase() {
        let tokens = QueryParser.tokenize("\"hello world\" foo")
        XCTAssertEqual(tokens, ["\"hello world\"", "foo"])
    }

    func testTokenizeMultipleSpaces() {
        let tokens = QueryParser.tokenize("a   b   c")
        XCTAssertEqual(tokens, ["a", "b", "c"])
    }

    func testTokenizeNegativeAndQuoted() {
        let tokens = QueryParser.tokenize("\"red car\" -truck beach")
        XCTAssertEqual(tokens, ["\"red car\"", "-truck", "beach"])
    }

    func testTokenizeUnmatchedQuote() {
        // 未闭合引号 → 剩余部分作为一个 token
        let tokens = QueryParser.tokenize("\"hello world")
        XCTAssertEqual(tokens, ["\"hello world"])
    }

    func testTokenizeEmpty() {
        let tokens = QueryParser.tokenize("")
        XCTAssertTrue(tokens.isEmpty)
    }

    func testTokenizeCJK() {
        let tokens = QueryParser.tokenize("海滩 \"红色跑车\" -雨天")
        XCTAssertEqual(tokens, ["海滩", "\"红色跑车\"", "-雨天"])
    }
}
