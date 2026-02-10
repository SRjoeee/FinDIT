import Foundation
import MCP
import GRDB
import FindItCore

/// 给视频片段添加用户标签
enum AddTagsTool {

    static func execute(params: CallTool.Parameters, context: DatabaseContext) throws -> CallTool.Result {
        let clipId = try ParamHelpers.requireInt(params, key: "clip_id")
        let folder = try ParamHelpers.requireString(params, key: "folder")
        let tags = try ParamHelpers.requireStringArray(params, key: "tags")

        guard !tags.isEmpty else {
            return CallTool.Result(
                content: [.text("Error: tags array must not be empty")],
                isError: true
            )
        }

        let folderDB = try context.folderDB(for: folder)

        try folderDB.write { db in
            guard try Clip.filter(Column("clip_id") == Int64(clipId)).fetchOne(db) != nil else {
                throw MCPError.invalidParams("clip_id=\(clipId) not found")
            }
            try TagManager.addTags(db, clipId: Int64(clipId), tags: tags)
        }

        let current = try folderDB.read { db in
            try TagManager.fetchUserTags(db, clipId: Int64(clipId))
        }

        struct Output: Codable {
            let clipId: Int
            let addedTags: [String]
            let currentTags: [String]
        }
        let json = try ParamHelpers.toJSON(Output(
            clipId: clipId,
            addedTags: tags,
            currentTags: current
        ))
        return CallTool.Result(content: [.text(json)])
    }
}
