import Foundation

/// 全局 DB tags 解析工具
///
/// 全局 DB 的 `tags` / `user_tags` 由 `SyncEngine.convertTagsForFTS()` 从 JSON 数组
/// 转为空格分隔字符串（如 `"海滩 户外 全景"`）。此工具提供统一解析，兼容两种格式。
enum TagParsingHelpers {

    /// 解析全局 DB 中的 tags/user_tags 字段为字符串数组
    ///
    /// 优先尝试 JSON 数组格式（兜底 edge case），失败则按空格分割。
    static func parseTagsFromGlobalDB(_ str: String?) -> [String] {
        guard let str, !str.isEmpty else { return [] }

        // Edge case: 如果 convertTagsForFTS 未生效，可能仍为 JSON 数组
        if str.hasPrefix("["),
           let data = str.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return arr.filter { !$0.isEmpty }
        }

        // 正常情况：空格分隔
        return str.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }
}
