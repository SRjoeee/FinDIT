import Foundation

// MARK: - EmbeddingGemmaConfig

/// EmbeddingGemma-300M 模型配置
///
/// 定义 EmbeddingGemma 的 tokenizer 参数和模型规格。
/// 与 `SigLIP2Config` 的关键差异：
/// - 需要 BOS token (id=2) 作为序列起始
/// - 使用 Gemma 256K 词汇表（独立 tokenizer.model）
/// - 纯文本模型，无图像相关参数
public struct EmbeddingGemmaConfig: Sendable {
    /// 输出嵌入维度
    public let embeddingDimension: Int
    /// 最大序列长度（模型支持 2048，实际使用 256 足够）
    public let maxSequenceLength: Int
    /// PAD token ID
    public let padTokenId: Int32
    /// EOS token ID
    public let eosTokenId: Int32
    /// BOS token ID（Gemma 家族必须 prepend BOS）
    public let bosTokenId: Int32
    /// 词汇表大小
    public let vocabSize: Int

    /// EmbeddingGemma-300M 默认配置
    public static let default300M = EmbeddingGemmaConfig(
        embeddingDimension: 768,
        maxSequenceLength: 256,
        padTokenId: 0,
        eosTokenId: 1,
        bosTokenId: 2,
        vocabSize: 256000
    )

    public init(
        embeddingDimension: Int = 768,
        maxSequenceLength: Int = 256,
        padTokenId: Int32 = 0,
        eosTokenId: Int32 = 1,
        bosTokenId: Int32 = 2,
        vocabSize: Int = 256000
    ) {
        self.embeddingDimension = embeddingDimension
        self.maxSequenceLength = maxSequenceLength
        self.padTokenId = padTokenId
        self.eosTokenId = eosTokenId
        self.bosTokenId = bosTokenId
        self.vocabSize = vocabSize
    }
}

// MARK: - EmbeddingGemmaModelManager

/// EmbeddingGemma 模型文件管理器
///
/// 管理 EmbeddingGemma 模型文件的路径解析和可用性检查。
/// 模型文件存放在 `~/Library/Application Support/FindIt/models/embedding-gemma/` 目录下。
///
/// 所需文件:
/// - `model_q8.onnx` — Q8 量化 ONNX 模型（~300MB）
/// - `tokenizer.model` — SentencePiece tokenizer 模型（Gemma 256K 词汇表）
public enum EmbeddingGemmaModelManager {

    /// 模型目录名
    static let modelDirectoryName = "embedding-gemma"

    /// 所需模型文件
    public enum ModelFile: String, CaseIterable {
        /// Q8 量化 ONNX 模型
        case model = "model_q8.onnx"
        /// SentencePiece tokenizer
        case tokenizer = "tokenizer.model"
    }

    /// 获取模型存储根目录
    ///
    /// `~/Library/Application Support/FindIt/models/embedding-gemma/`
    public static var modelDirectory: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.path
        return (appSupport as NSString)
            .appendingPathComponent("FindIt/models/\(modelDirectoryName)")
    }

    /// 获取指定模型文件的路径
    public static func path(for file: ModelFile) -> String {
        (modelDirectory as NSString).appendingPathComponent(file.rawValue)
    }

    /// 检查指定模型文件是否存在
    public static func exists(_ file: ModelFile) -> Bool {
        FileManager.default.fileExists(atPath: path(for: file))
    }

    /// 检查所有必需模型文件是否存在
    public static func allModelsAvailable() -> Bool {
        ModelFile.allCases.allSatisfy { exists($0) }
    }

    /// 列出缺失的模型文件
    public static func missingModels() -> [ModelFile] {
        ModelFile.allCases.filter { !exists($0) }
    }

    /// 确保模型目录存在
    public static func ensureModelDirectory() throws {
        try FileManager.default.createDirectory(
            atPath: modelDirectory,
            withIntermediateDirectories: true
        )
    }

    /// 模型文件信息
    public struct ModelInfo: Sendable {
        public let file: String
        public let path: String
        public let exists: Bool
        public let sizeBytes: Int64?
    }

    /// 获取所有模型文件的状态信息
    public static func modelStatus() -> [ModelInfo] {
        ModelFile.allCases.map { file in
            let filePath = path(for: file)
            let fileExists = FileManager.default.fileExists(atPath: filePath)
            let size: Int64? = fileExists
                ? (try? FileManager.default.attributesOfItem(atPath: filePath)[.size] as? Int64)
                : nil
            return ModelInfo(
                file: file.rawValue,
                path: filePath,
                exists: fileExists,
                sizeBytes: size
            )
        }
    }
}
