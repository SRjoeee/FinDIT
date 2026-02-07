import Foundation

/// API Key 管理器
///
/// 集中管理 Gemini API Key 的解析、验证和持久化。
/// 被 VisionAnalyzer、GeminiEmbeddingProvider、IndexingManager、
/// SearchState、CLI 等模块共同使用。
///
/// Key 解析优先级: override 参数 > 配置文件 > 环境变量
///
/// Key 存储路径: `~/.config/findit/gemini-api-key.txt`
/// （与 CLI 共享，不使用 UserDefaults，保持命令行兼容）
public enum APIKeyManager {

    // MARK: - 常量

    /// 默认 API Key 文件路径
    public static let defaultKeyFilePath = "~/.config/findit/gemini-api-key.txt"

    /// API Key 环境变量名
    public static let envVarName = "GEMINI_API_KEY"

    // MARK: - 错误类型

    /// API Key 管理错误
    public enum KeyError: Error, LocalizedError {
        case notFound
        case saveFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notFound:
                return "未找到 API Key。请在 ~/.config/findit/gemini-api-key.txt 中配置，或设置环境变量 GEMINI_API_KEY"
            case .saveFailed(let detail):
                return "保存 API Key 失败: \(detail)"
            }
        }
    }

    // MARK: - 解析

    /// 解析 API Key（优先级：override > 文件 > 环境变量）
    ///
    /// - Parameter override: 外部传入的 Key（最高优先级，如 CLI 参数）
    /// - Returns: 有效的 API Key
    /// - Throws: `KeyError.notFound` 若所有来源均无有效 Key
    public static func resolveAPIKey(override: String? = nil) throws -> String {
        // 1. 外部 override
        if let key = override, validateAPIKey(key) {
            return key
        }

        // 2. 配置文件
        let expandedPath = (defaultKeyFilePath as NSString).expandingTildeInPath
        if let key = readAPIKeyFromFile(expandedPath), validateAPIKey(key) {
            return key
        }

        // 3. 环境变量
        if let key = ProcessInfo.processInfo.environment[envVarName],
           validateAPIKey(key) {
            return key
        }

        throw KeyError.notFound
    }

    // MARK: - 验证

    /// 验证 API Key 格式（基本检查）
    ///
    /// Gemini API Key 通常以 "AIza" 开头，长度约 39 字符。
    /// 这里只做最基本的非空 + 最短长度检查。
    public static func validateAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 10
    }

    // MARK: - 文件读写

    /// 从文件读取 API Key
    ///
    /// - Parameter path: 文件绝对路径
    /// - Returns: trim 后的 Key，文件不存在或为空返回 nil
    static func readAPIKeyFromFile(_ path: String) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 保存 API Key 到配置文件
    ///
    /// 自动创建 `~/.config/findit/` 目录。写入后可被 CLI 和 App 共享读取。
    ///
    /// - Parameter key: 要保存的 API Key（空字符串 = 清除 Key）
    /// - Throws: `KeyError.saveFailed` 若写入失败
    public static func saveAPIKey(_ key: String) throws {
        let dir = try ensureConfigDirectory()
        let filePath = (dir as NSString).appendingPathComponent("gemini-api-key.txt")

        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try trimmed.write(toFile: filePath, atomically: true, encoding: .utf8)
        } catch {
            throw KeyError.saveFailed(error.localizedDescription)
        }
    }

    /// 确保 API Key 配置目录存在
    ///
    /// - Returns: 展开后的目录路径
    @discardableResult
    public static func ensureConfigDirectory() throws -> String {
        let expandedPath = (defaultKeyFilePath as NSString).expandingTildeInPath
        let dir = (expandedPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        return dir
    }
}
