import Foundation
import MCP
import GRDB
import FindItCore

/// 获取视频的完整信息及其所有片段
enum GetVideoDetailTool {

    static func execute(params: CallTool.Parameters, context: DatabaseContext) throws -> CallTool.Result {
        let videoPath = try ParamHelpers.requireString(params, key: "video_path")
        let folder = ParamHelpers.optionalString(params, key: "folder")

        // 自动检测文件夹路径
        let folderPath: String
        if let f = folder {
            folderPath = f
        } else if let detected = detectFolderPath(from: videoPath) {
            folderPath = detected
        } else {
            return CallTool.Result(
                content: [.text("Error: cannot detect folder for \(videoPath), please provide 'folder' parameter")],
                isError: true
            )
        }

        let folderDB = try context.folderDB(for: folderPath)

        struct VideoOutput: Codable {
            let videoId: Int64
            let fileName: String
            let filePath: String
            let duration: Double?
            let fileSize: Int64?
            let indexStatus: String
            let indexError: String?
            let srtPath: String?
            let clips: [ClipSummary]
        }

        struct ClipSummary: Codable {
            let clipId: Int64
            let startTime: Double
            let endTime: Double
            let scene: String?
            let description: String?
            let subjects: [String]?
            let actions: [String]?
            let objects: [String]?
            let transcript: String?
            let tags: [String]
            let userTags: [String]
            let mood: String?
            let shotType: String?
            let lighting: String?
            let colors: [String]?
            let rating: Int
            let colorLabel: String?
        }

        guard let video: Video = try folderDB.read({ db in
            try Video.fetchByPath(db, path: videoPath)
        }) else {
            return CallTool.Result(
                content: [.text("Error: video not found at \(videoPath)")],
                isError: true
            )
        }

        let clips: [Clip] = try folderDB.read { db in
            try Clip
                .filter(Column("video_id") == video.videoId)
                .order(Column("start_time"))
                .fetchAll(db)
        }

        let output = VideoOutput(
            videoId: video.videoId ?? 0,
            fileName: video.fileName,
            filePath: video.filePath,
            duration: video.duration,
            fileSize: video.fileSize,
            indexStatus: video.indexStatus,
            indexError: video.indexError,
            srtPath: video.srtPath,
            clips: clips.map {
                ClipSummary(
                    clipId: $0.clipId ?? 0,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    scene: $0.scene,
                    description: $0.clipDescription,
                    subjects: parseJSONArray($0.subjects),
                    actions: parseJSONArray($0.actions),
                    objects: parseJSONArray($0.objects),
                    transcript: $0.transcript,
                    tags: $0.tagsArray,
                    userTags: $0.userTagsArray,
                    mood: $0.mood,
                    shotType: $0.shotType,
                    lighting: $0.lighting,
                    colors: parseJSONArray($0.colors),
                    rating: $0.rating,
                    colorLabel: $0.colorLabel
                )
            }
        )

        let json = try ParamHelpers.toJSON(output)
        return CallTool.Result(content: [.text(json)])
    }

    /// 解析 JSON 数组字符串为 [String]?
    private static func parseJSONArray(_ str: String?) -> [String]? {
        guard let str, !str.isEmpty,
              let data = str.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return nil
        }
        return arr.isEmpty ? nil : arr
    }

    /// 从视频路径自动检测文件夹库路径
    ///
    /// 向上遍历目录树，查找包含 `.clip-index/index.sqlite` 的文件夹。
    private static func detectFolderPath(from videoPath: String) -> String? {
        var dir = (videoPath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        while dir != "/" && !dir.isEmpty {
            let indexPath = (dir as NSString)
                .appendingPathComponent(".clip-index")
                .appending("/index.sqlite")
            if fm.fileExists(atPath: indexPath) {
                return dir
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }
}
