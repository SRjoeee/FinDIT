import Foundation
import MCP
import GRDB
import FindItCore

/// 设置视频片段的颜色标签
enum SetColorLabelTool {

    static func execute(params: CallTool.Parameters, context: DatabaseContext) throws -> CallTool.Result {
        let clipId = try ParamHelpers.requireInt(params, key: "clip_id")
        let folder = try ParamHelpers.requireString(params, key: "folder")
        let colorStr = try ParamHelpers.requireString(params, key: "color")

        let label: ColorLabel?
        if colorStr.lowercased() == "none" {
            label = nil
        } else {
            guard let parsed = ColorLabel(rawValue: colorStr.lowercased()) else {
                return CallTool.Result(
                    content: [.text("Error: invalid color '\(colorStr)'. Valid: red, orange, yellow, green, blue, purple, gray, none")],
                    isError: true
                )
            }
            label = parsed
        }

        let folderDB = try context.folderDB(for: folder)

        try folderDB.write { db in
            guard try Clip.filter(Column("clip_id") == Int64(clipId)).fetchOne(db) != nil else {
                throw MCPError.invalidParams("clip_id=\(clipId) not found")
            }
            try ClipLabel.updateColorLabel(db, clipId: Int64(clipId), label: label)
        }

        struct Output: Codable {
            let clipId: Int
            let colorLabel: String?
        }
        let json = try ParamHelpers.toJSON(Output(clipId: clipId, colorLabel: label?.rawValue))
        return CallTool.Result(content: [.text(json)])
    }
}
