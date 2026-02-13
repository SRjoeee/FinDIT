import XCTest
@testable import FindItCore

final class STTProcessorTests: XCTestCase {

    // MARK: - formatSRTTimestamp

    func testFormatSRTTimestampZero() {
        XCTAssertEqual(STTProcessor.formatSRTTimestamp(0.0), "00:00:00,000")
    }

    func testFormatSRTTimestampSimple() {
        XCTAssertEqual(STTProcessor.formatSRTTimestamp(5.5), "00:00:05,500")
    }

    func testFormatSRTTimestampMinutes() {
        XCTAssertEqual(STTProcessor.formatSRTTimestamp(65.5), "00:01:05,500")
    }

    func testFormatSRTTimestampHours() {
        XCTAssertEqual(STTProcessor.formatSRTTimestamp(3723.123), "01:02:03,123")
    }

    func testFormatSRTTimestampNegativeClamped() {
        // 负值钳位到 0
        XCTAssertEqual(STTProcessor.formatSRTTimestamp(-1.0), "00:00:00,000")
    }

    func testFormatSRTTimestampSubMillisecond() {
        // 0.9999... → 截断而非四舍五入
        XCTAssertEqual(STTProcessor.formatSRTTimestamp(1.9999), "00:00:01,999")
    }

    // MARK: - parseSRTTimestamp

    func testParseSRTTimestampBasic() {
        XCTAssertEqual(STTProcessor.parseSRTTimestamp("00:01:05,500"), 65.5)
    }

    func testParseSRTTimestampZero() {
        XCTAssertEqual(STTProcessor.parseSRTTimestamp("00:00:00,000"), 0.0)
    }

    func testParseSRTTimestampHours() {
        let result = STTProcessor.parseSRTTimestamp("01:02:03,123")!
        XCTAssertEqual(result, 3723.123, accuracy: 0.001)
    }

    func testParseSRTTimestampInvalid() {
        XCTAssertNil(STTProcessor.parseSRTTimestamp("invalid"))
    }

    func testParseSRTTimestampMissingComma() {
        XCTAssertNil(STTProcessor.parseSRTTimestamp("00:01:05.500"))
    }

    // MARK: - generateSRT

    func testGenerateSRTSingleSegment() {
        let segments = [
            TranscriptSegment(index: 1, startTime: 0.0, endTime: 5.5, text: "Hello world")
        ]
        let srt = STTProcessor.generateSRT(from: segments)
        let expected = "1\n00:00:00,000 --> 00:00:05,500\nHello world\n"
        XCTAssertEqual(srt, expected)
    }

    func testGenerateSRTMultipleSegments() {
        let segments = [
            TranscriptSegment(index: 1, startTime: 0, endTime: 5, text: "第一句"),
            TranscriptSegment(index: 2, startTime: 5, endTime: 10, text: "第二句"),
            TranscriptSegment(index: 3, startTime: 10, endTime: 18, text: "第三句"),
        ]
        let srt = STTProcessor.generateSRT(from: segments)

        XCTAssertTrue(srt.contains("1\n00:00:00,000 --> 00:00:05,000\n第一句"))
        XCTAssertTrue(srt.contains("2\n00:00:05,000 --> 00:00:10,000\n第二句"))
        XCTAssertTrue(srt.contains("3\n00:00:10,000 --> 00:00:18,000\n第三句"))
    }

    func testGenerateSRTEmpty() {
        XCTAssertEqual(STTProcessor.generateSRT(from: []), "")
    }

    // MARK: - parseSRT

    func testParseSRTBasic() {
        let srt = """
        1
        00:00:00,000 --> 00:00:05,500
        Hello world

        2
        00:00:05,500 --> 00:00:12,000
        你好世界
        """
        let segments = STTProcessor.parseSRT(srt)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].index, 1)
        XCTAssertEqual(segments[0].startTime, 0.0)
        XCTAssertEqual(segments[0].endTime, 5.5)
        XCTAssertEqual(segments[0].text, "Hello world")
        XCTAssertEqual(segments[1].text, "你好世界")
    }

    func testParseSRTMultilineText() {
        let srt = """
        1
        00:00:00,000 --> 00:00:05,000
        First line
        Second line
        """
        let segments = STTProcessor.parseSRT(srt)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "First line\nSecond line")
    }

    func testParseSRTEmpty() {
        XCTAssertTrue(STTProcessor.parseSRT("").isEmpty)
    }

    func testParseSRTMalformed() {
        // 缺少时间戳行，应跳过该块
        let srt = """
        1
        Hello world

        2
        00:00:05,000 --> 00:00:10,000
        Valid segment
        """
        let segments = STTProcessor.parseSRT(srt)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Valid segment")
    }

    // MARK: - SRT Roundtrip

    func testSRTRoundtrip() {
        let original = [
            TranscriptSegment(index: 1, startTime: 0, endTime: 5.5, text: "Hello"),
            TranscriptSegment(index: 2, startTime: 5.5, endTime: 12.0, text: "你好世界"),
            TranscriptSegment(index: 3, startTime: 12.0, endTime: 18.75, text: "The end"),
        ]
        let srt = STTProcessor.generateSRT(from: original)
        let parsed = STTProcessor.parseSRT(srt)

        XCTAssertEqual(parsed.count, original.count)
        for (o, p) in zip(original, parsed) {
            XCTAssertEqual(p.text, o.text)
            XCTAssertEqual(p.startTime, o.startTime, accuracy: 0.001)
            XCTAssertEqual(p.endTime, o.endTime, accuracy: 0.001)
        }
    }

    // MARK: - resolveSRTPath

    func testResolveSRTPathBasic() {
        let paths = STTProcessor.resolveSRTPath(videoPath: "/Videos/clip.mp4")
        XCTAssertEqual(paths.primary, "/Videos/clip.srt")
    }

    func testResolveSRTPathFallbackFormat() {
        let paths = STTProcessor.resolveSRTPath(videoPath: "/any/video.mp4")
        XCTAssertTrue(paths.fallback.contains("FindIt/srt/"))
        XCTAssertTrue(paths.fallback.hasSuffix(".srt"))
    }

    func testResolveSRTPathChineseName() {
        let paths = STTProcessor.resolveSRTPath(videoPath: "/素材/海滩日落.mp4")
        XCTAssertEqual(paths.primary, "/素材/海滩日落.srt")
    }

    func testResolveSRTPathDifferentExtension() {
        let paths = STTProcessor.resolveSRTPath(videoPath: "/media/vlog.mov")
        XCTAssertEqual(paths.primary, "/media/vlog.srt")
    }

    // MARK: - mapTranscriptToClips

    func testMapTranscriptToClipsExactMatch() {
        let transcripts = [
            TranscriptSegment(index: 1, startTime: 0, endTime: 10, text: "hello")
        ]
        let scenes = [SceneSegment(startTime: 0, endTime: 10)]
        let result = STTProcessor.mapTranscriptToClips(
            transcriptSegments: transcripts, sceneSegments: scenes
        )
        XCTAssertEqual(result, ["hello"])
    }

    func testMapTranscriptToClipsOverlap() {
        let transcripts = [
            TranscriptSegment(index: 1, startTime: 0, endTime: 8, text: "A"),
            TranscriptSegment(index: 2, startTime: 8, endTime: 15, text: "B"),
        ]
        let scenes = [SceneSegment(startTime: 5, endTime: 12)]
        let result = STTProcessor.mapTranscriptToClips(
            transcriptSegments: transcripts, sceneSegments: scenes
        )
        XCTAssertEqual(result, ["A B"])
    }

    func testMapTranscriptToClipsNoOverlap() {
        let transcripts = [
            TranscriptSegment(index: 1, startTime: 20, endTime: 30, text: "text")
        ]
        let scenes = [SceneSegment(startTime: 0, endTime: 10)]
        let result = STTProcessor.mapTranscriptToClips(
            transcriptSegments: transcripts, sceneSegments: scenes
        )
        XCTAssertEqual(result, [nil])
    }

    func testMapTranscriptToClipsMultipleScenes() {
        let transcripts = [
            TranscriptSegment(index: 1, startTime: 0, endTime: 5, text: "开头"),
            TranscriptSegment(index: 2, startTime: 5, endTime: 12, text: "中间"),
            TranscriptSegment(index: 3, startTime: 12, endTime: 20, text: "结尾"),
        ]
        let scenes = [
            SceneSegment(startTime: 0, endTime: 10),
            SceneSegment(startTime: 10, endTime: 20),
        ]
        let result = STTProcessor.mapTranscriptToClips(
            transcriptSegments: transcripts, sceneSegments: scenes
        )
        XCTAssertEqual(result.count, 2)
        // 场景 [0-10]: "开头" 和 "中间" 重叠
        XCTAssertEqual(result[0], "开头 中间")
        // 场景 [10-20]: "中间" 和 "结尾" 重叠
        XCTAssertEqual(result[1], "中间 结尾")
    }

    func testMapTranscriptToClipsEmptyTranscript() {
        let scenes = [SceneSegment(startTime: 0, endTime: 10)]
        let result = STTProcessor.mapTranscriptToClips(
            transcriptSegments: [], sceneSegments: scenes
        )
        XCTAssertEqual(result, [nil])
    }

    // MARK: - Config

    func testDefaultConfig() {
        let config = STTProcessor.Config.default
        XCTAssertEqual(config.modelName, "openai_whisper-large-v3-v20240930")
        XCTAssertNil(config.language)
        XCTAssertTrue(config.wordTimestamps)
    }

    func testCustomConfig() {
        let config = STTProcessor.Config(modelName: "tiny", language: "zh", wordTimestamps: false)
        XCTAssertEqual(config.modelName, "tiny")
        XCTAssertEqual(config.language, "zh")
        XCTAssertFalse(config.wordTimestamps)
    }

    // MARK: - stableHash

    func testStableHashDeterministic() {
        let hash1 = STTProcessor.stableHash("/path/to/video.mp4")
        let hash2 = STTProcessor.stableHash("/path/to/video.mp4")
        XCTAssertEqual(hash1, hash2)
    }

    func testStableHashDifferentInputs() {
        let hash1 = STTProcessor.stableHash("/path/a.mp4")
        let hash2 = STTProcessor.stableHash("/path/b.mp4")
        XCTAssertNotEqual(hash1, hash2)
    }

    func testStableHashFormat() {
        let hash = STTProcessor.stableHash("test")
        XCTAssertEqual(hash.count, 16) // 16 位十六进制
    }

    // MARK: - stripWhisperTokens

    func testStripWhisperTokensBasic() {
        let input = "<|startoftranscript|><|en|><|transcribe|><|0.00|> I got it!<|0.50|>"
        XCTAssertEqual(STTProcessor.stripWhisperTokens(input), "I got it!")
    }

    func testStripWhisperTokensTimestampOnly() {
        let input = "<|0.50|> 9-4-1<|1.50|>"
        XCTAssertEqual(STTProcessor.stripWhisperTokens(input), "9-4-1")
    }

    func testStripWhisperTokensCleanText() {
        // 已经干净的文本不应被修改
        XCTAssertEqual(STTProcessor.stripWhisperTokens("Hello world"), "Hello world")
        XCTAssertEqual(STTProcessor.stripWhisperTokens("你好世界"), "你好世界")
    }

    func testStripWhisperTokensEmpty() {
        XCTAssertEqual(STTProcessor.stripWhisperTokens(""), "")
        XCTAssertEqual(STTProcessor.stripWhisperTokens("  "), "")
    }

    func testStripWhisperTokensOnlyTokens() {
        // 仅含 token 和标点，无有意义文字
        XCTAssertEqual(STTProcessor.stripWhisperTokens("<|startoftranscript|><|en|><|transcribe|><|0.00|> -<|5.00|>"), "")
    }

    func testStripWhisperTokensQuotedText() {
        let input = "<|8.00|> \"It's amazing. Sayaka is so good at passing exams.\"<|13.00|>"
        XCTAssertEqual(STTProcessor.stripWhisperTokens(input), "\"It's amazing. Sayaka is so good at passing exams.\"")
    }

    // MARK: - selectSampleRanges

    func testSelectSampleRangesSkipsScene0() {
        let scenes = [
            SceneSegment(startTime: 0, endTime: 15),     // 场景0 (打板)
            SceneSegment(startTime: 15, endTime: 45),    // 场景1
            SceneSegment(startTime: 45, endTime: 80),    // 场景2
            SceneSegment(startTime: 80, endTime: 120),   // 场景3
        ]
        let ranges = STTProcessor.selectSampleRanges(scenes: scenes)

        // 应跳过场景 0，从场景 1/2/3 中选取
        XCTAssertEqual(ranges.count, 3)
        // 第一个采样应从场景 1 开始
        XCTAssertEqual(ranges[0].startTime, 15.0)
    }

    func testSelectSampleRangesMaxSampleDuration() {
        let scenes = [
            SceneSegment(startTime: 0, endTime: 10),     // 场景0
            SceneSegment(startTime: 10, endTime: 100),   // 场景1 (90s)
        ]
        let ranges = STTProcessor.selectSampleRanges(scenes: scenes, sampleDuration: 30.0)

        // 应只从场景 1 采样，最长 30 秒
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].startTime, 10.0)
        XCTAssertEqual(ranges[0].endTime, 40.0) // 10 + 30
    }

    func testSelectSampleRangesSingleScene() {
        // 只有 1 个场景时，使用后半段
        let scenes = [
            SceneSegment(startTime: 0, endTime: 60),
        ]
        let ranges = STTProcessor.selectSampleRanges(scenes: scenes)

        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].startTime, 30.0) // 中点
    }

    func testSelectSampleRangesEmpty() {
        let ranges = STTProcessor.selectSampleRanges(scenes: [])
        XCTAssertTrue(ranges.isEmpty)
    }

    func testSelectSampleRangesTwoScenes() {
        let scenes = [
            SceneSegment(startTime: 0, endTime: 10),     // 场景0
            SceneSegment(startTime: 10, endTime: 50),    // 场景1
        ]
        let ranges = STTProcessor.selectSampleRanges(scenes: scenes, maxSamples: 3)

        // 只有 1 个内容场景，应返回 1 个采样
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].startTime, 10.0)
    }

    func testSelectSampleRangesManyScenes() {
        // 10 个场景，选 3 个采样
        var scenes: [SceneSegment] = []
        for i in 0..<10 {
            scenes.append(SceneSegment(
                startTime: Double(i * 30),
                endTime: Double((i + 1) * 30)
            ))
        }
        let ranges = STTProcessor.selectSampleRanges(scenes: scenes, maxSamples: 3)

        XCTAssertEqual(ranges.count, 3)
        // 应跳过场景 0，从场景 1+ 均匀选取
        XCTAssertTrue(ranges[0].startTime >= 30.0) // >= 场景 1
    }

    // MARK: - computeLIDScore

    func testComputeLIDScoreEnglishWordCount() {
        // 英语按词计数
        let score = STTProcessor.computeLIDScore(
            text: "Hello world how are you", language: "en"
        )
        XCTAssertEqual(score, 5)
    }

    func testComputeLIDScoreCJKCharCount() {
        // 日语按非空白字符计数
        let ja = STTProcessor.computeLIDScore(
            text: "こんにちは世界", language: "ja"
        )
        XCTAssertEqual(ja, 7)

        // 中文同理
        let zh = STTProcessor.computeLIDScore(
            text: "你好世界", language: "zh"
        )
        XCTAssertEqual(zh, 4)

        // 韩语同理
        let ko = STTProcessor.computeLIDScore(
            text: "안녕하세요", language: "ko"
        )
        XCTAssertEqual(ko, 5)
    }

    func testComputeLIDScoreEmptyReturnsZero() {
        XCTAssertEqual(STTProcessor.computeLIDScore(text: "", language: "en"), 0)
        XCTAssertEqual(STTProcessor.computeLIDScore(text: "   ", language: "ja"), 0)
        XCTAssertEqual(STTProcessor.computeLIDScore(text: "\n\t", language: "zh"), 0)
    }

    func testComputeLIDScoreBalancedCrossLanguage() {
        // 同等语义内容，CJK 字符数 ≈ 英语词数 → 分数可比
        let enScore = STTProcessor.computeLIDScore(
            text: "This week Shibuya exhibition father also exhibits",
            language: "en"
        )
        let jaScore = STTProcessor.computeLIDScore(
            text: "今週もその渋谷の展示会な父さんも出店する",
            language: "ja"
        )
        // 英语 7 词 vs 日语 18 字符 → 日语分数更高
        // 关键：正确语言的转录应产出合理的非零分数
        XCTAssertGreaterThan(enScore, 0)
        XCTAssertGreaterThan(jaScore, 0)
        // 日语正确转录的字符数应 >= 英语词数（CJK 信息密度高）
        XCTAssertGreaterThanOrEqual(jaScore, enScore)
    }

    // MARK: - majorityVote

    func testMajorityVoteClear() {
        let votes: [(language: String, confidence: Float)] = [
            ("ja", -0.1),
            ("ja", -0.2),
            ("en", -0.5),
        ]
        let result = STTProcessor.majorityVote(votes)
        XCTAssertEqual(result?.language, "ja")
    }

    func testMajorityVoteTieBreakByConfidence() {
        // 票数相同时，选置信度更高的
        let votes: [(language: String, confidence: Float)] = [
            ("ja", -0.3),
            ("en", -0.1), // en 置信度更高
        ]
        let result = STTProcessor.majorityVote(votes)
        XCTAssertEqual(result?.language, "en")
    }

    func testMajorityVoteUnanimous() {
        let votes: [(language: String, confidence: Float)] = [
            ("zh", -0.05),
            ("zh", -0.1),
            ("zh", -0.08),
        ]
        let result = STTProcessor.majorityVote(votes)
        XCTAssertEqual(result?.language, "zh")
        XCTAssertEqual(result?.confidence, -0.05) // 最高置信度
    }

    func testMajorityVoteEmpty() {
        let result = STTProcessor.majorityVote([])
        XCTAssertNil(result)
    }

    func testMajorityVoteSingle() {
        let votes: [(language: String, confidence: Float)] = [("ja", -0.2)]
        let result = STTProcessor.majorityVote(votes)
        XCTAssertEqual(result?.language, "ja")
    }

}
