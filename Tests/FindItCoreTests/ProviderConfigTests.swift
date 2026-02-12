import XCTest
@testable import FindItCore

final class ProviderConfigTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        // 每个测试后清理 UserDefaults
        ProviderConfig.resetToDefault()
    }

    // MARK: - 默认值

    func testDefaultValues() {
        let config = ProviderConfig.default
        XCTAssertEqual(config.visionModel, "gemini-2.5-flash")
        XCTAssertEqual(config.visionMaxImages, 10)
        XCTAssertEqual(config.visionTimeout, 60.0)
        XCTAssertEqual(config.visionMaxRetries, 3)
        XCTAssertEqual(config.embeddingModel, "gemini-embedding-001")
        XCTAssertEqual(config.embeddingDimensions, 768)
        XCTAssertEqual(config.rateLimitRPM, 9)
    }

    // MARK: - 持久化

    func testSaveAndLoad() {
        var config = ProviderConfig.default
        config.visionModel = "gemini-3.0-flash"
        config.embeddingDimensions = 512
        config.rateLimitRPM = 5

        config.save()

        let loaded = ProviderConfig.load()
        XCTAssertEqual(loaded.visionModel, "gemini-3.0-flash")
        XCTAssertEqual(loaded.embeddingDimensions, 512)
        XCTAssertEqual(loaded.rateLimitRPM, 5)
        // 其他字段保持默认
        XCTAssertEqual(loaded.visionMaxImages, 10)
    }

    func testLoadWithoutSaveReturnsDefault() {
        ProviderConfig.resetToDefault()
        let loaded = ProviderConfig.load()
        XCTAssertEqual(loaded, ProviderConfig.default)
    }

    func testResetToDefault() {
        var config = ProviderConfig.default
        config.visionModel = "custom-model"
        config.save()

        ProviderConfig.resetToDefault()
        let loaded = ProviderConfig.load()
        XCTAssertEqual(loaded, ProviderConfig.default)
    }

    // MARK: - 便捷转换

    func testToVisionConfig() {
        let config = ProviderConfig(
            visionModel: "test-model",
            visionMaxImages: 5,
            visionTimeout: 30.0,
            visionMaxRetries: 1
        )
        let visionConfig = config.toVisionConfig()
        XCTAssertEqual(visionConfig.model, "test-model")
        XCTAssertEqual(visionConfig.maxImagesPerRequest, 5)
        XCTAssertEqual(visionConfig.requestTimeoutSeconds, 30.0)
        XCTAssertEqual(visionConfig.maxRetries, 1)
    }

    func testToEmbeddingConfig() {
        let config = ProviderConfig(
            embeddingModel: "custom-embedding",
            embeddingDimensions: 512
        )
        let embeddingConfig = config.toEmbeddingConfig()
        XCTAssertEqual(embeddingConfig.model, "custom-embedding")
        XCTAssertEqual(embeddingConfig.outputDimensionality, 512)
    }

    func testToRateLimiterConfig() {
        let config = ProviderConfig(rateLimitRPM: 5)
        let rlConfig = config.toRateLimiterConfig()
        XCTAssertEqual(rlConfig.maxRequestsPerWindow, 5)
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let original = ProviderConfig(
            visionModel: "gemini-2.5-flash-lite",
            visionMaxImages: 8,
            visionTimeout: 45.0,
            visionMaxRetries: 2,
            embeddingModel: "text-embedding-005",
            embeddingDimensions: 1024,
            rateLimitRPM: 15
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Equatable

    func testEquatable() {
        let a = ProviderConfig.default
        let b = ProviderConfig.default
        XCTAssertEqual(a, b)

        var c = ProviderConfig.default
        c.visionModel = "different"
        XCTAssertNotEqual(a, c)
    }

    // MARK: - APIProvider

    func testDefaultProviderIsGemini() {
        let config = ProviderConfig.default
        XCTAssertEqual(config.provider, .gemini)
        XCTAssertNil(config.baseURL)
    }

    func testProviderDisplayNames() {
        XCTAssertEqual(APIProvider.gemini.displayName, "Google Gemini")
        XCTAssertEqual(APIProvider.openRouter.displayName, "OpenRouter")
    }

    func testProviderDefaultBaseURLs() {
        XCTAssertTrue(APIProvider.gemini.defaultBaseURL.contains("googleapis.com"))
        XCTAssertTrue(APIProvider.openRouter.defaultBaseURL.contains("openrouter.ai"))
    }

    func testProviderAuthHeaders() {
        XCTAssertEqual(APIProvider.gemini.authHeaderName, "x-goog-api-key")
        XCTAssertEqual(APIProvider.openRouter.authHeaderName, "Authorization")

        XCTAssertEqual(APIProvider.gemini.authHeaderValue(apiKey: "key123"), "key123")
        XCTAssertEqual(APIProvider.openRouter.authHeaderValue(apiKey: "key123"), "Bearer key123")
    }

    func testProviderKeyFilePaths() {
        XCTAssertTrue(APIProvider.gemini.keyFilePath.hasSuffix("gemini-api-key.txt"))
        XCTAssertTrue(APIProvider.openRouter.keyFilePath.hasSuffix("openrouter-api-key.txt"))
    }

    func testProviderEnvVarNames() {
        XCTAssertEqual(APIProvider.gemini.envVarName, "GEMINI_API_KEY")
        XCTAssertEqual(APIProvider.openRouter.envVarName, "OPENROUTER_API_KEY")
    }

    func testEffectiveBaseURLUsesDefault() {
        let config = ProviderConfig(provider: .openRouter)
        XCTAssertEqual(config.effectiveBaseURL, APIProvider.openRouter.defaultBaseURL)
    }

    func testEffectiveBaseURLUsesCustom() {
        let config = ProviderConfig(provider: .gemini, baseURL: "https://custom.api.com/v1")
        XCTAssertEqual(config.effectiveBaseURL, "https://custom.api.com/v1")
    }

    func testCodableWithProvider() throws {
        let original = ProviderConfig(
            provider: .openRouter,
            baseURL: "https://custom.api.com",
            visionModel: "qwen-vl",
            embeddingModel: "text-embedding-3-small"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: data)
        XCTAssertEqual(decoded.provider, .openRouter)
        XCTAssertEqual(decoded.baseURL, "https://custom.api.com")
        XCTAssertEqual(decoded.visionModel, "qwen-vl")
    }

    func testToVisionConfigPassesProvider() {
        let config = ProviderConfig(provider: .openRouter)
        let visionConfig = config.toVisionConfig()
        XCTAssertEqual(visionConfig.provider, .openRouter)
        XCTAssertEqual(visionConfig.baseURL, APIProvider.openRouter.defaultBaseURL)
    }

    func testToEmbeddingConfigPassesProvider() {
        let config = ProviderConfig(provider: .openRouter)
        let embConfig = config.toEmbeddingConfig()
        XCTAssertEqual(embConfig.provider, .openRouter)
        XCTAssertEqual(embConfig.baseURL, APIProvider.openRouter.defaultBaseURL)
    }

    func testSaveAndLoadWithProvider() {
        var config = ProviderConfig(provider: .openRouter, baseURL: "https://custom.url")
        config.save()

        let loaded = ProviderConfig.load()
        XCTAssertEqual(loaded.provider, .openRouter)
        XCTAssertEqual(loaded.baseURL, "https://custom.url")
    }

    func testAllCases() {
        XCTAssertEqual(APIProvider.allCases.count, 2)
        XCTAssertTrue(APIProvider.allCases.contains(.gemini))
        XCTAssertTrue(APIProvider.allCases.contains(.openRouter))
    }
}
