import Foundation
import MCP
import GRDB
import FindItCore

/// 设置视频片段的星级评分
enum SetRatingTool {

    static func execute(params: CallTool.Parameters, context: DatabaseContext) throws -> CallTool.Result {
        let clipId = try ParamHelpers.requireInt(params, key: "clip_id")
        let folder = try ParamHelpers.requireString(params, key: "folder")
        let rating = try ParamHelpers.requireInt(params, key: "rating")

        guard (0...5).contains(rating) else {
            return CallTool.Result(
                content: [.text("Error: rating must be 0-5 (0 clears rating)")],
                isError: true
            )
        }

        let folderDB = try context.folderDB(for: folder)

        try folderDB.write { db in
            guard try Clip.filter(Column("clip_id") == Int64(clipId)).fetchOne(db) != nil else {
                throw MCPError.invalidParams("clip_id=\(clipId) not found")
            }
            try ClipLabel.updateRating(db, clipId: Int64(clipId), rating: rating)
        }

        struct Output: Codable {
            let clipId: Int
            let rating: Int
        }
        let json = try ParamHelpers.toJSON(Output(clipId: clipId, rating: rating))
        return CallTool.Result(content: [.text(json)])
    }
}
