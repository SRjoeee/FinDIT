import Foundation
import OnnxRuntimeBindings
import SentencepieceTokenizer

/// EmbeddingGemma 文本编码器
///
/// 使用 SentencePiece tokenizer + ONNX Runtime 将文本编码为 768 维嵌入向量。
/// 输出向量与 Gemini embedding-001 在同一维度（768d, L2 归一化），
/// 可在 VectorStore 中混合搜索。
///
/// 与 `SigLIP2TextEncoder` 的关键差异：
/// - 需要 BOS token (id=2) 作为序列起始
/// - 独立文本模型，无需 dummy pixel_values
/// - Q8 模型支持图优化 `.all`（无 FP16 bug）
/// - 使用 Gemma 256K 词汇表（独立 tokenizer.model）
///
/// Tokenizer 注意事项（同 SigLIP2）:
/// - swift-sentencepiece 返回 1-indexed token ID
/// - EmbeddingGemma 期望 0-indexed，因此所有 ID 需要 -1 修正
public final class EmbeddingGemmaEncoder: @unchecked Sendable {

    public let name = "embedding-gemma"
    public var dimensions: Int { config.embeddingDimension }

    private let config: EmbeddingGemmaConfig
    private let modelPath: String
    private let tokenizerPath: String
    private let lock = NSLock()
    private var _session: ORTSession?
    private var _env: ORTEnv?
    private var _tokenizer: SentencepieceTokenizer?

    /// 创建 EmbeddingGemma 编码器
    ///
    /// - Parameters:
    ///   - modelPath: ONNX 模型路径。默认使用 EmbeddingGemmaModelManager 路径。
    ///   - tokenizerPath: SentencePiece tokenizer 路径。默认使用 EmbeddingGemmaModelManager 路径。
    ///   - config: 模型配置（默认 `EmbeddingGemmaConfig.default300M`）
    public init(
        modelPath: String? = nil,
        tokenizerPath: String? = nil,
        config: EmbeddingGemmaConfig = .default300M
    ) {
        self.modelPath = modelPath ?? EmbeddingGemmaModelManager.path(for: .model)
        self.tokenizerPath = tokenizerPath ?? EmbeddingGemmaModelManager.path(for: .tokenizer)
        self.config = config
    }

    /// 检查编码器是否可用（模型文件 + tokenizer 存在）
    public func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: modelPath)
            && FileManager.default.fileExists(atPath: tokenizerPath)
    }

    /// 编码单条文本为 768 维嵌入向量
    ///
    /// - Parameter text: 输入文本（中英文均可）
    /// - Returns: L2 归一化的 768 维嵌入向量
    public func encode(text: String) async throws -> [Float] {
        let (inputIds, attentionMask) = try tokenize(text)
        return try runInference(inputIds: inputIds, attentionMask: attentionMask)
    }

    // MARK: - Tokenization

    /// 文本 → token IDs + attention mask
    ///
    /// 流程: 小写化 → SentencePiece 分词 → ID -1 修正 → prepend BOS →
    ///       truncate (保留 EOS 位) → append EOS → pad 到 maxSequenceLength
    ///
    /// 与 SigLIP2 的差异：多了 BOS prepend 步骤。
    func tokenize(_ text: String) throws -> (inputIds: [Int32], attentionMask: [Int32]) {
        let tokenizer = try getTokenizer()
        let lowered = text.lowercased()
        let tokenIds = try tokenizer.encode(lowered)

        // swift-sentencepiece 是 1-indexed，EmbeddingGemma 期望 0-indexed → -1
        var inputIds = tokenIds.map { Int32(max(0, $0 - 1)) }

        // Prepend BOS (Gemma 家族必须)
        inputIds.insert(config.bosTokenId, at: 0)

        // Truncate BEFORE appending EOS，保证 EOS 始终存在
        // 最终序列: [BOS, token..., EOS, PAD...]
        let maxLen = config.maxSequenceLength
        if inputIds.count > maxLen - 1 {
            inputIds = Array(inputIds.prefix(maxLen - 1))
        }
        inputIds.append(config.eosTokenId)

        // Attention mask: 1 for real tokens, 0 for padding
        let realLength = inputIds.count
        var attentionMask = [Int32](repeating: 1, count: realLength)

        // Pad to maxSequenceLength
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
            throw EmbeddingError.embeddingFailed(
                detail: "EmbeddingGemma tokenizer not found: \(tokenizerPath)"
            )
        }

        do {
            let tokenizer = try SentencepieceTokenizer(modelPath: tokenizerPath)
            _tokenizer = tokenizer
            return tokenizer
        } catch {
            throw EmbeddingError.embeddingFailed(
                detail: "EmbeddingGemma tokenizer 加载失败: \(error.localizedDescription)"
            )
        }
    }

    /// 懒加载 ORT session
    private func getSession() throws -> ORTSession {
        lock.lock()
        defer { lock.unlock() }

        if let session = _session { return session }

        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw EmbeddingError.providerNotAvailable(name: "embedding-gemma")
        }

        let (env, session) = try ORTSessionHelper.createSession(
            modelPath: modelPath,
            graphOptimizationLevel: .all  // Q8 模型可安全启用图优化
        )
        _env = env
        _session = session
        return session
    }

    // MARK: - ONNX Runtime Inference

    /// 执行 ONNX 推理
    ///
    /// 独立文本模型，仅需 input_ids + attention_mask（无需 dummy pixel_values）。
    /// 输出优先级: sentence_embedding > pooler_output > last_hidden_state (需 mean pooling)。
    private func runInference(
        inputIds: [Int32],
        attentionMask: [Int32]
    ) throws -> [Float] {
        let session = try getSession()
        let maxLen = config.maxSequenceLength

        // input_ids: [1, maxLen] as Int64
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

        // attention_mask: [1, maxLen] as Int64
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

        let inputs: [String: ORTValue] = [
            "input_ids": idsTensor,
            "attention_mask": maskTensor,
        ]

        let outputNames = try session.outputNames()
        let outputs = try session.run(
            withInputs: inputs,
            outputNames: Set(outputNames),
            runOptions: nil
        )

        // 优先取 sentence_embedding (直接可用)，回退到 pooler_output，
        // 最后回退到 last_hidden_state (需要 mean pooling)
        let preferredKeys = ["sentence_embedding", "pooler_output"]
        if let targetKey = preferredKeys.first(where: { outputNames.contains($0) }),
           let outputValue = outputs[targetKey] {
            return try extractAndNormalize(outputValue, expectedDim: config.embeddingDimension)
        }

        // 回退: last_hidden_state → mean pooling
        if outputNames.contains("last_hidden_state"),
           let outputValue = outputs["last_hidden_state"] {
            return try meanPoolAndNormalize(
                outputValue,
                attentionMask: attentionMask,
                seqLen: maxLen,
                embeddingDim: config.embeddingDimension
            )
        }

        // 最后回退: 取第一个输出
        guard let firstKey = outputNames.first,
              let outputValue = outputs[firstKey] else {
            throw EmbeddingError.embeddingFailed(
                detail: "EmbeddingGemma: 无可用输出 (available: \(outputNames))"
            )
        }
        return try extractAndNormalize(outputValue, expectedDim: config.embeddingDimension)
    }

    /// 从 ORTValue 提取 Float 数组并 L2 归一化
    private func extractAndNormalize(_ value: ORTValue, expectedDim: Int) throws -> [Float] {
        let data = try value.tensorData()
        let floatCount = data.count / MemoryLayout<Float>.size
        var embedding = [Float](repeating: 0, count: floatCount)
        data.getBytes(&embedding, length: data.count)

        // 如果输出是 [1, dim]，取前 dim 个
        if embedding.count > expectedDim {
            embedding = Array(embedding.prefix(expectedDim))
        }

        guard embedding.count == expectedDim else {
            throw EmbeddingError.dimensionMismatch(
                expected: expectedDim, got: embedding.count
            )
        }

        return EmbeddingUtils.l2Normalize(embedding)
    }

    /// Mean pooling: 对 attention_mask=1 的位置取平均，再 L2 归一化
    ///
    /// last_hidden_state shape: [1, seqLen, embeddingDim]
    private func meanPoolAndNormalize(
        _ value: ORTValue,
        attentionMask: [Int32],
        seqLen: Int,
        embeddingDim: Int
    ) throws -> [Float] {
        let data = try value.tensorData()
        let expectedCount = seqLen * embeddingDim
        let floatCount = data.count / MemoryLayout<Float>.size

        guard floatCount >= expectedCount else {
            throw EmbeddingError.embeddingFailed(
                detail: "last_hidden_state 大小不匹配: 期望 \(expectedCount), 实际 \(floatCount)"
            )
        }

        var allFloats = [Float](repeating: 0, count: floatCount)
        data.getBytes(&allFloats, length: data.count)

        // Mean pooling over attention_mask=1 positions
        var sum = [Float](repeating: 0, count: embeddingDim)
        var tokenCount: Float = 0

        for i in 0..<seqLen {
            if attentionMask[i] == 1 {
                let offset = i * embeddingDim
                for j in 0..<embeddingDim {
                    sum[j] += allFloats[offset + j]
                }
                tokenCount += 1
            }
        }

        guard tokenCount > 0 else {
            throw EmbeddingError.embeddingFailed(detail: "attention_mask 全为 0，无法 mean pool")
        }

        let mean = sum.map { $0 / tokenCount }
        return EmbeddingUtils.l2Normalize(mean)
    }
}
