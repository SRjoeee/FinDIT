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

    /// 每批同步的最大记录数（控制内存峰值）
    static let batchSize = 500

    /// 从文件夹库增量同步到全局搜索索引
    ///
    /// 使用分批处理（每批 500 条），避免大量记录一次加载到内存。
    ///
    /// - Parameters:
    ///   - folderPath: 文件夹路径（用于 source_folder 标识和 sync_meta 追踪）
    ///   - folderDB: 文件夹级数据库连接（只读）
    ///   - globalDB: 全局搜索索引数据库连接（读写）
    ///   - force: 强制全量同步（忽略增量游标，重新同步所有记录）。
    ///            适用于已有记录被更新（如 embedding 填充）但 rowid 未变的情况。
    /// - Returns: 同步结果（同步的 video/clip 条数）
    public static func sync(
        folderPath: String,
        folderDB: DatabaseReader,
        globalDB: DatabaseWriter,
        force: Bool = false
    ) throws -> SyncResult {
        // 1. 从全局库读取该文件夹的同步进度
        let meta = try globalDB.read { db in
            try Row.fetchOne(db, sql: """
                SELECT last_synced_video_rowid, last_synced_clip_rowid
                FROM sync_meta WHERE folder_path = ?
                """, arguments: [folderPath])
        }
        var currentVideoRowId: Int64 = force ? 0 : (meta?["last_synced_video_rowid"] ?? 0)
        var currentClipRowId: Int64 = force ? 0 : (meta?["last_synced_clip_rowid"] ?? 0)

        var totalSyncedVideos = 0
        var totalSyncedClips = 0

        // 2. 分批同步 videos
        while true {
            let batch = try folderDB.read { db in
                try Video.fetchAfterRowId(db, rowId: currentVideoRowId, limit: batchSize)
            }
            guard !batch.isEmpty else { break }

            try globalDB.write { db in
                for video in batch {
                    try db.execute(sql: """
                        INSERT INTO videos
                            (source_folder, source_video_id, file_path, file_name, duration, file_size, srt_path)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(source_folder, source_video_id) DO UPDATE SET
                            file_path = excluded.file_path,
                            file_name = excluded.file_name,
                            duration = excluded.duration,
                            file_size = excluded.file_size,
                            srt_path = excluded.srt_path
                        """, arguments: [
                            folderPath, video.videoId,
                            video.filePath, video.fileName,
                            video.duration, video.fileSize, video.srtPath
                        ])
                    if let vid = video.videoId, vid > currentVideoRowId {
                        currentVideoRowId = vid
                    }
                }
            }
            totalSyncedVideos += batch.count

            if batch.count < batchSize { break }
        }

        // 3. 分批同步 clips
        while true {
            let batch = try folderDB.read { db in
                try Clip.fetchAfterRowId(db, rowId: currentClipRowId, limit: batchSize)
            }
            guard !batch.isEmpty else { break }

            // 动态生成 vision 列名和 SQL（循环外构建一次）
            let visionCols = VisionField.sqlColumnNames()
            let allCols = ["source_folder", "source_clip_id", "video_id",
                           "start_time", "end_time", "thumbnail_path"]
                + visionCols
                + ["tags", "transcript", "embedding", "embedding_model"]
            let placeholders = allCols.map { _ in "?" }.joined(separator: ", ")
            let conflictSet = (["video_id", "start_time", "end_time", "thumbnail_path"]
                + visionCols
                + ["tags", "transcript", "embedding", "embedding_model"])
                .map { "\($0) = excluded.\($0)" }
                .joined(separator: ",\n                            ")
            let clipSQL = """
                INSERT INTO clips
                    (\(allCols.joined(separator: ", ")))
                VALUES (\(placeholders))
                ON CONFLICT(source_folder, source_clip_id) DO UPDATE SET
                    \(conflictSet)
                """
            let activeFields = VisionField.allActive

            try globalDB.write { db in
                for clip in batch {
                    let globalVideoId = try Int64.fetchOne(db, sql: """
                        SELECT video_id FROM videos
                        WHERE source_folder = ? AND source_video_id = ?
                        """, arguments: [folderPath, clip.videoId])

                    let tagsForFTS = convertTagsForFTS(clip.tags)

                    var args: [DatabaseValueConvertible?] = []
                    args.append(folderPath)
                    args.append(clip.clipId)
                    args.append(globalVideoId)
                    args.append(clip.startTime)
                    args.append(clip.endTime)
                    args.append(clip.thumbnailPath)
                    for field in activeFields {
                        args.append(clip.visionValue(for: field))
                    }
                    args.append(tagsForFTS)
                    args.append(clip.transcript)
                    args.append(clip.embedding)
                    args.append(clip.embeddingModel)

                    try db.execute(sql: clipSQL, arguments: StatementArguments(args))
                    if let cid = clip.clipId, cid > currentClipRowId {
                        currentClipRowId = cid
                    }
                }
            }
            totalSyncedClips += batch.count

            if batch.count < batchSize { break }
        }

        // 4. 更新同步进度（仅在有数据同步时）
        if totalSyncedVideos > 0 || totalSyncedClips > 0 {
            try globalDB.write { db in
                try db.execute(sql: """
                    INSERT INTO sync_meta (folder_path, last_synced_video_rowid, last_synced_clip_rowid, last_synced_at)
                    VALUES (?, ?, ?, datetime('now'))
                    ON CONFLICT(folder_path) DO UPDATE SET
                        last_synced_video_rowid = excluded.last_synced_video_rowid,
                        last_synced_clip_rowid = excluded.last_synced_clip_rowid,
                        last_synced_at = excluded.last_synced_at
                    """, arguments: [folderPath, currentVideoRowId, currentClipRowId])
            }
        }

        return SyncResult(syncedVideos: totalSyncedVideos, syncedClips: totalSyncedClips)
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
