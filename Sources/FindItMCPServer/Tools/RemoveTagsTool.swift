import Foundation
import MCP
import GRDB
import FindItCore

/// 移除视频片段的指定用户标签
enum RemoveTagsTool {

    static func execute(params: CallTool.Parameters, context: DatabaseContext) throws -> CallTool.Result {
        let clipId = try ParamHelpers.requireInt(params, key: "clip_id")
        let folder = try ParamHelpers.requireString(params, key: "folder")
        let tags = try ParamHelpers.requireStringArray(params, key: "tags")

        let folderDB = try context.folderDB(for: folder)

        try folderDB.write { db in
            guard try Clip.filter(Column("clip_id") == Int64(clipId)).fetchOne(db) != nil else {
                throw MCPError.invalidParams("clip_id=\(clipId) not found")
            }
            try TagManager.removeTags(db, clipId: Int64(clipId), tags: tags)
        }

        let current = try folderDB.read { db in
            try TagManager.fetchUserTags(db, clipId: Int64(clipId))
        }

        struct Output: Codable {
            let clipId: Int
            let removedTags: [String]
            let currentTags: [String]
        }
        let json = try ParamHelpers.toJSON(Output(
            clipId: clipId,
            removedTags: tags,
            currentTags: current
        ))
        return CallTool.Result(content: [.text(json)])
    }
}
