import XCTest
import OnnxRuntimeBindings
@testable import FindItCore

// MARK: - 单元测试（不依赖模型文件）

final class ORTSessionHelperTests: XCTestCase {

    func testCoreMLAvailability() {
        // Apple Silicon 上应返回 true
        let available = ORTSessionHelper.isCoreMLAvailable
        #if arch(arm64)
        XCTAssertTrue(available, "Apple Silicon 上 CoreML EP 应可用")
        #else
        // Intel Mac 上可能不可用
        _ = available
        #endif
    }

    func testMakeSessionOptionsNone() throws {
        let options = try ORTSessionHelper.makeSessionOptions(graphOptimizationLevel: .none)
        XCTAssertNotNil(options, "应成功创建 .none 级别的 session options")
    }

    func testMakeSessionOptionsAll() throws {
        let options = try ORTSessionHelper.makeSessionOptions(graphOptimizationLevel: .all)
        XCTAssertNotNil(options, "应成功创建 .all 级别的 session options")
    }

    func testCreateSessionWithMissingModel() {
        XCTAssertThrowsError(
            try ORTSessionHelper.createSession(
                modelPath: "/nonexistent/model.onnx",
                graphOptimizationLevel: .none
            )
        ) { error in
            // ORT 在模型文件不存在时应抛出错误
            XCTAssertFalse("\(error)".isEmpty, "错误描述不应为空")
        }
    }
}

// MARK: - 精度与基准测试（需要模型文件）

final class ORTSessionHelperIntegrationTests: XCTestCase {

    /// 检查 SigLIP2 模型是否已下载
    private var modelAvailable: Bool {
        CLIPModelManager.allModelsAvailable()
    }

    func testImageEncoderPrecisionWithCoreML() async throws {
        try XCTSkipUnless(modelAvailable, "SigLIP2 模型未下载，跳过精度测试")

        let modelPath = CLIPModelManager.path(for: .combinedModel)
        let encoder = SigLIP2ImageEncoder(modelPath: modelPath)
        let imageData = createTestPNGData(width: 224, height: 224)

        // 同一输入编码 2 次
        let vec1 = try await encoder.encode(imageData: imageData)
        let vec2 = try await encoder.encode(imageData: imageData)

        XCTAssertEqual(vec1.count, 768)
        XCTAssertEqual(vec2.count, 768)

        // 确定性: 同输入应产生完全相同的输出
        let similarity = cosineSimilarity(vec1, vec2)
        XCTAssertGreaterThan(similarity, 0.999,
            "同输入重复编码的 cosine similarity 应 > 0.999，实际: \(similarity)")
    }

    func testTextEncoderPrecisionWithCoreML() async throws {
        try XCTSkipUnless(modelAvailable, "SigLIP2 模型未下载，跳过精度测试")

        let modelPath = CLIPModelManager.path(for: .combinedModel)
        let tokenizerPath = CLIPModelManager.path(for: .tokenizer)
        let encoder = SigLIP2TextEncoder(
            modelPath: modelPath,
            tokenizerPath: tokenizerPath
        )

        let text = "a cat sitting on a table"

        // 同一输入编码 2 次
        let vec1 = try await encoder.encode(text: text)
        let vec2 = try await encoder.encode(text: text)

        XCTAssertEqual(vec1.count, 768)
        XCTAssertEqual(vec2.count, 768)

        let similarity = cosineSimilarity(vec1, vec2)
        XCTAssertGreaterThan(similarity, 0.999,
            "同输入重复编码的 cosine similarity 应 > 0.999，实际: \(similarity)")
    }

    func testImageEncoderBenchmark() async throws {
        try XCTSkipUnless(modelAvailable, "SigLIP2 模型未下载，跳过基准测试")

        let modelPath = CLIPModelManager.path(for: .combinedModel)
        let encoder = SigLIP2ImageEncoder(modelPath: modelPath)
        let imageData = createTestPNGData(width: 224, height: 224)

        // 预热
        _ = try await encoder.encode(imageData: imageData)

        // 10 次计时
        var times: [Double] = []
        for _ in 0..<10 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try await encoder.encode(imageData: imageData)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            times.append(elapsed)
        }

        let avg = times.reduce(0, +) / Double(times.count)
        let minT = times.min()!
        let maxT = times.max()!
        print("Image Encoder Benchmark (CoreML EP \(ORTSessionHelper.isCoreMLAvailable ? "ON" : "OFF")):")
        print("   avg: \(String(format: "%.1f", avg))ms, min: \(String(format: "%.1f", minT))ms, max: \(String(format: "%.1f", maxT))ms")
    }

    func testTextEncoderBenchmark() async throws {
        try XCTSkipUnless(modelAvailable, "SigLIP2 模型未下载，跳过基准测试")

        let modelPath = CLIPModelManager.path(for: .combinedModel)
        let tokenizerPath = CLIPModelManager.path(for: .tokenizer)
        let encoder = SigLIP2TextEncoder(
            modelPath: modelPath,
            tokenizerPath: tokenizerPath
        )

        let texts = ["a sunset over the ocean", "drone aerial view"]

        // 预热
        for text in texts {
            _ = try await encoder.encode(text: text)
        }

        // 5 次计时
        var times: [Double] = []
        for _ in 0..<5 {
            let start = CFAbsoluteTimeGetCurrent()
            for text in texts {
                _ = try await encoder.encode(text: text)
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            times.append(elapsed)
        }

        let avg = times.reduce(0, +) / Double(times.count)
        let minT = times.min()!
        let maxT = times.max()!
        print("Text Encoder Benchmark (CoreML EP \(ORTSessionHelper.isCoreMLAvailable ? "ON" : "OFF")):")
        print("   2 texts x 5 rounds, avg: \(String(format: "%.1f", avg))ms, min: \(String(format: "%.1f", minT))ms, max: \(String(format: "%.1f", maxT))ms")
    }

    // MARK: - Helpers

    /// 创建纯色测试 PNG Data
    private func createTestPNGData(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = context.makeImage()!

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .png, properties: [:])!
    }

    /// 余弦相似度
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
}
