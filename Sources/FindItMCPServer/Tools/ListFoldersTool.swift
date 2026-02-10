import Foundation
import MCP
import GRDB
import FindItCore

/// 列出所有已索引的素材文件夹
enum ListFoldersTool {

    static func execute(params: CallTool.Parameters, context: DatabaseContext) throws -> CallTool.Result {
        struct FolderInfo: Codable {
            let folderPath: String
            let videoCount: Int
            let clipCount: Int
        }

        let folders: [FolderInfo] = try context.globalDB.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    v.source_folder,
                    COUNT(DISTINCT v.video_id) AS video_count,
                    COUNT(c.clip_id) AS clip_count
                FROM videos v
                LEFT JOIN clips c ON c.video_id = v.video_id
                GROUP BY v.source_folder
                ORDER BY v.source_folder
                """)
            return rows.map {
                FolderInfo(
                    folderPath: $0["source_folder"],
                    videoCount: $0["video_count"],
                    clipCount: $0["clip_count"]
                )
            }
        }

        let json = try ParamHelpers.toJSON(folders)
        return CallTool.Result(content: [.text(json)])
    }
}
