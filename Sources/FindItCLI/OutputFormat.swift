import ArgumentParser
import Foundation

/// CLI 输出格式
///
/// 所有输出数据的命令统一通过 `--format text|json` 切换输出格式。
/// `text` 为人类可读的表格/列表格式，`json` 为机器可解析的 JSON。
enum OutputFormat: String, CaseIterable, ExpressibleByArgument {
    case text
    case json
}

/// JSON 序列化输出工具
enum JSONOutput {

    /// 将 Encodable 值输出为格式化 JSON（prettyPrinted + sortedKeys）
    static func print<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        Swift.print(String(data: data, encoding: .utf8) ?? "{}")
    }
}

/// CLI 通用工具
enum CLIHelpers {

    /// 格式化秒数为 m:ss
    static func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    /// 格式化文件大小为人类可读字符串
    static func formatFileSize(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        } else if bytes >= 1_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000)
        } else if bytes >= 1_000 {
            return String(format: "%.1f KB", Double(bytes) / 1_000)
        }
        return "\(bytes) B"
    }

    /// 从视频路径向上查找文件夹库所在目录
    ///
    /// 逐级向上搜索 `.clip-index/index.sqlite`，找到第一个匹配的目录。
    static func detectFolderPath(from videoPath: String) -> String? {
        var current = (videoPath as NSString).deletingLastPathComponent
        while current != "/" && !current.isEmpty {
            let dbPath = (current as NSString).appendingPathComponent(".clip-index/index.sqlite")
            if FileManager.default.fileExists(atPath: dbPath) {
                return current
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }
}
