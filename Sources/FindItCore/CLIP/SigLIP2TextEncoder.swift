import Foundation
import OnnxRuntimeBindings
import SentencepieceTokenizer

/// SigLIP2 文本编码器
///
/// 使用 SentencePiece tokenizer + ONNX Runtime 将文本编码为 768 维 CLIP 向量。
/// 输出向量与 `SigLIP2ImageEncoder` 在同一嵌入空间，支持跨模态搜索。
///
/// Tokenizer 注意事项:
/// - swift-sentencepiece 返回 1-indexed token ID
/// - SigLIP2 期望 0-indexed，因此所有 ID 需要 -1 修正
///
/// - Important: ORT GraphOptimizationLevel 必须为 `.none`，FP16 模型的图优化有 Bug。
public final class SigLIP2TextEncoder: CLIPTextEncoder, @unchecked Sendable {

    public let name = "siglip2-base"
    public var dimensions: Int { config.embeddingDimension }

    private let config: SigLIP2Config
    private let modelPath: String
    private let tokenizerPath: String
    private let lock = NSLock()
    private var _session: ORTSession?
    private var _env: ORTEnv?
    private var _tokenizer: SentencepieceTokenizer?

    /// 创建 SigLIP2 文本编码器
    ///
    /// - Parameters:
    ///   - modelPath: 合并模型路径（`model_fp16.onnx`）。默认使用 CLIPModelManager 路径。
    ///   - tokenizerPath: SentencePiece tokenizer 路径。默认使用 CLIPModelManager 路径。
    ///   - config: 模型配置（默认 `SigLIP2Config.base224`）
    public init(
        modelPath: String? = nil,
        tokenizerPath: String? = nil,
        config: SigLIP2Config = .base224
    ) {
        self.modelPath = modelPath ?? CLIPModelManager.path(for: .combinedModel)
        self.tokenizerPath = tokenizerPath ?? CLIPModelManager.path(for: .tokenizer)
        self.config = config
    }

    public func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: modelPath)
            && FileManager.default.fileExists(atPath: tokenizerPath)
    }

    public func encode(text: String) async throws -> [Float] {
        let (inputIds, attentionMask) = try tokenize(text)
        return try await runInference(inputIds: inputIds, attentionMask: attentionMask)
    }

    // MARK: - Tokenization

    /// 文本 → token IDs + attention mask
    ///
    /// 流程: 小写化 → SentencePiece 分词 → ID -1 修正 → 追加 EOS → pad/truncate 到 64
    func tokenize(_ text: String) throws -> (inputIds: [Int32], attentionMask: [Int32]) {
        let tokenizer = try getTokenizer()
        let lowered = text.lowercased()
        let tokenIds = try tokenizer.encode(lowered)

        // swift-sentencepiece 是 1-indexed，SigLIP2 期望 0-indexed → -1
        var inputIds = tokenIds.map { Int32($0) - 1 }
        inputIds.append(config.eosTokenId)

        // Truncate
        let maxLen = config.maxTextLength
        if inputIds.count > maxLen {
            inputIds = Array(inputIds.prefix(maxLen))
        }

        // Attention mask: 1 for real tokens, 0 for padding
        let realLength = inputIds.count
        var attentionMask = [Int32](repeating: 1, count: realLength)

        // Pad to maxTextLength
        while inputIds.count < maxLen {
            inputIds.append(config.padTokenId)
            attentionMask.append(0)
        }

        return (inputIds, attentionMask)
    }

    // MARK: - Lazy Loading

    /// 懒加载 SentencePiece tokenizer
    private func getTokenizer() throws -> SentencepieceTokenizer {
        lock.lock()
        defer { lock.unlock() }

        if let tokenizer = _tokenizer { return tokenizer }

        guard FileManager.default.fileExists(atPath: tokenizerPath) else {
            throw CLIPError.tokenizerFailed(detail: "Tokenizer not found: \(tokenizerPath)")
        }

        do {
            let tokenizer = try SentencepieceTokenizer(modelPath: tokenizerPath)
            _tokenizer = tokenizer
            return tokenizer
        } catch {
            throw CLIPError.tokenizerFailed(detail: error.localizedDescription)
        }
    }

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
        // FP16 模型必须禁用图优化
        try options.setGraphOptimizationLevel(.none)

        let session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: options)
        _env = env
        _session = session
        return session
    }

    // MARK: - ONNX Runtime Inference

    /// 执行 ONNX 推理
    ///
    /// 合并模型需要同时提供 dummy pixel_values 和真实 text 输入。
    /// 输出取 `text_embeds` 键。
    private func runInference(
        inputIds: [Int32],
        attentionMask: [Int32]
    ) async throws -> [Float] {
        let session = try getSession()
        let size = config.imageSize
        let maxLen = config.maxTextLength

        // Dummy pixel_values: [1, 3, H, W] 全零
        let pixelCount = 3 * size * size
        var dummyPixels = [Float](repeating: 0, count: pixelCount)
        let pixelData = NSMutableData(
            bytes: &dummyPixels,
            length: dummyPixels.count * MemoryLayout<Float>.size
        )
        let pixelTensor = try ORTValue(
            tensorData: pixelData,
            elementType: .float,
            shape: [1, 3, NSNumber(value: size), NSNumber(value: size)]
        )

        // input_ids: [1, 64] as Int64
        var ids64 = inputIds.map { Int64($0) }
        let idsData = NSMutableData(
            bytes: &ids64,
            length: ids64.count * MemoryLayout<Int64>.size
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

        // attention_mask if model expects it
        let modelInputNames = try session.inputNames()
        if modelInputNames.contains("attention_mask") {
            var mask64 = attentionMask.map { Int64($0) }
            let maskData = NSMutableData(
                bytes: &mask64,
                length: mask64.count * MemoryLayout<Int64>.size
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

        // 优先取 text_embeds (投影后)，回退到 pooler_output
        let preferredKeys = ["text_embeds", "pooler_output"]
        let targetKey = preferredKeys.first { outputNames.contains($0) } ?? outputNames.first!
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
        return l2Normalize(embedding)
    }

    // MARK: - Utility

    private func l2Normalize(_ v: [Float]) -> [Float] {
        var sum: Float = 0
        for x in v { sum += x * x }
        let norm = sqrt(sum)
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }
}
