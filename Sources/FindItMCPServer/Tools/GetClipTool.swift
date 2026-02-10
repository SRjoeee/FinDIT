import Foundation
import MCP
import GRDB
import FindItCore

/// 获取单个 clip 的完整元数据
enum GetClipTool {

    static func execute(params: CallTool.Parameters, context: DatabaseContext) throws -> CallTool.Result {
        let clipId = try ParamHelpers.requireInt(params, key: "clip_id")
        let folder = try ParamHelpers.requireString(params, key: "folder")

        let folderDB = try context.folderDB(for: folder)

        struct ClipDetail: Codable {
            let clipId: Int64
            let videoId: Int64?
            let startTime: Double
            let endTime: Double
            let scene: String?
            let subjects: String?
            let actions: String?
            let objects: String?
            let mood: String?
            let shotType: String?
            let lighting: String?
            let colors: String?
            let description: String?
            let tags: [String]
            let userTags: [String]
            let transcript: String?
            let rating: Int
            let colorLabel: String?
        }

        guard let clip: Clip = try folderDB.read({ db in
            try Clip.filter(Column("clip_id") == Int64(clipId)).fetchOne(db)
        }) else {
            return CallTool.Result(
                content: [.text("Error: clip_id=\(clipId) not found in folder \(folder)")],
                isError: true
            )
        }

        let detail = ClipDetail(
            clipId: clip.clipId ?? 0,
            videoId: clip.videoId,
            startTime: clip.startTime,
            endTime: clip.endTime,
            scene: clip.scene,
            subjects: clip.subjects,
            actions: clip.actions,
            objects: clip.objects,
            mood: clip.mood,
            shotType: clip.shotType,
            lighting: clip.lighting,
            colors: clip.colors,
            description: clip.clipDescription,
            tags: clip.tagsArray,
            userTags: clip.userTagsArray,
            transcript: clip.transcript,
            rating: clip.rating,
            colorLabel: clip.colorLabel
        )

        let json = try ParamHelpers.toJSON(detail)
        return CallTool.Result(content: [.text(json)])
    }
}
