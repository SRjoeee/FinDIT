import Foundation
import MCP
import GRDB
import FindItCore

/// 获取素材库综合概览
///
/// 提供文件夹分布、镜头类型/情绪/评分/颜色标签的分面统计，
/// 让 AI 在搜索前快速了解库的全貌。
///
/// 复用 `FilterEngine.availableFacets()` 获取分面数据。
enum GetLibrarySummaryTool {

    static func execute(params: CallTool.Parameters, context: DatabaseContext) async throws -> CallTool.Result {
        let summary = try await context.globalDB.read { db -> LibrarySummary in
            // 基础统计
            let totalFolders = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT source_folder) FROM videos") ?? 0
            let totalVideos = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM videos") ?? 0
            let totalClips = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips") ?? 0
            let totalDuration = try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(end_time - start_time), 0) FROM clips") ?? 0

            // 文件夹分布
            let folderRows = try Row.fetchAll(db, sql: """
                SELECT source_folder,
                       COUNT(DISTINCT video_id) as video_count,
                       COUNT(*) as clip_count,
                       COALESCE(SUM(end_time - start_time), 0) as total_duration
                FROM clips
                GROUP BY source_folder
                ORDER BY clip_count DESC
                """)

            let folders = folderRows.map { row in
                FolderSummary(
                    path: row["source_folder"] as String? ?? "",
                    videoCount: row["video_count"] as Int? ?? 0,
                    clipCount: row["clip_count"] as Int? ?? 0,
                    totalDurationSeconds: row["total_duration"] as Double? ?? 0
                )
            }

            // 分面统计（复用 FilterEngine）
            let facets = try FilterEngine.availableFacets(db)

            return LibrarySummary(
                totalFolders: totalFolders,
                totalVideos: totalVideos,
                totalClips: totalClips,
                totalDurationSeconds: totalDuration,
                folders: folders,
                shotTypes: facets.shotTypes.map { FacetItem(value: $0.value, count: $0.count) },
                moods: facets.moods.map { FacetItem(value: $0.value, count: $0.count) },
                ratingDistribution: facets.ratingCounts,
                colorLabels: facets.colorLabelCounts.map { FacetItem(value: $0.value.rawValue, count: $0.count) }
            )
        }

        let json = try ParamHelpers.toJSON(summary)
        return CallTool.Result(content: [.text(json)])
    }
}

// MARK: - Output Types

private struct LibrarySummary: Codable {
    let totalFolders: Int
    let totalVideos: Int
    let totalClips: Int
    let totalDurationSeconds: Double
    let folders: [FolderSummary]
    let shotTypes: [FacetItem]
    let moods: [FacetItem]
    let ratingDistribution: [Int: Int]
    let colorLabels: [FacetItem]
}

private struct FolderSummary: Codable {
    let path: String
    let videoCount: Int
    let clipCount: Int
    let totalDurationSeconds: Double
}

private struct FacetItem: Codable {
    let value: String
    let count: Int
}
