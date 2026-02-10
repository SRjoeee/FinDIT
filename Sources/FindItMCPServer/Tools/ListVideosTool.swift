import Foundation
import MCP
import GRDB
import FindItCore

/// 列出指定文件夹中的视频
enum ListVideosTool {

    static func execute(params: CallTool.Parameters, context: DatabaseContext) throws -> CallTool.Result {
        let folder = try ParamHelpers.requireString(params, key: "folder")
        let status = ParamHelpers.optionalString(params, key: "status")

        let folderDB = try context.folderDB(for: folder)

        struct VideoInfo: Codable {
            let videoId: Int64
            let fileName: String
            let filePath: String
            let duration: Double?
            let fileSize: Int64?
            let indexStatus: String
            let clipCount: Int
        }

        let videos: [VideoInfo] = try folderDB.read { db in
            let allVideos: [Video]
            if let status = status {
                allVideos = try Video.fetchByStatus(db, status: status)
            } else {
                allVideos = try Video
                    .order(Column("video_id"))
                    .fetchAll(db)
            }

            return try allVideos.map { video in
                let clipCount = try Int.fetchOne(db, sql:
                    "SELECT COUNT(*) FROM clips WHERE video_id = ?",
                    arguments: [video.videoId]) ?? 0
                return VideoInfo(
                    videoId: video.videoId ?? 0,
                    fileName: video.fileName,
                    filePath: video.filePath,
                    duration: video.duration,
                    fileSize: video.fileSize,
                    indexStatus: video.indexStatus,
                    clipCount: clipCount
                )
            }
        }

        let json = try ParamHelpers.toJSON(videos)
        return CallTool.Result(content: [.text(json)])
    }
}
