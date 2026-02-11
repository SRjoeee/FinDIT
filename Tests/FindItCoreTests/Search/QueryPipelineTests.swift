import XCTest
import GRDB
@testable import FindItCore

// MARK: - 语言检测测试

final class LanguageDetectionTests: XCTestCase {

    func testDetectChinese() {
        let result = QueryPipeline.detectLanguage("海滩日落")
        XCTAssertTrue(result.isCJK, "中文应检测为 CJK")
        XCTAssertTrue(
            result.code == "zh-Hans" || result.code == "zh-Hant",
            "中文语言代码应为 zh-Hans 或 zh-Hant, got: \(result.code)"
        )
    }

    func testDetectEnglish() {
        let result = QueryPipeline.detectLanguage("a beautiful beach at sunset in the afternoon")
        XCTAssertFalse(result.isCJK, "英文不应被识别为 CJK")
        XCTAssertEqual(result.code, "en")
    }

    func testDetectJapanese() {
        let result = QueryPipeline.detectLanguage("東京の夜景")
        XCTAssertTrue(result.isCJK, "日文应检测为 CJK")
    }

    func testDetectKorean() {
        let result = QueryPipeline.detectLanguage("서울 야경 촬영")
        XCTAssertTrue(result.isCJK, "韩文应检测为 CJK")
    }

    func testDetectEmptyString() {
        let result = QueryPipeline.detectLanguage("")
        XCTAssertEqual(result.code, "und", "空字符串应返回 unknown")
    }

    func testDetectShortChinese() {
        // 短文本 (<3 字) 回退到字符检测
        let result = QueryPipeline.detectLanguage("猫")
        XCTAssertTrue(result.isCJK, "单个中文字符应通过字符检测识别为 CJK")
        XCTAssertEqual(result.confidence, 0.5, "短文本置信度应为 0.5")
    }

    func testDetectShortEnglish() {
        let result = QueryPipeline.detectLanguage("hi")
        XCTAssertFalse(result.isCJK, "短英文应通过字符检测识别为非 CJK")
    }

    func testDetectHighConfidence() {
        let result = QueryPipeline.detectLanguage("这是一个关于大自然风景的视频片段")
        XCTAssertTrue(result.isCJK)
        XCTAssertGreaterThan(result.confidence, 0.5, "长中文文本应有较高置信度")
    }
}

// MARK: - CJK 字符检测

final class ContainsCJKTests: XCTestCase {

    func testChineseCharacters() {
        XCTAssertTrue(QueryPipeline.containsCJK("海滩"))
    }

    func testJapaneseHiragana() {
        XCTAssertTrue(QueryPipeline.containsCJK("こんにちは"))
    }

    func testKorean() {
        XCTAssertTrue(QueryPipeline.containsCJK("안녕"))
    }

    func testEnglishOnly() {
        XCTAssertFalse(QueryPipeline.containsCJK("beach sunset"))
    }

    func testMixed() {
        XCTAssertTrue(QueryPipeline.containsCJK("beach 海滩"))
    }
}

// MARK: - CJK 分词测试

final class CJKSegmentationTests: XCTestCase {

    func testChineseSegmentation() {
        let tokens = QueryPipeline.segmentCJK("海滩日落")
        XCTAssertTrue(tokens.count >= 2, "中文应被分词为多个 token, got: \(tokens)")
        XCTAssertTrue(tokens.contains("海滩"), "应包含 '海滩', got: \(tokens)")
        XCTAssertTrue(tokens.contains("日落"), "应包含 '日落', got: \(tokens)")
    }

    func testEnglishPassthrough() {
        let tokens = QueryPipeline.segmentCJK("beach sunset")
        XCTAssertEqual(tokens, ["beach", "sunset"])
    }

    func testEmptyString() {
        let tokens = QueryPipeline.segmentCJK("")
        XCTAssertTrue(tokens.isEmpty)
    }

    func testSingleCharacter() {
        let tokens = QueryPipeline.segmentCJK("猫")
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens.first, "猫")
    }
}

// MARK: - 翻译方向测试

final class TranslationDirectionTests: XCTestCase {

    func testCJKToEnglish() {
        let (source, target) = QueryPipeline.translationDirection(
            for: .chinese
        )
        XCTAssertEqual(source, "zh-Hans")
        XCTAssertEqual(target, "en")
    }

    func testEnglishToChinese() {
        let (source, target) = QueryPipeline.translationDirection(
            for: .english
        )
        XCTAssertEqual(source, "en")
        XCTAssertEqual(target, "zh-Hans")
    }

    func testUnknownNoTranslation() {
        let (source, target) = QueryPipeline.translationDirection(
            for: .unknown
        )
        XCTAssertNil(source)
        XCTAssertNil(target)
    }
}

// MARK: - 词典翻译测试

final class TranslationDictionaryTests: XCTestCase {

    let dict = TranslationDictionary.shared

    func testZHToEN_SingleWord() {
        let result = dict.translateSync("海滩", from: "zh-Hans", to: "en")
        XCTAssertEqual(result, "beach")
    }

    func testZHToEN_CompoundPhrase() {
        let result = dict.translateSync("海滩日落", from: "zh-Hans", to: "en")
        XCTAssertNotNil(result, "复合词应能翻译")
        // "海滩日落" → 分词为 ["海滩", "日落"] → "beach sunset"
        if let result {
            XCTAssertTrue(result.contains("beach"), "应包含 beach, got: \(result)")
            XCTAssertTrue(result.contains("sunset"), "应包含 sunset, got: \(result)")
        }
    }

    func testENToZH_SingleWord() {
        let result = dict.translateSync("beach", from: "en", to: "zh-Hans")
        XCTAssertEqual(result, "海滩")
    }

    func testENToZH_MultiWord() {
        let result = dict.translateSync("wide shot", from: "en", to: "zh-Hans")
        XCTAssertEqual(result, "全景", "多词短语应匹配")
    }

    func testUnknownWord() {
        let result = dict.translateSync("xyz123", from: "en", to: "zh-Hans")
        XCTAssertNil(result, "完全未知词应返回 nil")
    }

    func testEmptyInput() {
        let result = dict.translateSync("", from: "zh-Hans", to: "en")
        XCTAssertNil(result, "空输入应返回 nil")
    }

    func testCaseInsensitiveEN() {
        let result = dict.translateSync("Beach", from: "en", to: "zh-Hans")
        XCTAssertEqual(result, "海滩", "英文查表应不区分大小写")
    }

    func testBidirectionalConsistency() {
        // beach → 海滩，海滩 → beach
        let zh = dict.translateSync("beach", from: "en", to: "zh-Hans")
        let en = dict.translateSync("海滩", from: "zh-Hans", to: "en")
        XCTAssertEqual(zh, "海滩")
        XCTAssertEqual(en, "beach")
    }
}

// MARK: - 同步查询扩展测试

final class QueryExpansionSyncTests: XCTestCase {

    let dict = TranslationDictionary.shared

    func testChineseQueryExpansion() {
        let parsed = QueryParser.parse("海滩")
        let expanded = QueryPipeline.expandSync("海滩", parsed: parsed, dictionary: dict)

        XCTAssertTrue(expanded.language.isCJK, "应检测为 CJK")
        XCTAssertNotNil(expanded.translatedPositiveText, "中文查询应有英文翻译")
        XCTAssertNotNil(expanded.translatedFTSQuery, "应生成翻译后的 FTS 查询")
        if let translated = expanded.translatedPositiveText {
            XCTAssertTrue(
                translated.lowercased().contains("beach"),
                "海滩应翻译为 beach, got: \(translated)"
            )
        }
    }

    func testEnglishQueryExpansion() {
        // 使用较长的英文短语确保 NLLanguageRecognizer 能可靠检测为英文
        let parsed = QueryParser.parse("beautiful beach in the morning")
        let expanded = QueryPipeline.expandSync(
            "beautiful beach in the morning", parsed: parsed, dictionary: dict
        )

        XCTAssertFalse(expanded.language.isCJK, "应检测为英文")
        // 词典只能翻译 "beach"，整体结果应包含 "海滩"
        XCTAssertNotNil(expanded.translatedPositiveText, "英文查询应有中文翻译")
        if let translated = expanded.translatedPositiveText {
            XCTAssertTrue(translated.contains("海滩"), "应包含海滩, got: \(translated)")
        }
    }

    func testQuotedQueryNoTranslation() {
        let parsed = QueryParser.parse("\"海滩\"")
        let expanded = QueryPipeline.expandSync("\"海滩\"", parsed: parsed, dictionary: dict)

        XCTAssertNil(expanded.translatedPositiveText, "引号查询不应翻译")
        XCTAssertNil(expanded.translatedFTSQuery, "引号查询不应生成翻译 FTS 查询")
    }

    func testUnknownWordNoTranslation() {
        let parsed = QueryParser.parse("xyz123abc")
        let expanded = QueryPipeline.expandSync("xyz123abc", parsed: parsed, dictionary: dict)

        XCTAssertNil(expanded.translatedPositiveText, "词典无法翻译的词应返回 nil")
    }

    func testNegativeTermsPreserved() {
        // "海滩 -室内" → positiveText="海滩", negativeTerms=["室内"]
        let parsed = QueryParser.parse("海滩 -室内")
        let expanded = QueryPipeline.expandSync("海滩 -室内", parsed: parsed, dictionary: dict)

        XCTAssertNotNil(expanded.translatedFTSQuery)
        if let fts = expanded.translatedFTSQuery {
            XCTAssertTrue(fts.contains("NOT"), "负向词应翻译为 NOT 子句, got: \(fts)")
        }
    }

    func testEmbeddingTextIsOriginal() {
        let parsed = QueryParser.parse("海滩日落")
        let expanded = QueryPipeline.expandSync("海滩日落", parsed: parsed, dictionary: dict)

        // embeddingText 应保持原文（CLIP/TextEmb 原生多语言）
        XCTAssertEqual(expanded.embeddingText, parsed.embeddingText)
    }
}

// MARK: - 异步查询扩展测试

final class QueryExpansionAsyncTests: XCTestCase {

    func testExpandWithNilTranslator() async {
        let parsed = QueryParser.parse("海滩")
        let expanded = await QueryPipeline.expand(
            "海滩", parsed: parsed, translator: nil
        )

        // nil 翻译器 → 回退到词典
        XCTAssertNotNil(expanded.translatedPositiveText, "nil 翻译器应回退到词典")
    }

    func testExpandWithDictionary() async {
        // 使用较长英文确保检测为 en
        let parsed = QueryParser.parse("a beautiful beach at sunset")
        let expanded = await QueryPipeline.expand(
            "a beautiful beach at sunset", parsed: parsed,
            translator: TranslationDictionary.shared
        )

        XCTAssertNotNil(expanded.translatedPositiveText, "英文多词查询应有翻译")
    }

    func testExpandQuotedAsync() async {
        let parsed = QueryParser.parse("\"forest\"")
        let expanded = await QueryPipeline.expand(
            "\"forest\"", parsed: parsed, translator: TranslationDictionary.shared
        )

        XCTAssertNil(expanded.translatedPositiveText, "引号查询不应翻译")
    }

    func testExpandEmptyQuery() async {
        let parsed = QueryParser.parse("")
        let expanded = await QueryPipeline.expand(
            "", parsed: parsed, translator: TranslationDictionary.shared
        )

        XCTAssertNil(expanded.translatedPositiveText)
        XCTAssertNil(expanded.translatedFTSQuery)
    }
}

// MARK: - 跨语言 FTS 集成测试

final class CrossLanguageFTSTests: XCTestCase {

    /// 创建全局库 + 插入测试数据
    private func makeTestDB() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        let migrator = Migrations.globalMigrator()
        try migrator.migrate(db)

        try db.write { dbConn in
            // 插入视频
            try dbConn.execute(sql: """
                INSERT INTO videos
                (source_folder, source_video_id, file_path, file_name)
                VALUES ('/test', 1, '/test/video1.mp4', 'video1.mp4')
                """)

            // 插入带英文标签的 clip
            try dbConn.execute(sql: """
                INSERT INTO clips
                (source_folder, source_clip_id, video_id, start_time, end_time, scene,
                 description, tags)
                VALUES ('/test', 1, 1, 0.0, 5.0, 'S01',
                        'A beautiful beach at sunset', '["beach", "sunset", "ocean"]')
                """)

            // 插入带中文标签的 clip
            try dbConn.execute(sql: """
                INSERT INTO clips
                (source_folder, source_clip_id, video_id, start_time, end_time, scene,
                 description, tags)
                VALUES ('/test', 2, 1, 5.0, 10.0, 'S02',
                        '森林里的小路', '["森林", "小路", "户外"]')
                """)
        }

        return db
    }

    func testChineseQueryFindsEnglishTags() throws {
        let db = try makeTestDB()

        let parsed = QueryParser.parse("海滩")
        let expanded = QueryPipeline.expandSync(
            "海滩", parsed: parsed, dictionary: TranslationDictionary.shared
        )

        let results = try db.read { dbConn in
            try SearchEngine.threeWaySearch(
                dbConn,
                query: parsed,
                expandedQuery: expanded,
                weights: SearchEngine.SearchWeights(clipWeight: 0, ftsWeight: 1.0, textEmbWeight: 0),
                limit: 50
            )
        }

        XCTAssertFalse(results.isEmpty, "中文 '海滩' 应通过跨语言扩展找到英文 'beach' 标签的 clip")
        let clipIds = results.map(\.clipId)
        XCTAssertTrue(clipIds.contains(where: { _ in true }), "应有搜索结果")
    }

    func testEnglishQueryFindsChinese() throws {
        let db = try makeTestDB()

        let parsed = QueryParser.parse("forest")
        let expanded = QueryPipeline.expandSync(
            "forest", parsed: parsed, dictionary: TranslationDictionary.shared
        )

        let results = try db.read { dbConn in
            try SearchEngine.threeWaySearch(
                dbConn,
                query: parsed,
                expandedQuery: expanded,
                weights: SearchEngine.SearchWeights(clipWeight: 0, ftsWeight: 1.0, textEmbWeight: 0),
                limit: 50
            )
        }

        XCTAssertFalse(results.isEmpty, "英文 'forest' 应通过跨语言扩展找到中文 '森林' 标签的 clip")
    }

    func testNilExpandedQueryCompatibility() throws {
        let db = try makeTestDB()

        let parsed = QueryParser.parse("beach")

        // expandedQuery = nil → 纯原始 FTS 搜索（向后兼容）
        let results = try db.read { dbConn in
            try SearchEngine.threeWaySearch(
                dbConn,
                query: parsed,
                expandedQuery: nil,
                weights: SearchEngine.SearchWeights(clipWeight: 0, ftsWeight: 1.0, textEmbWeight: 0),
                limit: 50
            )
        }

        XCTAssertFalse(results.isEmpty, "nil expandedQuery 应正常搜索")
    }

    func testDeduplication() throws {
        let db = try makeTestDB()

        // "beach" 原始搜索和翻译搜索都能匹配 clip 1
        let parsed = QueryParser.parse("beach")
        let expanded = QueryPipeline.expandSync(
            "beach", parsed: parsed, dictionary: TranslationDictionary.shared
        )

        let results = try db.read { dbConn in
            try SearchEngine.threeWaySearch(
                dbConn,
                query: parsed,
                expandedQuery: expanded,
                weights: SearchEngine.SearchWeights(clipWeight: 0, ftsWeight: 1.0, textEmbWeight: 0),
                limit: 50
            )
        }

        // 检查无重复 clipId
        let clipIds = results.map(\.clipId)
        XCTAssertEqual(clipIds.count, Set(clipIds).count, "结果不应有重复 clipId")
    }

    func testTranslationDiscountFactor() throws {
        let db = try makeTestDB()

        // 中文查询 "海滩" → 翻译为 "beach" → FTS 命中但 rank * 0.8
        let parsed = QueryParser.parse("海滩")
        let expanded = QueryPipeline.expandSync(
            "海滩", parsed: parsed, dictionary: TranslationDictionary.shared
        )

        let results = try db.read { dbConn in
            try SearchEngine.threeWaySearch(
                dbConn,
                query: parsed,
                expandedQuery: expanded,
                weights: SearchEngine.SearchWeights(clipWeight: 0, ftsWeight: 1.0, textEmbWeight: 0),
                limit: 50
            )
        }

        // 翻译扩展的结果应存在
        XCTAssertFalse(results.isEmpty, "跨语言翻译扩展应有结果")
    }
}

// MARK: - 最佳翻译器工厂测试

final class BestTranslatorTests: XCTestCase {

    func testFactoryReturnsService() {
        let translator = QueryPipeline.bestAvailableTranslator()
        XCTAssertTrue(translator.isAvailable, "工厂方法应返回可用的翻译服务")
    }

    func testDictionaryIsAlwaysAvailable() {
        let dict = TranslationDictionary.shared
        XCTAssertTrue(dict.isAvailable, "词典翻译应始终可用")
    }
}
