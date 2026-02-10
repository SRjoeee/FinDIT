import Foundation
import MCP
import GRDB
import FindItCore

/// 获取数据库综合统计
enum GetStatsTool {

    static func execute(params: CallTool.Parameters, context: DatabaseContext) throws -> CallTool.Result {
        struct Stats: Codable {
            let totalFolders: Int
            let totalVideos: Int
            let totalClips: Int
            let totalDurationSeconds: Double
            let embeddingCoverage: Double
            let transcriptCoverage: Double
            let descriptionCoverage: Double
        }

        let stats: Stats = try context.globalDB.read { db in
            let folderCount = try Int.fetchOne(db, sql:
                "SELECT COUNT(DISTINCT source_folder) FROM videos") ?? 0
            let videoCount = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM videos") ?? 0
            let clipCount = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM clips") ?? 0
            let totalDuration = try Double.fetchOne(db, sql:
                "SELECT COALESCE(SUM(end_time - start_time), 0) FROM clips") ?? 0

            // 覆盖率统计
            let withEmbedding = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM clips WHERE embedding IS NOT NULL") ?? 0
            let withTranscript = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM clips WHERE transcript IS NOT NULL AND transcript != ''") ?? 0
            let withDescription = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM clips WHERE description IS NOT NULL AND description != ''") ?? 0

            let embCov = clipCount > 0 ? Double(withEmbedding) / Double(clipCount) : 0
            let trsCov = clipCount > 0 ? Double(withTranscript) / Double(clipCount) : 0
            let desCov = clipCount > 0 ? Double(withDescription) / Double(clipCount) : 0

            return Stats(
                totalFolders: folderCount,
                totalVideos: videoCount,
                totalClips: clipCount,
                totalDurationSeconds: totalDuration,
                embeddingCoverage: (embCov * 1000).rounded() / 1000,
                transcriptCoverage: (trsCov * 1000).rounded() / 1000,
                descriptionCoverage: (desCov * 1000).rounded() / 1000
            )
        }

        let json = try ParamHelpers.toJSON(stats)
        return CallTool.Result(content: [.text(json)])
    }
}
