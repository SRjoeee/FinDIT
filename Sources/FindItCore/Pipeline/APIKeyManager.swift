import Foundation

/// API Key 管理器
///
/// 集中管理 API Key 的解析、验证和持久化。
/// 支持多 provider（Gemini、OpenRouter），每个 provider 使用独立的 key 文件和环境变量。
///
/// Key 解析优先级: override 参数 > 配置文件 > 环境变量
///
/// Key 存储路径:
/// - Gemini: `~/.config/findit/gemini-api-key.txt`
/// - OpenRouter: `~/.config/findit/openrouter-api-key.txt`
///
/// 与 CLI 共享，不使用 UserDefaults，保持命令行兼容。
public enum APIKeyManager {

    // MARK: - 常量

    /// 默认 API Key 文件路径（Gemini，保持向后兼容）
    public static let defaultKeyFilePath = "~/.config/findit/gemini-api-key.txt"

    /// API Key 环境变量名（Gemini，保持向后兼容）
    public static let envVarName = "GEMINI_API_KEY"

    // MARK: - 错误类型

    /// API Key 管理错误
    public enum KeyError: Error, LocalizedError {
        case notFound
        case saveFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notFound:
                return "未找到 API Key。请在 ~/.config/findit/ 中配置，或设置相应的环境变量"
            case .saveFailed(let detail):
                return "保存 API Key 失败: \(detail)"
            }
        }
    }

    // MARK: - 解析

    /// 解析 API Key（优先级：override > 文件 > 环境变量）
    ///
    /// - Parameters:
    ///   - override: 外部传入的 Key（最高优先级，如 CLI 参数）
    ///   - provider: API 提供者（决定 key 文件路径和环境变量名）
    /// - Returns: 有效的 API Key
    /// - Throws: `KeyError.notFound` 若所有来源均无有效 Key
    public static func resolveAPIKey(override: String? = nil, provider: APIProvider = .gemini) throws -> String {
        // 1. 外部 override
        if let key = override, validateAPIKey(key) {
            return key
        }

        // 2. 配置文件（按 provider 读取对应文件）
        let keyFilePath = provider.keyFilePath
        let expandedPath = (keyFilePath as NSString).expandingTildeInPath
        if let key = readAPIKeyFromFile(expandedPath), validateAPIKey(key) {
            return key
        }

        // 3. 环境变量（按 provider 读取对应变量）
        let envVar = provider.envVarName
        if let key = ProcessInfo.processInfo.environment[envVar],
           validateAPIKey(key) {
            return key
        }

        throw KeyError.notFound
    }

    // MARK: - 验证

    /// 验证 API Key 格式（基本检查）
    ///
    /// API Key 通常 10+ 字符。这里只做最基本的非空 + 最短长度检查。
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
    /// 自动创建 `~/.config/findit/` 目录。
    ///
    /// - Parameters:
    ///   - key: 要保存的 API Key（空字符串 = 清除 Key）
    ///   - provider: API 提供者（决定写入哪个文件）
    /// - Throws: `KeyError.saveFailed` 若写入失败
    public static func saveAPIKey(_ key: String, provider: APIProvider = .gemini) throws {
        let dir = try ensureConfigDirectory()
        let fileName = (provider.keyFilePath as NSString).lastPathComponent
        let filePath = (dir as NSString).appendingPathComponent(fileName)

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
