import Foundation
import GRDB

/// 用户标签管理器
///
/// 提供对 clips 表 `user_tags` 字段的增删改查操作。
/// `user_tags` 与 `tags`（AI 自动生成）独立存储，格式相同（JSON 数组）。
/// 搜索时两者均参与 FTS5 全文搜索。
public enum TagManager {

    /// 给片段添加用户标签（合并去重，保留原有标签）
    ///
    /// - Parameters:
    ///   - db: 数据库连接（文件夹级库）
    ///   - clipId: 片段 ID
    ///   - tags: 要添加的标签
    public static func addTags(_ db: Database, clipId: Int64, tags: [String]) throws {
        let cleaned = tags.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }

        let existing = try fetchUserTags(db, clipId: clipId)
        var seen = Set(existing)
        var merged = existing
        for tag in cleaned {
            if !seen.contains(tag) {
                seen.insert(tag)
                merged.append(tag)
            }
        }

        try writeUserTags(db, clipId: clipId, tags: merged)
    }

    /// 移除片段的指定用户标签
    ///
    /// 不存在的标签静默忽略。
    public static func removeTags(_ db: Database, clipId: Int64, tags: [String]) throws {
        let toRemove = Set(tags.map { $0.trimmingCharacters(in: .whitespaces) })
        let existing = try fetchUserTags(db, clipId: clipId)
        let filtered = existing.filter { !toRemove.contains($0) }

        try writeUserTags(db, clipId: clipId, tags: filtered)
    }

    /// 替换片段的全部用户标签
    public static func replaceTags(_ db: Database, clipId: Int64, tags: [String]) throws {
        let cleaned = tags.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        try writeUserTags(db, clipId: clipId, tags: cleaned)
    }

    /// 查询片段的用户标签
    public static func fetchUserTags(_ db: Database, clipId: Int64) throws -> [String] {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT user_tags FROM clips WHERE clip_id = ?
            """, arguments: [clipId]) else {
            return []
        }
        return parseTagsJSON(row["user_tags"])
    }

    /// 统计所有标签（auto + user）的使用频率
    ///
    /// 返回按使用次数降序排列的标签列表。
    /// 从 `tags` 和 `user_tags` 两个字段的 JSON 数组中提取标签并合并统计。
    public static func popularTags(_ db: Database, limit: Int = 30) throws -> [(tag: String, count: Int)] {
        // 收集所有 clips 的 tags 和 user_tags
        let rows = try Row.fetchAll(db, sql: """
            SELECT tags, user_tags FROM clips
            """)

        var counts: [String: Int] = [:]
        for row in rows {
            let autoTags = parseTagsJSON(row["tags"])
            let userTags = parseTagsJSON(row["user_tags"])
            // 每个 clip 内 auto + user 去重后各贡献 1 次
            var seen = Set<String>()
            for tag in autoTags + userTags {
                let trimmed = tag.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
                seen.insert(trimmed)
                counts[trimmed, default: 0] += 1
            }
        }

        return counts.sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (tag: $0.key, count: $0.value) }
    }

    // MARK: - Private

    /// 将标签数组写入 user_tags 字段
    private static func writeUserTags(_ db: Database, clipId: Int64, tags: [String]) throws {
        let jsonString: String?
        if tags.isEmpty {
            jsonString = nil
        } else {
            let data = try JSONEncoder().encode(tags)
            jsonString = String(data: data, encoding: .utf8)
        }

        try db.execute(sql: """
            UPDATE clips SET user_tags = ? WHERE clip_id = ?
            """, arguments: [jsonString, clipId])
    }

    /// 解析 JSON 数组字符串为字符串数组
    static func parseTagsJSON(_ value: DatabaseValue?) -> [String] {
        guard let dbValue = value,
              let string = String.fromDatabaseValue(dbValue),
              let data = string.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return array
    }
}
