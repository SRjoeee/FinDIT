import XCTest
@testable import FindItCore

final class EmbeddingUtilsTests: XCTestCase {

    // MARK: - composeClipText

    func testComposeClipTextAllFields() {
        let clip = Clip(
            startTime: 0.0,
            endTime: 10.0,
            scene: "海边日落",
            subjects: "女生",
            actions: "散步",
            objects: "帽子",
            mood: "浪漫",
            shotType: "全景",
            lighting: "暖光",
            colors: "金色",
            clipDescription: "一个女生在海边散步，夕阳映照着海面",
            tags: "[\"海滩\",\"日落\"]",
            transcript: "今天的日落真美"
        )
        let text = EmbeddingUtils.composeClipText(clip: clip)
        XCTAssertTrue(text.contains("海边日落"))
        XCTAssertTrue(text.contains("一个女生在海边散步"))
        XCTAssertTrue(text.contains("女生"))
        XCTAssertTrue(text.contains("散步"))
        XCTAssertTrue(text.contains("帽子"))
        XCTAssertTrue(text.contains("浪漫"))
        XCTAssertTrue(text.contains("全景"))
        XCTAssertTrue(text.contains("今天的日落真美"))
        XCTAssertTrue(text.contains("海滩"))
        XCTAssertTrue(text.contains("日落"))
    }

    func testComposeClipTextEmptyFields() {
        let clip = Clip(startTime: 0.0, endTime: 10.0)
        let text = EmbeddingUtils.composeClipText(clip: clip)
        XCTAssertTrue(text.isEmpty)
    }

    func testComposeClipTextOnlyTranscript() {
        let clip = Clip(
            startTime: 0.0,
            endTime: 5.0,
            transcript: "这是一段台词"
        )
        let text = EmbeddingUtils.composeClipText(clip: clip)
        XCTAssertEqual(text, "这是一段台词")
    }

    func testComposeClipTextOnlySceneAndDescription() {
        let clip = Clip(
            startTime: 0.0,
            endTime: 5.0,
            scene: "室内办公室",
            clipDescription: "一间现代化的办公室"
        )
        let text = EmbeddingUtils.composeClipText(clip: clip)
        XCTAssertTrue(text.contains("室内办公室"))
        XCTAssertTrue(text.contains("一间现代化的办公室"))
    }

    func testComposeClipTextWithTags() {
        var clip = Clip(startTime: 0.0, endTime: 5.0, scene: "森林")
        clip.setTags(["户外", "自然", "绿色"])
        let text = EmbeddingUtils.composeClipText(clip: clip)
        XCTAssertTrue(text.contains("森林"))
        XCTAssertTrue(text.contains("户外 自然 绿色"))
    }

    // MARK: - cosineSimilarity

    func testCosineSimilarityIdentical() {
        let v = [Float](repeating: 1.0, count: 10)
        let sim = EmbeddingUtils.cosineSimilarity(v, v)
        XCTAssertEqual(sim, 1.0, accuracy: 1e-5)
    }

    func testCosineSimilarityOrthogonal() {
        let a: [Float] = [1.0, 0.0, 0.0]
        let b: [Float] = [0.0, 1.0, 0.0]
        let sim = EmbeddingUtils.cosineSimilarity(a, b)
        XCTAssertEqual(sim, 0.0, accuracy: 1e-5)
    }

    func testCosineSimilarityOpposite() {
        let a: [Float] = [1.0, 2.0, 3.0]
        let b: [Float] = [-1.0, -2.0, -3.0]
        let sim = EmbeddingUtils.cosineSimilarity(a, b)
        XCTAssertEqual(sim, -1.0, accuracy: 1e-5)
    }

    func testCosineSimilarityZeroVector() {
        let a: [Float] = [0.0, 0.0, 0.0]
        let b: [Float] = [1.0, 2.0, 3.0]
        let sim = EmbeddingUtils.cosineSimilarity(a, b)
        XCTAssertEqual(sim, 0.0)
    }

    func testCosineSimilarityEmpty() {
        let sim = EmbeddingUtils.cosineSimilarity([], [])
        XCTAssertEqual(sim, 0.0)
    }

    func testCosineSimilarityDifferentLength() {
        let a: [Float] = [1.0, 2.0]
        let b: [Float] = [1.0, 2.0, 3.0]
        let sim = EmbeddingUtils.cosineSimilarity(a, b)
        XCTAssertEqual(sim, 0.0, "长度不同应返回 0")
    }

    func testCosineSimilaritySimilarVectors() {
        // 两个相似但不完全相同的向量
        let a: [Float] = [1.0, 2.0, 3.0]
        let b: [Float] = [1.1, 2.1, 3.1]
        let sim = EmbeddingUtils.cosineSimilarity(a, b)
        XCTAssertGreaterThan(sim, 0.99, "非常相似的向量应接近 1.0")
    }

    // MARK: - serializeEmbedding / deserializeEmbedding

    func testSerializeDeserializeRoundtrip() {
        let original: [Float] = [0.1, 0.2, 0.3, -0.5, 1.0]
        let data = EmbeddingUtils.serializeEmbedding(original)
        let restored = EmbeddingUtils.deserializeEmbedding(data)
        XCTAssertEqual(original, restored)
    }

    func testSerializeDeserializeEmpty() {
        let original: [Float] = []
        let data = EmbeddingUtils.serializeEmbedding(original)
        let restored = EmbeddingUtils.deserializeEmbedding(data)
        XCTAssertEqual(restored, [])
    }

    func testSerializeSize() {
        let vector: [Float] = [1.0, 2.0, 3.0]
        let data = EmbeddingUtils.serializeEmbedding(vector)
        // 3 个 Float × 4 bytes = 12 bytes
        XCTAssertEqual(data.count, 12)
    }

    func testSerializeLargeVector() {
        // 模拟 768 维向量
        let vector = (0..<768).map { Float($0) / 768.0 }
        let data = EmbeddingUtils.serializeEmbedding(vector)
        let restored = EmbeddingUtils.deserializeEmbedding(data)
        XCTAssertEqual(vector.count, restored.count)
        XCTAssertEqual(vector, restored)
    }

    // MARK: - minMaxNormalize

    func testMinMaxNormalizeBasic() {
        let values = [1.0, 2.0, 3.0, 4.0, 5.0]
        let normalized = EmbeddingUtils.minMaxNormalize(values)
        XCTAssertEqual(normalized, [0.0, 0.25, 0.5, 0.75, 1.0])
    }

    func testMinMaxNormalizeSingleValue() {
        let values = [42.0]
        let normalized = EmbeddingUtils.minMaxNormalize(values)
        XCTAssertEqual(normalized, [0.0])
    }

    func testMinMaxNormalizeAllSame() {
        let values = [3.0, 3.0, 3.0]
        let normalized = EmbeddingUtils.minMaxNormalize(values)
        XCTAssertEqual(normalized, [0.0, 0.0, 0.0])
    }

    func testMinMaxNormalizeEmpty() {
        let normalized = EmbeddingUtils.minMaxNormalize([])
        XCTAssertEqual(normalized, [])
    }

    func testMinMaxNormalizeNegativeValues() {
        // FTS5 rank 是负数
        let values = [-5.0, -3.0, -1.0]
        let normalized = EmbeddingUtils.minMaxNormalize(values)
        XCTAssertEqual(normalized[0], 0.0, accuracy: 1e-10)
        XCTAssertEqual(normalized[1], 0.5, accuracy: 1e-10)
        XCTAssertEqual(normalized[2], 1.0, accuracy: 1e-10)
    }

    // MARK: - EmbeddingError

    func testEmbeddingErrorDescriptions() {
        let err1 = EmbeddingError.providerNotAvailable(name: "gemini")
        XCTAssertTrue(err1.localizedDescription.contains("gemini"))

        let err2 = EmbeddingError.dimensionMismatch(expected: 768, got: 512)
        XCTAssertTrue(err2.localizedDescription.contains("768"))
        XCTAssertTrue(err2.localizedDescription.contains("512"))

        let err3 = EmbeddingError.apiError(statusCode: 429, message: "限速")
        XCTAssertTrue(err3.localizedDescription.contains("429"))
    }
}
