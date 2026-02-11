import Foundation
import MCP
import GRDB
import FindItCore

/// 批量浏览素材库中的所有片段元数据
///
/// 专为 AI 设计的全量数据读取工具。从全局搜索索引（globalDB）读取，
/// 支持分页、过滤、排序，返回全部 vision 字段。
///
/// AI 典型用法:
/// 1. 不传 folder → 获取全局概览
/// 2. 传 folder → 聚焦单个项目
/// 3. 用 offset/limit 翻页遍历全部素材
enum BrowseAllClipsTool {

    /// 每次请求返回的最大条数（防止内存溢出）
    private static let maxLimit = 500

    static func execute(params: CallTool.Parameters, context: DatabaseContext) async throws -> CallTool.Result {
        let folder = ParamHelpers.optionalString(params, key: "folder")
        let offset = max(ParamHelpers.optionalInt(params, key: "offset") ?? 0, 0)
        let requestedLimit = ParamHelpers.optionalInt(params, key: "limit") ?? 100
        let limit = min(max(requestedLimit, 1), maxLimit)
        let sortBy = ParamHelpers.optionalString(params, key: "sort_by") ?? "clip_id"
        let minRating = ParamHelpers.optionalInt(params, key: "min_rating")
        let colorLabels = ParamHelpers.optionalStringArray(params, key: "color_labels")
        let shotTypes = ParamHelpers.optionalStringArray(params, key: "shot_types")
        let moods = ParamHelpers.optionalStringArray(params, key: "moods")

        // 构建 WHERE 子句
        var conditions: [String] = []
        var arguments: [DatabaseValueConvertible] = []

        if let folder {
            conditions.append("c.source_folder = ?")
            arguments.append(folder)
        }

        if let minRating {
            conditions.append("c.rating >= ?")
            arguments.append(minRating)
        }

        if let colorLabels, !colorLabels.isEmpty {
            let placeholders = colorLabels.map { _ in "?" }.joined(separator: ", ")
            conditions.append("c.color_label IN (\(placeholders))")
            arguments.append(contentsOf: colorLabels)
        }

        if let shotTypes, !shotTypes.isEmpty {
            let placeholders = shotTypes.map { _ in "?" }.joined(separator: ", ")
            conditions.append("c.shot_type IN (\(placeholders))")
            arguments.append(contentsOf: shotTypes)
        }

        if let moods, !moods.isEmpty {
            let placeholders = moods.map { _ in "?" }.joined(separator: ", ")
            conditions.append("c.mood IN (\(placeholders))")
            arguments.append(contentsOf: moods)
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

        // ORDER BY（白名单校验防 SQL 注入）
        let orderColumn: String
        switch sortBy {
        case "start_time": orderColumn = "c.start_time"
        case "rating": orderColumn = "c.rating DESC, c.clip_id"
        default: orderColumn = "c.clip_id"
        }

        // 绑定为 let 满足 Sendable 闭包要求
        let finalOffset = offset
        let finalLimit = limit
        let finalWhereClause = whereClause
        let finalOrderColumn = orderColumn
        let finalArguments = arguments

        let (total, rows) = try await context.globalDB.read { db -> (Int, [Row]) in
            let countSQL = "SELECT COUNT(*) FROM clips c \(finalWhereClause)"
            let total = try Int.fetchOne(db, sql: countSQL, arguments: StatementArguments(finalArguments)) ?? 0

            let dataSQL = """
                SELECT c.clip_id, c.source_folder, c.source_clip_id, c.video_id,
                       v.file_name, v.file_path,
                       c.start_time, c.end_time,
                       c.scene, c.description, c.subjects, c.actions, c.objects,
                       c.mood, c.shot_type, c.lighting, c.colors,
                       c.tags, c.user_tags, c.transcript,
                       c.rating, c.color_label
                FROM clips c
                LEFT JOIN videos v ON v.video_id = c.video_id
                \(finalWhereClause)
                ORDER BY \(finalOrderColumn)
                LIMIT ? OFFSET ?
                """

            var dataArgs = finalArguments
            dataArgs.append(finalLimit)
            dataArgs.append(finalOffset)

            let rows = try Row.fetchAll(db, sql: dataSQL, arguments: StatementArguments(dataArgs))
            return (total, rows)
        }

        // 构造输出
        let clips = rows.map { row -> ClipItem in
            ClipItem(
                clipId: row["clip_id"] as Int64? ?? 0,
                sourceFolder: row["source_folder"] as String? ?? "",
                fileName: row["file_name"] as String?,
                filePath: row["file_path"] as String?,
                startTime: row["start_time"] as Double? ?? 0,
                endTime: row["end_time"] as Double? ?? 0,
                scene: row["scene"] as String?,
                description: row["description"] as String?,
                subjects: TagParsingHelpers.parseTagsFromGlobalDB(row["subjects"] as String?),
                actions: TagParsingHelpers.parseTagsFromGlobalDB(row["actions"] as String?),
                objects: TagParsingHelpers.parseTagsFromGlobalDB(row["objects"] as String?),
                mood: row["mood"] as String?,
                shotType: row["shot_type"] as String?,
                lighting: row["lighting"] as String?,
                colors: TagParsingHelpers.parseTagsFromGlobalDB(row["colors"] as String?),
                tags: TagParsingHelpers.parseTagsFromGlobalDB(row["tags"] as String?),
                userTags: TagParsingHelpers.parseTagsFromGlobalDB(row["user_tags"] as String?),
                transcript: row["transcript"] as String?,
                rating: row["rating"] as Int? ?? 0,
                colorLabel: row["color_label"] as String?
            )
        }

        let result = BrowseResult(
            total: total,
            returned: clips.count,
            offset: offset,
            limit: limit,
            clips: clips
        )

        let json = try ParamHelpers.toJSON(result)
        return CallTool.Result(content: [.text(json)])
    }
}

// MARK: - Output Types

private struct BrowseResult: Codable {
    let total: Int
    let returned: Int
    let offset: Int
    let limit: Int
    let clips: [ClipItem]
}

private struct ClipItem: Codable {
    let clipId: Int64
    let sourceFolder: String
    let fileName: String?
    let filePath: String?
    let startTime: Double
    let endTime: Double
    let scene: String?
    let description: String?
    let subjects: [String]
    let actions: [String]
    let objects: [String]
    let mood: String?
    let shotType: String?
    let lighting: String?
    let colors: [String]
    let tags: [String]
    let userTags: [String]
    let transcript: String?
    let rating: Int
    let colorLabel: String?
}
