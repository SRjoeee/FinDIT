import XCTest
@testable import FindItCore

// MARK: - EmbeddingGemmaConfig Tests

final class EmbeddingGemmaConfigTests: XCTestCase {

    func testDefaultConfig() {
        let config = EmbeddingGemmaConfig.default300M
        XCTAssertEqual(config.embeddingDimension, 768)
        XCTAssertEqual(config.maxSequenceLength, 256)
        XCTAssertEqual(config.padTokenId, 0)
        XCTAssertEqual(config.eosTokenId, 1)
        XCTAssertEqual(config.bosTokenId, 2)
        XCTAssertEqual(config.vocabSize, 256000)
    }

    func testCustomConfig() {
        let config = EmbeddingGemmaConfig(
            embeddingDimension: 1024,
            maxSequenceLength: 512,
            bosTokenId: 5
        )
        XCTAssertEqual(config.embeddingDimension, 1024)
        XCTAssertEqual(config.maxSequenceLength, 512)
        XCTAssertEqual(config.bosTokenId, 5)
        // 其余保持默认
        XCTAssertEqual(config.padTokenId, 0)
        XCTAssertEqual(config.eosTokenId, 1)
        XCTAssertEqual(config.vocabSize, 256000)
    }
}

// MARK: - EmbeddingGemmaModelManager Tests

final class EmbeddingGemmaModelManagerTests: XCTestCase {

    func testModelDirectory() {
        let dir = EmbeddingGemmaModelManager.modelDirectory
        XCTAssertTrue(dir.contains("FindIt/models/embedding-gemma"),
                      "目录应包含 embedding-gemma: \(dir)")
        XCTAssertTrue(dir.contains("Application Support"))
    }

    func testModelPaths() {
        let modelPath = EmbeddingGemmaModelManager.path(for: .model)
        XCTAssertTrue(modelPath.hasSuffix("model_q8.onnx"),
                      "模型路径应以 model_q8.onnx 结尾: \(modelPath)")

        let tokenizerPath = EmbeddingGemmaModelManager.path(for: .tokenizer)
        XCTAssertTrue(tokenizerPath.hasSuffix("tokenizer.model"),
                      "Tokenizer 路径应以 tokenizer.model 结尾: \(tokenizerPath)")
    }

    func testModelFileEnumeration() {
        let allFiles = EmbeddingGemmaModelManager.ModelFile.allCases
        XCTAssertEqual(allFiles.count, 2, "应有 2 个模型文件")
        XCTAssertTrue(allFiles.contains(.model))
        XCTAssertTrue(allFiles.contains(.tokenizer))
    }

    func testMissingModels() {
        // 在 CI 环境通常没有模型文件
        let missing = EmbeddingGemmaModelManager.missingModels()
        for m in missing {
            XCTAssertTrue(EmbeddingGemmaModelManager.ModelFile.allCases.contains(m))
        }
    }

    func testModelStatus() {
        let status = EmbeddingGemmaModelManager.modelStatus()
        XCTAssertEqual(status.count, EmbeddingGemmaModelManager.ModelFile.allCases.count)
        for info in status {
            XCTAssertFalse(info.file.isEmpty)
            XCTAssertFalse(info.path.isEmpty)
        }
    }

    func testAllModelsAvailableWhenMissing() {
        // 除非模型已安装，否则应为 false
        // 这个测试在模型安装时也能通过（返回 true）
        let available = EmbeddingGemmaModelManager.allModelsAvailable()
        let missing = EmbeddingGemmaModelManager.missingModels()
        if missing.isEmpty {
            XCTAssertTrue(available)
        } else {
            XCTAssertFalse(available)
        }
    }
}

// MARK: - EmbeddingGemmaEncoder Tests

final class EmbeddingGemmaEncoderTests: XCTestCase {

    func testEncoderProperties() {
        let encoder = EmbeddingGemmaEncoder()
        XCTAssertEqual(encoder.name, "embedding-gemma")
        XCTAssertEqual(encoder.dimensions, 768)
    }

    func testIsAvailableWhenModelMissing() {
        let encoder = EmbeddingGemmaEncoder(
            modelPath: "/nonexistent/model_q8.onnx",
            tokenizerPath: "/nonexistent/tokenizer.model"
        )
        XCTAssertFalse(encoder.isAvailable())
    }

    func testIsAvailablePartialFiles() {
        // 只有一个文件存在（使用 /tmp 作为存在的路径）
        let encoder = EmbeddingGemmaEncoder(
            modelPath: "/tmp",  // 存在但不是模型
            tokenizerPath: "/nonexistent/tokenizer.model"
        )
        XCTAssertFalse(encoder.isAvailable(), "两个文件都需要存在")
    }

    // MARK: - Tokenization Tests (需要 tokenizer.model)

    /// 获取 EmbeddingGemma tokenizer 路径（如果存在）
    private var gemmaTokenizerPath: String? {
        let standardPath = EmbeddingGemmaModelManager.path(for: .tokenizer)
        if FileManager.default.fileExists(atPath: standardPath) {
            return standardPath
        }
        return nil
    }

    func testTokenizeShortText() throws {
        guard let tokenizerPath = gemmaTokenizerPath else {
            throw XCTSkip("EmbeddingGemma tokenizer not available")
        }

        let encoder = EmbeddingGemmaEncoder(
            modelPath: "/nonexistent",
            tokenizerPath: tokenizerPath
        )

        let (ids, mask) = try encoder.tokenize("hello world")
        let maxLen = EmbeddingGemmaConfig.default300M.maxSequenceLength

        XCTAssertEqual(ids.count, maxLen, "应 pad 到 \(maxLen)")
        XCTAssertEqual(mask.count, maxLen)

        // BOS 应在第一个位置
        XCTAssertEqual(ids[0], EmbeddingGemmaConfig.default300M.bosTokenId,
                       "第一个 token 应为 BOS (id=2)")

        // EOS 应在最后一个 real token 位置
        let realCount = mask.filter { $0 == 1 }.count
        XCTAssertGreaterThan(realCount, 2, "应有 BOS + tokens + EOS")
        XCTAssertEqual(ids[realCount - 1], EmbeddingGemmaConfig.default300M.eosTokenId,
                       "最后一个 real token 应为 EOS (id=1)")

        // Padding 验证
        for i in realCount..<maxLen {
            XCTAssertEqual(ids[i], EmbeddingGemmaConfig.default300M.padTokenId,
                           "Padding 位应为 PAD (id=0)")
            XCTAssertEqual(mask[i], 0, "Padding mask 应为 0")
        }

        // 所有 ID 应 >= 0 (验证 -1 修正没有产生负数)
        for id in ids {
            XCTAssertGreaterThanOrEqual(id, 0, "Token ID 不应为负数")
        }
    }

    func testTokenizeTruncation() throws {
        guard let tokenizerPath = gemmaTokenizerPath else {
            throw XCTSkip("EmbeddingGemma tokenizer not available")
        }

        let encoder = EmbeddingGemmaEncoder(
            modelPath: "/nonexistent",
            tokenizerPath: tokenizerPath
        )

        // 超长文本（应截断到 maxSequenceLength）
        let longText = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 100)
        let (ids, mask) = try encoder.tokenize(longText)
        let maxLen = EmbeddingGemmaConfig.default300M.maxSequenceLength

        XCTAssertEqual(ids.count, maxLen)
        XCTAssertEqual(mask.count, maxLen)

        // 全部填满，无 padding
        let realCount = mask.filter { $0 == 1 }.count
        XCTAssertEqual(realCount, maxLen, "超长文本截断后应全部填满")

        // BOS 在第一个位置
        XCTAssertEqual(ids[0], EmbeddingGemmaConfig.default300M.bosTokenId,
                       "BOS 应保留")

        // EOS 在最后一个位置（不被截断丢失）
        XCTAssertEqual(ids[maxLen - 1], EmbeddingGemmaConfig.default300M.eosTokenId,
                       "超长文本截断后最后一个 token 应为 EOS")
    }

    func testTokenizeEmptyText() throws {
        guard let tokenizerPath = gemmaTokenizerPath else {
            throw XCTSkip("EmbeddingGemma tokenizer not available")
        }

        let encoder = EmbeddingGemmaEncoder(
            modelPath: "/nonexistent",
            tokenizerPath: tokenizerPath
        )

        let (ids, mask) = try encoder.tokenize("")
        let maxLen = EmbeddingGemmaConfig.default300M.maxSequenceLength

        XCTAssertEqual(ids.count, maxLen)
        XCTAssertEqual(mask.count, maxLen)

        // 空文本应至少有 BOS + EOS
        XCTAssertEqual(ids[0], EmbeddingGemmaConfig.default300M.bosTokenId)
        let realCount = mask.filter { $0 == 1 }.count
        XCTAssertGreaterThanOrEqual(realCount, 2, "至少应有 BOS + EOS")
    }

    func testTokenizeLowercasing() throws {
        guard let tokenizerPath = gemmaTokenizerPath else {
            throw XCTSkip("EmbeddingGemma tokenizer not available")
        }

        let encoder = EmbeddingGemmaEncoder(
            modelPath: "/nonexistent",
            tokenizerPath: tokenizerPath
        )

        let (ids1, _) = try encoder.tokenize("Beach Sunset")
        let (ids2, _) = try encoder.tokenize("beach sunset")
        // 小写化后应产生相同 token
        XCTAssertEqual(ids1, ids2)
    }

    func testTokenizeChineseText() throws {
        guard let tokenizerPath = gemmaTokenizerPath else {
            throw XCTSkip("EmbeddingGemma tokenizer not available")
        }

        let encoder = EmbeddingGemmaEncoder(
            modelPath: "/nonexistent",
            tokenizerPath: tokenizerPath
        )

        let (ids, mask) = try encoder.tokenize("海滩日落")
        let realCount = mask.filter { $0 == 1 }.count
        XCTAssertGreaterThan(realCount, 2, "中文应有 BOS + tokens + EOS")

        // BOS 应在第一个位置
        XCTAssertEqual(ids[0], EmbeddingGemmaConfig.default300M.bosTokenId)
    }
}

// MARK: - EmbeddingGemmaProvider Tests

final class EmbeddingGemmaProviderTests: XCTestCase {

    func testProviderProperties() {
        let provider = EmbeddingGemmaProvider()
        XCTAssertEqual(provider.name, "embedding-gemma")
        XCTAssertEqual(provider.dimensions, 768)
    }

    func testIsAvailableWhenModelsNotInstalled() {
        // 使用不存在路径的 encoder
        let encoder = EmbeddingGemmaEncoder(
            modelPath: "/nonexistent/model_q8.onnx",
            tokenizerPath: "/nonexistent/tokenizer.model"
        )
        let provider = EmbeddingGemmaProvider(encoder: encoder)

        // isAvailable 检查 ModelManager 路径而非 encoder 内部路径
        // 如果标准路径下无文件，应返回 false
        let available = provider.isAvailable()
        let modelsExist = EmbeddingGemmaModelManager.allModelsAvailable()
        XCTAssertEqual(available, modelsExist)
    }

    func testEmbedThrowsWhenUnavailable() async throws {
        // 确保标准路径下无模型（CI 环境）
        guard !EmbeddingGemmaModelManager.allModelsAvailable() else {
            throw XCTSkip("EmbeddingGemma models are installed, cannot test unavailable case")
        }

        let provider = EmbeddingGemmaProvider()
        do {
            _ = try await provider.embed(text: "test")
            XCTFail("应在模型不可用时抛出错误")
        } catch is EmbeddingError {
            // 期望抛出 EmbeddingError（providerNotAvailable）
        }
    }
}

// MARK: - Integration Tests (需要模型文件)

final class EmbeddingGemmaIntegrationTests: XCTestCase {

    /// 检查模型文件是否可用
    private var modelsAvailable: Bool {
        EmbeddingGemmaModelManager.allModelsAvailable()
    }

    func testEncodeEndToEnd() async throws {
        guard modelsAvailable else {
            throw XCTSkip("EmbeddingGemma models not installed")
        }

        let encoder = EmbeddingGemmaEncoder()

        let start = CFAbsoluteTimeGetCurrent()
        let embedding = try await encoder.encode(text: "a photo of a beach at sunset")
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        XCTAssertEqual(embedding.count, 768, "应输出 768 维向量")
        print("[EmbeddingGemma] Text encoding: \(String(format: "%.0f", elapsed))ms")

        // L2 范数应接近 1（已归一化）
        let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 0.01, "应 L2 归一化")
    }

    func testSemanticSimilarity() async throws {
        guard modelsAvailable else {
            throw XCTSkip("EmbeddingGemma models not installed")
        }

        let encoder = EmbeddingGemmaEncoder()

        let beachEmb = try await encoder.encode(text: "sandy beach ocean waves sunset")
        let desertEmb = try await encoder.encode(text: "desert sand dunes dry landscape")
        let beach2Emb = try await encoder.encode(text: "tropical beach with blue water")

        // beach1 ↔ beach2 应比 beach1 ↔ desert 更相似
        let beachSimilar = EmbeddingUtils.cosineSimilarity(beachEmb, beach2Emb)
        let beachDesert = EmbeddingUtils.cosineSimilarity(beachEmb, desertEmb)

        XCTAssertGreaterThan(beachSimilar, beachDesert,
            "相似主题的文本应有更高余弦相似度 (beach↔beach=\(beachSimilar), beach↔desert=\(beachDesert))")

        print("[EmbeddingGemma] Similarity: beach↔beach=\(String(format: "%.4f", beachSimilar)), "
              + "beach↔desert=\(String(format: "%.4f", beachDesert))")
    }

    func testChineseEncoding() async throws {
        guard modelsAvailable else {
            throw XCTSkip("EmbeddingGemma models not installed")
        }

        let encoder = EmbeddingGemmaEncoder()
        let embedding = try await encoder.encode(text: "海滩日落美景")

        XCTAssertEqual(embedding.count, 768)
        let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 0.01)
    }

    func testProviderEndToEnd() async throws {
        guard modelsAvailable else {
            throw XCTSkip("EmbeddingGemma models not installed")
        }

        let provider = EmbeddingGemmaProvider()
        XCTAssertTrue(provider.isAvailable())

        let embedding = try await provider.embed(text: "test query")
        XCTAssertEqual(embedding.count, 768)

        let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 0.01)
    }
}
