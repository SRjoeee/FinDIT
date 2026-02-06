import XCTest
@testable import FindItCore

final class GeminiEmbeddingTests: XCTestCase {

    // MARK: - Config

    func testConfigDefaults() {
        let config = GeminiEmbedding.Config.default
        XCTAssertEqual(config.model, "text-embedding-004")
        XCTAssertEqual(config.requestTimeoutSeconds, 30.0)
        XCTAssertEqual(config.maxRetries, 3)
        XCTAssertEqual(config.maxBatchSize, 100)
    }

    func testConfigCustom() {
        let config = GeminiEmbedding.Config(
            model: "custom-model",
            requestTimeoutSeconds: 60.0,
            maxRetries: 5,
            maxBatchSize: 50
        )
        XCTAssertEqual(config.model, "custom-model")
        XCTAssertEqual(config.maxBatchSize, 50)
    }

    // MARK: - Dimensions

    func testDimensions() {
        XCTAssertEqual(GeminiEmbedding.dimensions, 768)
    }

    // MARK: - buildEmbedRequestBody

    func testBuildEmbedRequestBody() throws {
        let data = try GeminiEmbedding.buildEmbedRequestBody(text: "测试文本")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json)
        XCTAssertEqual(json?["model"] as? String, "models/text-embedding-004")

        let content = json?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.first?["text"] as? String, "测试文本")
    }

    func testBuildEmbedRequestBodyCustomModel() throws {
        let config = GeminiEmbedding.Config(model: "my-model")
        let data = try GeminiEmbedding.buildEmbedRequestBody(text: "hello", config: config)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["model"] as? String, "models/my-model")
    }

    // MARK: - buildBatchRequestBody

    func testBuildBatchRequestBody() throws {
        let data = try GeminiEmbedding.buildBatchRequestBody(texts: ["文本A", "文本B"])
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let requests = json?["requests"] as? [[String: Any]]
        XCTAssertEqual(requests?.count, 2)

        let first = requests?.first
        XCTAssertEqual(first?["model"] as? String, "models/text-embedding-004")
    }

    func testBuildBatchRequestBodyEmpty() throws {
        let data = try GeminiEmbedding.buildBatchRequestBody(texts: [])
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let requests = json?["requests"] as? [[String: Any]]
        XCTAssertEqual(requests?.count, 0)
    }

    // MARK: - parseEmbedResponse

    func testParseEmbedResponse() throws {
        let responseJSON: [String: Any] = [
            "embedding": [
                "values": [0.1, 0.2, 0.3, -0.5]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: responseJSON)
        let vector = try GeminiEmbedding.parseEmbedResponse(data)

        XCTAssertEqual(vector.count, 4)
        XCTAssertEqual(vector[0], 0.1, accuracy: 1e-5)
        XCTAssertEqual(vector[3], -0.5, accuracy: 1e-5)
    }

    func testParseEmbedResponseMissingEmbedding() {
        let data = "{}".data(using: .utf8)!
        XCTAssertThrowsError(try GeminiEmbedding.parseEmbedResponse(data)) { error in
            XCTAssertTrue(error is EmbeddingError)
        }
    }

    func testParseEmbedResponseInvalidJSON() {
        let data = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try GeminiEmbedding.parseEmbedResponse(data))
    }

    // MARK: - parseBatchResponse

    func testParseBatchResponse() throws {
        let responseJSON: [String: Any] = [
            "embeddings": [
                ["values": [0.1, 0.2]],
                ["values": [0.3, 0.4]],
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: responseJSON)
        let vectors = try GeminiEmbedding.parseBatchResponse(data)

        XCTAssertEqual(vectors.count, 2)
        XCTAssertEqual(vectors[0], [Float(0.1), Float(0.2)], accuracy: 1e-5)
        XCTAssertEqual(vectors[1], [Float(0.3), Float(0.4)], accuracy: 1e-5)
    }

    func testParseBatchResponseEmpty() throws {
        let responseJSON: [String: Any] = ["embeddings": []]
        let data = try JSONSerialization.data(withJSONObject: responseJSON)
        let vectors = try GeminiEmbedding.parseBatchResponse(data)
        XCTAssertEqual(vectors.count, 0)
    }

    func testParseBatchResponseMissingEmbeddings() {
        let data = "{}".data(using: .utf8)!
        XCTAssertThrowsError(try GeminiEmbedding.parseBatchResponse(data))
    }

    // MARK: - parseErrorResponse

    func testParseErrorResponse429() throws {
        let errorJSON: [String: Any] = [
            "error": [
                "code": 429,
                "message": "Resource has been exhausted",
                "status": "RESOURCE_EXHAUSTED"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: errorJSON)
        let result = GeminiEmbedding.parseErrorResponse(data)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.code, 429)
        XCTAssertTrue(result?.message.contains("exhausted") ?? false)
    }

    func testParseErrorResponseInvalid() {
        let data = "not json".data(using: .utf8)!
        XCTAssertNil(GeminiEmbedding.parseErrorResponse(data))
    }

    // MARK: - shouldRetry

    func testShouldRetry() {
        XCTAssertTrue(GeminiEmbedding.shouldRetry(statusCode: 429))
        XCTAssertTrue(GeminiEmbedding.shouldRetry(statusCode: 503))
        XCTAssertTrue(GeminiEmbedding.shouldRetry(statusCode: 500))
        XCTAssertFalse(GeminiEmbedding.shouldRetry(statusCode: 200))
        XCTAssertFalse(GeminiEmbedding.shouldRetry(statusCode: 400))
        XCTAssertFalse(GeminiEmbedding.shouldRetry(statusCode: 401))
    }

    // MARK: - GeminiEmbeddingProvider

    func testProviderName() {
        let provider = GeminiEmbeddingProvider(apiKey: "AIza_fake_key_12345678901234567")
        XCTAssertEqual(provider.name, "gemini")
    }

    func testProviderDimensions() {
        let provider = GeminiEmbeddingProvider(apiKey: "AIza_fake_key_12345678901234567")
        XCTAssertEqual(provider.dimensions, 768)
    }

    func testProviderIsAvailableValid() {
        let provider = GeminiEmbeddingProvider(apiKey: "AIza_fake_key_12345678901234567")
        XCTAssertTrue(provider.isAvailable())
    }

    func testProviderIsAvailableInvalid() {
        let provider = GeminiEmbeddingProvider(apiKey: "short")
        XCTAssertFalse(provider.isAvailable())
    }
}

// MARK: - Helper

extension Array where Element == Float {
    /// 按 accuracy 比较两个 Float 数组
    func isEqual(to other: [Float], accuracy: Float) -> Bool {
        guard count == other.count else { return false }
        return zip(self, other).allSatisfy { abs($0 - $1) <= accuracy }
    }
}

func XCTAssertEqual(_ a: [Float], _ b: [Float], accuracy: Float, file: StaticString = #file, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, "Array length mismatch", file: file, line: line)
    for (i, (va, vb)) in zip(a, b).enumerated() {
        XCTAssertEqual(va, vb, accuracy: accuracy, "Element \(i) mismatch", file: file, line: line)
    }
}
