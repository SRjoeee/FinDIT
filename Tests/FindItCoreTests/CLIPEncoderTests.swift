import XCTest
@testable import FindItCore

// MARK: - Mock Encoders for Testing

/// Mock 图片编码器（返回固定向量，不需要模型文件）
final class MockCLIPImageEncoder: CLIPImageEncoder, @unchecked Sendable {
    let name = "mock-image"
    let dimensions = 768
    var callCount = 0
    var lastPath: String?
    var mockEmbedding: [Float]

    init(embedding: [Float]? = nil) {
        self.mockEmbedding = embedding ?? [Float](repeating: 0.036, count: 768)
    }

    func isAvailable() -> Bool { true }

    func encode(imageData: Data) async throws -> [Float] {
        callCount += 1
        return mockEmbedding
    }

    func encode(imagePath: String) async throws -> [Float] {
        callCount += 1
        lastPath = imagePath
        return mockEmbedding
    }
}

/// Mock 文本编码器（返回固定向量，不需要模型文件）
final class MockCLIPTextEncoder: CLIPTextEncoder, @unchecked Sendable {
    let name = "mock-text"
    let dimensions = 768
    var callCount = 0
    var lastText: String?
    var mockEmbedding: [Float]

    init(embedding: [Float]? = nil) {
        self.mockEmbedding = embedding ?? [Float](repeating: 0.036, count: 768)
    }

    func isAvailable() -> Bool { true }

    func encode(text: String) async throws -> [Float] {
        callCount += 1
        lastText = text
        return mockEmbedding
    }
}

// MARK: - SigLIP2Config Tests

final class SigLIP2ConfigTests: XCTestCase {

    func testDefaultConfig() {
        let config = SigLIP2Config.base224
        XCTAssertEqual(config.imageSize, 224)
        XCTAssertEqual(config.imageMean, 0.5)
        XCTAssertEqual(config.imageStd, 0.5)
        XCTAssertEqual(config.maxTextLength, 64)
        XCTAssertEqual(config.embeddingDimension, 768)
        XCTAssertEqual(config.padTokenId, 0)
        XCTAssertEqual(config.eosTokenId, 1)
    }

    func testCustomConfig() {
        let config = SigLIP2Config(
            imageSize: 384,
            embeddingDimension: 1024
        )
        XCTAssertEqual(config.imageSize, 384)
        XCTAssertEqual(config.embeddingDimension, 1024)
        // 其余保持默认
        XCTAssertEqual(config.imageMean, 0.5)
        XCTAssertEqual(config.maxTextLength, 64)
    }
}

// MARK: - CLIPModelManager Tests

final class CLIPModelManagerTests: XCTestCase {

    func testModelDirectory() {
        let dir = CLIPModelManager.modelDirectory
        XCTAssertTrue(dir.contains("FindIt/models/siglip2"))
        XCTAssertTrue(dir.contains("Application Support"))
    }

    func testModelPaths() {
        let modelPath = CLIPModelManager.path(for: .combinedModel)
        XCTAssertTrue(modelPath.hasSuffix("model_fp16.onnx"))

        let tokenizerPath = CLIPModelManager.path(for: .tokenizer)
        XCTAssertTrue(tokenizerPath.hasSuffix("tokenizer.model"))
    }

    func testMissingModels() {
        // 在 CI 环境通常没有模型文件
        let missing = CLIPModelManager.missingModels()
        // 只验证返回的是 ModelFile 类型
        for m in missing {
            XCTAssertTrue(CLIPModelManager.ModelFile.allCases.contains(m))
        }
    }

    func testModelStatus() {
        let status = CLIPModelManager.modelStatus()
        XCTAssertEqual(status.count, CLIPModelManager.ModelFile.allCases.count)
        for info in status {
            XCTAssertFalse(info.file.isEmpty)
            XCTAssertFalse(info.path.isEmpty)
            // exists 可能为 true 或 false
        }
    }
}

// MARK: - Image Preprocessing Tests

final class SigLIP2ImageEncoderTests: XCTestCase {

    /// 测试 CGImage → CHW 张量预处理
    func testPreprocessCGImage() throws {
        let encoder = SigLIP2ImageEncoder(modelPath: "/nonexistent")

        // 创建一个 2x2 测试图片 (RGBA)
        let width = 2
        let height = 2
        var pixels: [UInt8] = [
            255, 0, 0, 255,    // Red
            0, 255, 0, 255,    // Green
            0, 0, 255, 255,    // Blue
            128, 128, 128, 255 // Gray
        ]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let cgImage = context.makeImage() else {
            XCTFail("Cannot create test image")
            return
        }

        let result = try encoder.preprocessCGImage(cgImage)

        // 输出应是 [3, 224, 224] = 150528 floats
        XCTAssertEqual(result.count, 3 * 224 * 224)

        // 值域应在 [-1, 1]
        let minVal = result.min()!
        let maxVal = result.max()!
        XCTAssertGreaterThanOrEqual(minVal, -1.0)
        XCTAssertLessThanOrEqual(maxVal, 1.0)
    }

    /// 测试纯黑图片归一化
    func testPreprocessBlackImage() throws {
        let encoder = SigLIP2ImageEncoder(modelPath: "/nonexistent")

        let size = 4
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        // 设置 alpha
        for i in stride(from: 3, to: pixels.count, by: 4) {
            pixels[i] = 255
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let cgImage = context.makeImage() else {
            XCTFail("Cannot create test image")
            return
        }

        let result = try encoder.preprocessCGImage(cgImage)

        // 纯黑: (0/255 - 0.5) / 0.5 = -1.0
        // 由于 resize 到 224×224 可能有插值，但所有像素都是黑色，所以结果应接近 -1
        let avg = result.reduce(0, +) / Float(result.count)
        XCTAssertEqual(avg, -1.0, accuracy: 0.01)
    }

    /// 测试纯白图片归一化
    func testPreprocessWhiteImage() throws {
        let encoder = SigLIP2ImageEncoder(modelPath: "/nonexistent")

        let size = 4
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let cgImage = context.makeImage() else {
            XCTFail("Cannot create test image")
            return
        }

        let result = try encoder.preprocessCGImage(cgImage)

        // 纯白: (255/255 - 0.5) / 0.5 = 1.0
        let avg = result.reduce(0, +) / Float(result.count)
        XCTAssertEqual(avg, 1.0, accuracy: 0.01)
    }

    func testIsAvailableWhenModelMissing() {
        let encoder = SigLIP2ImageEncoder(modelPath: "/nonexistent/model.onnx")
        XCTAssertFalse(encoder.isAvailable())
    }

    func testEncoderProperties() {
        let encoder = SigLIP2ImageEncoder()
        XCTAssertEqual(encoder.name, "siglip2-base")
        XCTAssertEqual(encoder.dimensions, 768)
    }
}

// MARK: - Text Encoder Tests

final class SigLIP2TextEncoderTests: XCTestCase {

    func testIsAvailableWhenModelMissing() {
        let encoder = SigLIP2TextEncoder(modelPath: "/nonexistent/model.onnx")
        XCTAssertFalse(encoder.isAvailable())
    }

    func testEncoderProperties() {
        let encoder = SigLIP2TextEncoder()
        XCTAssertEqual(encoder.name, "siglip2-base")
        XCTAssertEqual(encoder.dimensions, 768)
    }

    /// 测试 tokenize 逻辑（需要 tokenizer.model 文件）
    func testTokenizeWithRealTokenizer() throws {
        let tokenizerPath = "/tmp/siglip2-spike/models/tokenizer.model"
        guard FileManager.default.fileExists(atPath: tokenizerPath) else {
            // 跳过：tokenizer 文件不存在
            throw XCTSkip("Tokenizer model not available at \(tokenizerPath)")
        }

        let encoder = SigLIP2TextEncoder(
            modelPath: "/nonexistent",
            tokenizerPath: tokenizerPath
        )

        // 英文测试
        let (ids, mask) = try encoder.tokenize("a photo of a beach")
        XCTAssertEqual(ids.count, 64, "应 pad 到 64 tokens")
        XCTAssertEqual(mask.count, 64)
        let realTokenCount = mask.filter { $0 == 1 }.count
        XCTAssertGreaterThan(realTokenCount, 1, "应有多个 token")
        XCTAssertEqual(ids.last { mask[ids.firstIndex(of: $0)!] == 1 },
                       SigLIP2Config.base224.eosTokenId,
                       "最后一个 real token 应为 EOS")

        // 中文测试
        let (zhIds, zhMask) = try encoder.tokenize("海滩日落")
        let zhRealCount = zhMask.filter { $0 == 1 }.count
        XCTAssertGreaterThan(zhRealCount, 1, "中文应有多个 token")

        // Padding 验证: pad token = 0
        let padStart = zhRealCount
        for i in padStart..<64 {
            XCTAssertEqual(zhIds[i], 0, "Padding 位应为 0")
            XCTAssertEqual(zhMask[i], 0, "Padding mask 应为 0")
        }
    }

    /// 测试小写化
    func testTokenizeLowercasing() throws {
        let tokenizerPath = "/tmp/siglip2-spike/models/tokenizer.model"
        guard FileManager.default.fileExists(atPath: tokenizerPath) else {
            throw XCTSkip("Tokenizer model not available")
        }

        let encoder = SigLIP2TextEncoder(
            modelPath: "/nonexistent",
            tokenizerPath: tokenizerPath
        )

        let (ids1, _) = try encoder.tokenize("Beach Sunset")
        let (ids2, _) = try encoder.tokenize("beach sunset")
        // 小写化后应产生相同 token
        XCTAssertEqual(ids1, ids2)
    }

    /// 测试截断超长文本
    func testTokenizeTruncation() throws {
        let tokenizerPath = "/tmp/siglip2-spike/models/tokenizer.model"
        guard FileManager.default.fileExists(atPath: tokenizerPath) else {
            throw XCTSkip("Tokenizer model not available")
        }

        let encoder = SigLIP2TextEncoder(
            modelPath: "/nonexistent",
            tokenizerPath: tokenizerPath
        )

        // 超长文本（应截断到 64 tokens）
        let longText = String(repeating: "the quick brown fox jumps ", count: 50)
        let (ids, mask) = try encoder.tokenize(longText)
        XCTAssertEqual(ids.count, 64)
        XCTAssertEqual(mask.count, 64)
        // 所有位都应该是 real token（截断后无 padding）
        let realCount = mask.filter { $0 == 1 }.count
        XCTAssertEqual(realCount, 64, "超长文本截断后应全部填满")
        // EOS 应始终是最后一个 real token（不被截断丢失）
        let eosId = SigLIP2Config.base224.eosTokenId
        XCTAssertEqual(ids[63], eosId, "超长文本截断后最后一个 token 应为 EOS")
    }
}

// MARK: - CLIPEmbeddingProvider Tests

final class CLIPEmbeddingProviderTests: XCTestCase {

    func testProviderProperties() async {
        let provider = CLIPEmbeddingProvider()
        let name = await provider.name
        XCTAssertEqual(name, "siglip2-clip")
        let dims = await provider.dimensions
        XCTAssertEqual(dims, 768)
    }

    func testProviderWithMockEncoders() async throws {
        let mockImg = MockCLIPImageEncoder()
        let mockTxt = MockCLIPTextEncoder()
        let provider = CLIPEmbeddingProvider(
            imageEncoder: mockImg,
            textEncoder: mockTxt
        )

        let available = await provider.isAvailable
        XCTAssertTrue(available)
        let imgAvail = await provider.isImageEncoderAvailable
        XCTAssertTrue(imgAvail)
        let txtAvail = await provider.isTextEncoderAvailable
        XCTAssertTrue(txtAvail)

        // Image encoding
        let imgEmb = try await provider.encodeImage(path: "/test/image.jpg")
        XCTAssertEqual(imgEmb.count, 768)
        XCTAssertEqual(mockImg.callCount, 1)
        XCTAssertEqual(mockImg.lastPath, "/test/image.jpg")

        // Text encoding
        let txtEmb = try await provider.encodeText("beach sunset")
        XCTAssertEqual(txtEmb.count, 768)
        XCTAssertEqual(mockTxt.callCount, 1)
    }

    func testTextCaching() async throws {
        let mockTxt = MockCLIPTextEncoder()
        let provider = CLIPEmbeddingProvider(
            imageEncoder: MockCLIPImageEncoder(),
            textEncoder: mockTxt,
            cacheCapacity: 10
        )

        // 首次调用
        let emb1 = try await provider.encodeText("beach")
        XCTAssertEqual(mockTxt.callCount, 1)
        let stats1 = await provider.cacheStats
        XCTAssertEqual(stats1.misses, 1)
        XCTAssertEqual(stats1.hits, 0)

        // 缓存命中
        let emb2 = try await provider.encodeText("beach")
        XCTAssertEqual(mockTxt.callCount, 1, "缓存命中不应调用 encoder")
        XCTAssertEqual(emb1, emb2)
        let stats2 = await provider.cacheStats
        XCTAssertEqual(stats2.hits, 1)

        // 大小写不影响缓存（小写化）
        let _ = try await provider.encodeText("BEACH")
        XCTAssertEqual(mockTxt.callCount, 1, "大小写归一后应命中缓存")
    }

    func testCacheEviction() async throws {
        let provider = CLIPEmbeddingProvider(
            imageEncoder: MockCLIPImageEncoder(),
            textEncoder: MockCLIPTextEncoder(),
            cacheCapacity: 3
        )

        // 填满缓存
        let _ = try await provider.encodeText("a")
        let _ = try await provider.encodeText("b")
        let _ = try await provider.encodeText("c")
        // 超出容量 → 驱逐 "a"
        let _ = try await provider.encodeText("d")
        // "a" 应该被驱逐（cache miss）
        let _ = try await provider.encodeText("a")

        let stats = await provider.cacheStats
        // 5 次 encode，第 5 次 "a" 应 miss（被驱逐）
        XCTAssertEqual(stats.misses, 5, "被驱逐的 key 应 miss")
    }

    func testClearCache() async throws {
        let mockTxt = MockCLIPTextEncoder()
        let provider = CLIPEmbeddingProvider(
            imageEncoder: MockCLIPImageEncoder(),
            textEncoder: mockTxt
        )

        let _ = try await provider.encodeText("test")
        XCTAssertEqual(mockTxt.callCount, 1)

        await provider.clearCache()

        let _ = try await provider.encodeText("test")
        XCTAssertEqual(mockTxt.callCount, 2, "清空缓存后应重新调用 encoder")
    }

    func testBatchEncoding() async throws {
        let mockImg = MockCLIPImageEncoder()
        let provider = CLIPEmbeddingProvider(
            imageEncoder: mockImg,
            textEncoder: MockCLIPTextEncoder()
        )

        let paths = ["/a.jpg", "/b.jpg", "/c.jpg"]
        let results = try await provider.encodeImages(paths: paths)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(mockImg.callCount, 3)
    }
}

// MARK: - LRU Cache Tests

final class LRUCacheTests: XCTestCase {

    func testBasicGetPut() {
        var cache = LRUCache<String, Int>(capacity: 3)
        cache.put("a", value: 1)
        cache.put("b", value: 2)

        XCTAssertEqual(cache.get("a"), 1)
        XCTAssertEqual(cache.get("b"), 2)
        XCTAssertNil(cache.get("c"))
    }

    func testEviction() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.put("a", value: 1)
        cache.put("b", value: 2)
        cache.put("c", value: 3) // 驱逐 "a"

        XCTAssertNil(cache.get("a"), "a 应被驱逐")
        XCTAssertEqual(cache.get("b"), 2)
        XCTAssertEqual(cache.get("c"), 3)
    }

    func testLRUOrder() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.put("a", value: 1)
        cache.put("b", value: 2)
        let _ = cache.get("a") // 访问 "a"，使其成为最近使用
        cache.put("c", value: 3) // 驱逐 "b"（最久未使用）

        XCTAssertEqual(cache.get("a"), 1, "a 最近访问过，不应被驱逐")
        XCTAssertNil(cache.get("b"), "b 应被驱逐")
        XCTAssertEqual(cache.get("c"), 3)
    }

    func testUpdate() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.put("a", value: 1)
        cache.put("a", value: 10)

        XCTAssertEqual(cache.get("a"), 10)
        XCTAssertEqual(cache.count, 1, "更新不应增加计数")
    }

    func testClear() {
        var cache = LRUCache<String, Int>(capacity: 5)
        cache.put("a", value: 1)
        cache.put("b", value: 2)
        cache.clear()

        // clear 重置统计
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.hits, 0)
        XCTAssertEqual(cache.misses, 0)

        // 清空后 get 应 miss
        XCTAssertNil(cache.get("a"))
        XCTAssertEqual(cache.misses, 1)
    }

    func testHitMissStats() {
        var cache = LRUCache<String, Int>(capacity: 5)
        cache.put("a", value: 1)

        let _ = cache.get("a")   // hit
        let _ = cache.get("b")   // miss
        let _ = cache.get("a")   // hit
        let _ = cache.get("c")   // miss

        XCTAssertEqual(cache.hits, 2)
        XCTAssertEqual(cache.misses, 2)
    }

    func testMinCapacity() {
        var cache = LRUCache<String, Int>(capacity: 0) // 应被 clamp 到 1
        cache.put("a", value: 1)
        cache.put("b", value: 2)
        // 容量 1 → "a" 被驱逐
        XCTAssertNil(cache.get("a"))
        XCTAssertEqual(cache.get("b"), 2)
    }
}

// MARK: - CLIP Error Tests

final class CLIPErrorTests: XCTestCase {

    func testErrorDescriptions() {
        let errors: [CLIPError] = [
            .modelNotFound(path: "/test/model.onnx"),
            .tokenizerFailed(detail: "corrupted"),
            .imageProcessingFailed(detail: "invalid format"),
            .inferenceFailed(detail: "runtime error"),
            .dimensionMismatch(expected: 768, got: 512),
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "每个 error 应有描述")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }
}

// MARK: - Integration Tests (需要模型文件)

final class CLIPIntegrationTests: XCTestCase {

    /// 需要合并模型和 tokenizer 才能运行
    private var modelsAvailable: Bool {
        let modelPath = "/tmp/siglip2-spike/models/model_fp16.onnx"
        let tokenizerPath = "/tmp/siglip2-spike/models/tokenizer.model"
        return FileManager.default.fileExists(atPath: modelPath)
            && FileManager.default.fileExists(atPath: tokenizerPath)
    }

    /// 端到端: 图片编码 → 768 维向量
    func testImageEncodingEndToEnd() async throws {
        guard modelsAvailable else {
            throw XCTSkip("SigLIP2 models not available at /tmp/siglip2-spike/models/")
        }

        let encoder = SigLIP2ImageEncoder(
            modelPath: "/tmp/siglip2-spike/models/model_fp16.onnx"
        )

        // 创建测试图片
        let testImagePath = "/tmp/clip_test_image.png"
        try createTestImage(at: testImagePath, size: 64)
        defer { try? FileManager.default.removeItem(atPath: testImagePath) }

        let start = CFAbsoluteTimeGetCurrent()
        let embedding = try await encoder.encode(imagePath: testImagePath)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        XCTAssertEqual(embedding.count, 768, "应输出 768 维向量")
        print("[CLIPIntegration] Image encoding: \(String(format: "%.0f", elapsed))ms")

        // L2 范数应接近 1（已归一化）
        let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 0.01, "应 L2 归一化")

        // 性能验收: < 200ms
        XCTAssertLessThan(elapsed, 500, "首次编码应在 500ms 内（含模型加载）")
    }

    /// 端到端: 文本编码 → 768 维向量
    func testTextEncodingEndToEnd() async throws {
        guard modelsAvailable else {
            throw XCTSkip("SigLIP2 models not available")
        }

        let encoder = SigLIP2TextEncoder(
            modelPath: "/tmp/siglip2-spike/models/model_fp16.onnx",
            tokenizerPath: "/tmp/siglip2-spike/models/tokenizer.model"
        )

        let start = CFAbsoluteTimeGetCurrent()
        let embedding = try await encoder.encode(text: "a photo of a beach at sunset")
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        XCTAssertEqual(embedding.count, 768)
        print("[CLIPIntegration] Text encoding: \(String(format: "%.0f", elapsed))ms")

        let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 0.01)
    }

    /// 端到端: 中英文跨模态匹配
    func testCrossModalSimilarity() async throws {
        guard modelsAvailable else {
            throw XCTSkip("SigLIP2 models not available")
        }

        // 使用 spike 的测试图片（macOS 壁纸缩略图）
        let testImgDir = "/tmp/siglip2-spike/test_images"
        let beachPath = "\(testImgDir)/The Beach.png"
        let desertPath = "\(testImgDir)/The Desert.png"
        guard FileManager.default.fileExists(atPath: beachPath),
              FileManager.default.fileExists(atPath: desertPath) else {
            throw XCTSkip("Test images not available at \(testImgDir)")
        }

        let provider = CLIPEmbeddingProvider(
            imageEncoder: SigLIP2ImageEncoder(
                modelPath: "/tmp/siglip2-spike/models/model_fp16.onnx"
            ),
            textEncoder: SigLIP2TextEncoder(
                modelPath: "/tmp/siglip2-spike/models/model_fp16.onnx",
                tokenizerPath: "/tmp/siglip2-spike/models/tokenizer.model"
            )
        )

        // 编码图片
        let beachEmb = try await provider.encodeImage(path: beachPath)
        let desertEmb = try await provider.encodeImage(path: desertPath)

        // 编码文本
        let beachTextEmb = try await provider.encodeText("a sandy beach with ocean waves")
        let desertTextEmb = try await provider.encodeText("desert sand dunes dry landscape")

        // 中文
        let zhBeachEmb = try await provider.encodeText("沙滩海浪海洋")
        let _ = try await provider.encodeText("沙漠干旱荒野")

        // 验证匹配: beach text ↔ beach image 应高于 beach text ↔ desert image
        let beachMatch = cosineSimilarity(beachTextEmb, beachEmb)
        let beachMismatch = cosineSimilarity(beachTextEmb, desertEmb)
        XCTAssertGreaterThan(beachMatch, beachMismatch,
            "Beach text 应与 beach image 更相似")

        let desertMatch = cosineSimilarity(desertTextEmb, desertEmb)
        let desertMismatch = cosineSimilarity(desertTextEmb, beachEmb)
        XCTAssertGreaterThan(desertMatch, desertMismatch,
            "Desert text 应与 desert image 更相似")

        // 中文同样验证
        let zhBeachMatch = cosineSimilarity(zhBeachEmb, beachEmb)
        let zhBeachMismatch = cosineSimilarity(zhBeachEmb, desertEmb)
        XCTAssertGreaterThan(zhBeachMatch, zhBeachMismatch,
            "中文 beach 查询应与 beach image 更相似")

        print("[CLIPIntegration] Cross-modal similarities:")
        print("  EN beach↔beach:  \(String(format: "%.4f", beachMatch))")
        print("  EN beach↔desert: \(String(format: "%.4f", beachMismatch))")
        print("  EN desert↔desert: \(String(format: "%.4f", desertMatch))")
        print("  ZH beach↔beach:  \(String(format: "%.4f", zhBeachMatch))")
        print("  ZH beach↔desert: \(String(format: "%.4f", zhBeachMismatch))")
    }

    // MARK: - Helpers

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    private func createTestImage(at path: String, size: Int) throws {
        var pixelData = [UInt8](repeating: 0, count: size * size * 4)
        // 创建简单渐变
        for y in 0..<size {
            for x in 0..<size {
                let idx = (y * size + x) * 4
                pixelData[idx] = UInt8(x * 255 / max(1, size - 1))
                pixelData[idx + 1] = UInt8(y * 255 / max(1, size - 1))
                pixelData[idx + 2] = 128
                pixelData[idx + 3] = 255
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = context.makeImage() else {
            throw CLIPError.imageProcessingFailed(detail: "Cannot create test image")
        }

        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ) else {
            throw CLIPError.imageProcessingFailed(detail: "Cannot create image destination")
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw CLIPError.imageProcessingFailed(detail: "Cannot finalize image")
        }
    }
}
