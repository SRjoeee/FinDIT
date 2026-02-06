import Foundation
import GRDB

/// 文件夹库 → 全局搜索索引同步引擎
///
/// 从指定文件夹的索引数据库中读取新增 videos 和 clips，
/// 写入全局搜索索引。使用 `sync_meta` 表跟踪每个文件夹
/// 的同步进度，实现增量同步。
///
/// 同步过程中会将 tags 从 JSON 数组格式转为空格分隔文本（ADR-010），
/// 便于 FTS5 全文搜索。
public enum SyncEngine {

    /// 同步结果
    public struct SyncResult {
        /// 本次同步的视频数
        public let syncedVideos: Int
        /// 本次同步的片段数
        public let syncedClips: Int
    }

    /// 从文件夹库增量同步到全局搜索索引
    ///
    /// - Parameters:
    ///   - folderPath: 文件夹路径（用于 source_folder 标识和 sync_meta 追踪）
    ///   - folderDB: 文件夹级数据库连接（只读）
    ///   - globalDB: 全局搜索索引数据库连接（读写）
    /// - Returns: 同步结果（新增的 video/clip 条数）
    public static func sync(
        folderPath: String,
        folderDB: DatabaseReader,
        globalDB: DatabaseWriter
    ) throws -> SyncResult {
        // 1. 从全局库读取该文件夹的同步进度
        let meta = try globalDB.read { db in
            try Row.fetchOne(db, sql: """
                SELECT last_synced_video_rowid, last_synced_clip_rowid
                FROM sync_meta WHERE folder_path = ?
                """, arguments: [folderPath])
        }
        let lastVideoRowId: Int64 = meta?["last_synced_video_rowid"] ?? 0
        let lastClipRowId: Int64 = meta?["last_synced_clip_rowid"] ?? 0

        // 2. 从文件夹库读取新增数据
        let newVideos = try folderDB.read { db in
            try Video.fetchAfterRowId(db, rowId: lastVideoRowId, limit: 10000)
        }
        let newClips = try folderDB.read { db in
            try Clip.fetchAfterRowId(db, rowId: lastClipRowId, limit: 10000)
        }

        // 无新数据则跳过
        guard !newVideos.isEmpty || !newClips.isEmpty else {
            return SyncResult(syncedVideos: 0, syncedClips: 0)
        }

        // 3. 写入全局库
        var maxVideoRowId = lastVideoRowId
        var maxClipRowId = lastClipRowId

        try globalDB.write { db in
            // 同步 videos
            for video in newVideos {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO videos
                        (source_folder, source_video_id, file_path, file_name, duration, file_size, srt_path)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        folderPath, video.videoId,
                        video.filePath, video.fileName,
                        video.duration, video.fileSize, video.srtPath
                    ])
                if let vid = video.videoId, vid > maxVideoRowId {
                    maxVideoRowId = vid
                }
            }

            // 同步 clips
            for clip in newClips {
                // 查找对应的全局 video_id
                let globalVideoId = try Int64.fetchOne(db, sql: """
                    SELECT video_id FROM videos
                    WHERE source_folder = ? AND source_video_id = ?
                    """, arguments: [folderPath, clip.videoId])

                // tags: JSON 数组 → 空格分隔文本 (ADR-010)
                let tagsForFTS = convertTagsForFTS(clip.tags)

                try db.execute(sql: """
                    INSERT OR IGNORE INTO clips
                        (source_folder, source_clip_id, video_id, start_time, end_time,
                         thumbnail_path, scene, subjects, actions, objects,
                         mood, shot_type, lighting, colors,
                         description, tags, transcript, embedding)
                    VALUES (?, ?, ?, ?, ?,
                            ?, ?, ?, ?, ?,
                            ?, ?, ?, ?,
                            ?, ?, ?, ?)
                    """, arguments: [
                        folderPath, clip.clipId, globalVideoId,
                        clip.startTime, clip.endTime,
                        clip.thumbnailPath, clip.scene, clip.subjects, clip.actions, clip.objects,
                        clip.mood, clip.shotType, clip.lighting, clip.colors,
                        clip.clipDescription, tagsForFTS, clip.transcript, clip.embedding
                    ])
                if let cid = clip.clipId, cid > maxClipRowId {
                    maxClipRowId = cid
                }
            }

            // 4. 更新同步进度
            try db.execute(sql: """
                INSERT INTO sync_meta (folder_path, last_synced_video_rowid, last_synced_clip_rowid, last_synced_at)
                VALUES (?, ?, ?, datetime('now'))
                ON CONFLICT(folder_path) DO UPDATE SET
                    last_synced_video_rowid = excluded.last_synced_video_rowid,
                    last_synced_clip_rowid = excluded.last_synced_clip_rowid,
                    last_synced_at = excluded.last_synced_at
                """, arguments: [folderPath, maxVideoRowId, maxClipRowId])
        }

        return SyncResult(syncedVideos: newVideos.count, syncedClips: newClips.count)
    }

    /// 删除全局库中指定文件夹的所有同步数据
    ///
    /// 用于文件夹被移除时清理全局库。
    public static func removeFolderData(folderPath: String, from globalDB: DatabaseWriter) throws {
        try globalDB.write { db in
            try db.execute(sql: "DELETE FROM clips WHERE source_folder = ?", arguments: [folderPath])
            try db.execute(sql: "DELETE FROM videos WHERE source_folder = ?", arguments: [folderPath])
            try db.execute(sql: "DELETE FROM sync_meta WHERE folder_path = ?", arguments: [folderPath])
        }
    }

    // MARK: - Private

    /// 将 tags 从 JSON 数组格式转为空格分隔文本
    ///
    /// 输入: `["海滩","户外","全景"]`
    /// 输出: `海滩 户外 全景`
    ///
    /// 如果输入不是有效 JSON 数组，原样返回。
    static func convertTagsForFTS(_ tags: String?) -> String? {
        guard let tags = tags,
              let data = tags.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return tags
        }
        return array.joined(separator: " ")
    }
}
