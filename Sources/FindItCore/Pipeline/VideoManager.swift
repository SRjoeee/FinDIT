import Foundation
import GRDB

/// 视频记录管理（删除 + 清理）
///
/// 负责从文件夹库和全局库中删除视频记录，
/// 并清理关联的缩略图目录和 SRT 文件。
public enum VideoManager {

    /// 删除结果
    public struct RemovalResult: Sendable {
        /// 从文件夹库删除的视频数
        public let removedFromFolder: Int
        /// 从全局库删除的 clips 数
        public let removedGlobalClips: Int
    }

    /// 删除单个视频及其所有关联数据
    ///
    /// 执行顺序:
    /// 1. 在文件夹库中查找视频记录
    /// 2. 从全局库删除对应的 clips 和 videos 记录
    /// 3. 从文件夹库删除视频记录（clips 通过 ON DELETE CASCADE 自动删除）
    /// 4. 清理缩略图目录
    /// 5. 清理 SRT 文件（仅当 SRT 不在视频同目录时）
    ///
    /// - Parameters:
    ///   - videoPath: 被删除的视频文件绝对路径
    ///   - folderPath: 所属监控文件夹路径
    ///   - folderDB: 文件夹级数据库连接
    ///   - globalDB: 全局搜索索引连接（nil 时跳过全局库清理）
    /// - Returns: true 表示找到并删除了视频记录，false 表示未找到
    @discardableResult
    public static func removeVideo(
        videoPath: String,
        folderPath: String,
        folderDB: DatabaseWriter,
        globalDB: DatabaseWriter? = nil
    ) throws -> Bool {
        // 1. 查找视频记录
        guard let video = try folderDB.read({ db in
            try Video.fetchByPath(db, path: videoPath)
        }) else {
            return false
        }

        guard let videoId = video.videoId else { return false }

        // 2. 全局库清理
        if let globalDB = globalDB {
            try cleanGlobalRecords(
                folderPath: folderPath,
                sourceVideoId: videoId,
                globalDB: globalDB
            )
        }

        // 3. 文件夹库删除（CASCADE 自动删除 clips）
        try folderDB.write { db in
            try db.execute(
                sql: "DELETE FROM videos WHERE video_id = ?",
                arguments: [videoId]
            )
        }

        // 4. 清理缩略图目录
        let thumbDir = PipelineManager.thumbnailDirectory(
            folderPath: folderPath, videoId: videoId
        )
        try? FileManager.default.removeItem(atPath: thumbDir)

        // 5. 清理 SRT 文件（仅 App Support 下的降级路径）
        if let srtPath = video.srtPath,
           !srtPath.hasPrefix((videoPath as NSString).deletingLastPathComponent) {
            try? FileManager.default.removeItem(atPath: srtPath)
        }

        return true
    }

    /// 批量删除多个视频及其关联数据
    ///
    /// 对每个视频路径执行 `removeVideo()`，返回成功删除的数量。
    /// 单个视频删除失败不影响其余视频。
    ///
    /// - Parameters:
    ///   - videoPaths: 被删除的视频文件路径列表
    ///   - folderPath: 所属监控文件夹路径
    ///   - folderDB: 文件夹级数据库连接
    ///   - globalDB: 全局搜索索引连接（nil 时跳过全局库清理）
    /// - Returns: 成功删除的视频数量
    @discardableResult
    public static func removeVideos(
        videoPaths: [String],
        folderPath: String,
        folderDB: DatabaseWriter,
        globalDB: DatabaseWriter? = nil
    ) throws -> Int {
        var count = 0
        for path in videoPaths {
            do {
                if try removeVideo(
                    videoPath: path,
                    folderPath: folderPath,
                    folderDB: folderDB,
                    globalDB: globalDB
                ) {
                    count += 1
                }
            } catch {
                print("[VideoManager] 删除失败: \(path) - \(error)")
            }
        }
        return count
    }

    // MARK: - Private

    /// 从全局库删除指定视频的 clips 和 video 记录
    private static func cleanGlobalRecords(
        folderPath: String,
        sourceVideoId: Int64,
        globalDB: DatabaseWriter
    ) throws {
        try globalDB.write { db in
            // 先查 global video_id
            let row = try Row.fetchOne(db, sql: """
                SELECT video_id FROM videos
                WHERE source_folder = ? AND source_video_id = ?
                """, arguments: [folderPath, sourceVideoId])

            guard let globalVideoId: Int64 = row?["video_id"] else { return }

            // 删除 clips（FTS5 触发器自动更新索引）
            try db.execute(
                sql: "DELETE FROM clips WHERE video_id = ?",
                arguments: [globalVideoId]
            )

            // 删除 video
            try db.execute(
                sql: "DELETE FROM videos WHERE video_id = ?",
                arguments: [globalVideoId]
            )
        }
    }
}
