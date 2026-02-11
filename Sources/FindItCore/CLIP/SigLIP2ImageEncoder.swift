import Foundation
import ImageIO
import CoreGraphics
import OnnxRuntimeBindings

/// SigLIP2 视觉编码器
///
/// 使用 ONNX Runtime 加载 SigLIP2 合并模型，将图片编码为 768 维 CLIP 向量。
/// 输出向量与 `SigLIP2TextEncoder` 在同一嵌入空间，支持文字搜图。
///
/// 使用合并模型 (`model_fp16.onnx`) 包含 vision encoder + text encoder + 投影层，
/// 编码图片时传递 dummy text 输入。
///
/// - Important: ORT GraphOptimizationLevel 必须为 `.none`，FP16 模型的图优化有 Bug。
public final class SigLIP2ImageEncoder: CLIPImageEncoder, @unchecked Sendable {

    public let name = "siglip2-base"
    public var dimensions: Int { config.embeddingDimension }

    private let config: SigLIP2Config
    private let modelPath: String
    private let lock = NSLock()
    private var _session: ORTSession?
    private var _env: ORTEnv?

    /// 创建 SigLIP2 视觉编码器
    ///
    /// - Parameters:
    ///   - modelPath: 合并模型路径（`model_fp16.onnx`）。
    ///                 默认使用 `CLIPModelManager` 管理的路径。
    ///   - config: 模型配置（默认 `SigLIP2Config.base224`）
    public init(
        modelPath: String? = nil,
        config: SigLIP2Config = .base224
    ) {
        self.modelPath = modelPath ?? CLIPModelManager.path(for: .combinedModel)
        self.config = config
    }

    public func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: modelPath)
    }

    public func encode(imageData: Data) async throws -> [Float] {
        let pixels = try preprocessImageData(imageData)
        return try await runInference(pixels: pixels)
    }

    public func encode(imagePath: String) async throws -> [Float] {
        let pixels = try preprocessImageFile(imagePath)
        return try await runInference(pixels: pixels)
    }

    // MARK: - Image Preprocessing

    /// 预处理图片文件为 CHW 浮点张量
    ///
    /// 1. 加载图片 (CGImage)
    /// 2. Resize 到 224×224 (bilinear)
    /// 3. 归一化: (pixel/255 - 0.5) / 0.5 → [-1, 1]
    /// 4. 转为 [3, 224, 224] CHW 格式
    func preprocessImageFile(_ path: String) throws -> [Float] {
        guard let imageSource = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, nil
        ),
        let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw CLIPError.imageProcessingFailed(detail: "Cannot load image: \(path)")
        }
        return try preprocessCGImage(cgImage)
    }

    /// 预处理图片数据为 CHW 浮点张量
    func preprocessImageData(_ data: Data) throws -> [Float] {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw CLIPError.imageProcessingFailed(detail: "Cannot decode image data")
        }
        return try preprocessCGImage(cgImage)
    }

    /// CGImage → [3, 224, 224] 归一化浮点张量
    func preprocessCGImage(_ cgImage: CGImage) throws -> [Float] {
        let size = config.imageSize
        let bytesPerRow = size * 4
        var pixelData = [UInt8](repeating: 0, count: size * bytesPerRow)

        guard let context = CGContext(
            data: &pixelData, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw CLIPError.imageProcessingFailed(detail: "Cannot create CGContext")
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        // RGBA → CHW 归一化
        let pixelCount = size * size
        var result = [Float](repeating: 0, count: 3 * pixelCount)
        let mean = config.imageMean
        let std = config.imageStd

        for i in 0..<pixelCount {
            let r = Float(pixelData[i * 4]) / 255.0
            let g = Float(pixelData[i * 4 + 1]) / 255.0
            let b = Float(pixelData[i * 4 + 2]) / 255.0
            result[i] = (r - mean) / std                  // R channel
            result[pixelCount + i] = (g - mean) / std     // G channel
            result[2 * pixelCount + i] = (b - mean) / std // B channel
        }
        return result
    }

    // MARK: - ONNX Runtime Inference

    /// 懒加载 ORT session
    private func getSession() throws -> ORTSession {
        lock.lock()
        defer { lock.unlock() }

        if let session = _session { return session }

        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw CLIPError.modelNotFound(path: modelPath)
        }

        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        // FP16 模型必须禁用图优化，否则产生错误输出
        try options.setGraphOptimizationLevel(.none)

        let session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: options)
        _env = env
        _session = session
        return session
    }

    /// 执行 ONNX 推理
    ///
    /// 合并模型需要同时提供 pixel_values 和 dummy text 输入。
    /// 输出取 `image_embeds` 键。
    private func runInference(pixels: [Float]) async throws -> [Float] {
        let session = try getSession()
        let size = config.imageSize
        let maxLen = config.maxTextLength

        // pixel_values: [1, 3, H, W]
        var pixelsCopy = pixels
        let pixelData = NSMutableData(
            bytes: &pixelsCopy,
            length: pixelsCopy.count * MemoryLayout<Float>.size
        )
        let pixelTensor = try ORTValue(
            tensorData: pixelData,
            elementType: .float,
            shape: [1, 3, NSNumber(value: size), NSNumber(value: size)]
        )

        // Dummy input_ids: [1, 64] 全 PAD
        var dummyIds = [Int64](repeating: Int64(config.padTokenId), count: maxLen)
        let idsData = NSMutableData(
            bytes: &dummyIds,
            length: dummyIds.count * MemoryLayout<Int64>.size
        )
        let idsTensor = try ORTValue(
            tensorData: idsData,
            elementType: .int64,
            shape: [1, NSNumber(value: maxLen)]
        )

        var inputs: [String: ORTValue] = [
            "pixel_values": pixelTensor,
            "input_ids": idsTensor,
        ]

        // 合并模型可能需要 attention_mask
        let modelInputNames = try session.inputNames()
        if modelInputNames.contains("attention_mask") {
            var dummyMask = [Int64](repeating: 0, count: maxLen)
            let maskData = NSMutableData(
                bytes: &dummyMask,
                length: dummyMask.count * MemoryLayout<Int64>.size
            )
            let maskTensor = try ORTValue(
                tensorData: maskData,
                elementType: .int64,
                shape: [1, NSNumber(value: maxLen)]
            )
            inputs["attention_mask"] = maskTensor
        }

        let outputNames = try session.outputNames()
        let outputs = try session.run(
            withInputs: inputs,
            outputNames: Set(outputNames),
            runOptions: nil
        )

        // 优先取 image_embeds (投影后)，回退到 pooler_output
        let preferredKeys = ["image_embeds", "pooler_output"]
        guard let targetKey = preferredKeys.first(where: { outputNames.contains($0) }) ?? outputNames.first else {
            throw CLIPError.inferenceFailed(detail: "ONNX model has no output tensors")
        }
        guard let outputValue = outputs[targetKey] else {
            throw CLIPError.inferenceFailed(detail: "No output for key '\(targetKey)'")
        }

        let outputData = try outputValue.tensorData()
        let floatCount = outputData.count / MemoryLayout<Float>.size
        var embedding = [Float](repeating: 0, count: floatCount)
        outputData.getBytes(&embedding, length: outputData.count)

        guard embedding.count == config.embeddingDimension else {
            throw CLIPError.dimensionMismatch(
                expected: config.embeddingDimension, got: embedding.count
            )
        }

        // L2 归一化
        return EmbeddingUtils.l2Normalize(embedding)
    }
}
