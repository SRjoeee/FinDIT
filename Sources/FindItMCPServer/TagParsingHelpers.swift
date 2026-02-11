import Foundation

/// 全局库 tags 解析辅助
///
/// 全局库的 tags 字段是空格分隔文本（由 SyncEngine.convertTagsForFTS 转换），
/// 而文件夹库存 JSON 数组。此辅助方法同时兼容两种格式。
enum TagParsingHelpers {

    /// 将全局库的 tags 字符串解析为数组
    ///
    /// - 先尝试 JSON 数组格式（兼容未转换的数据）
    /// - 回退到空格分割（正常的 FTS 格式）
    static func parseTagsFromGlobalDB(_ str: String?) -> [String] {
        guard let str, !str.isEmpty else { return [] }

        // 尝试 JSON 数组格式
        if str.hasPrefix("["),
           let data = str.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return arr.filter { !$0.isEmpty }
        }

        // 正常情况：空格分隔
        return str.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }
}
