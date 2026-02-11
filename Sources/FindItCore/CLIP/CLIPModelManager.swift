import Foundation

/// CLIP 模型文件管理器
///
/// 管理 SigLIP2 模型文件的路径解析和可用性检查。
/// 模型文件存放在 `~/Library/Application Support/FindIt/models/siglip2/` 目录下。
///
/// 所需文件:
/// - `model_fp16.onnx` — 合并模型（含 vision + text encoder + 投影层, ~716MB）
/// - `tokenizer.model` — SentencePiece tokenizer 模型 (~4MB)
public enum CLIPModelManager {

    /// 模型目录名
    static let modelDirectoryName = "siglip2"

    /// 所需模型文件
    public enum ModelFile: String, CaseIterable {
        /// 合并 ONNX 模型（vision + text + projection）
        case combinedModel = "model_fp16.onnx"
        /// SentencePiece tokenizer
        case tokenizer = "tokenizer.model"
    }

    /// 获取模型存储根目录
    ///
    /// `~/Library/Application Support/FindIt/models/siglip2/`
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
