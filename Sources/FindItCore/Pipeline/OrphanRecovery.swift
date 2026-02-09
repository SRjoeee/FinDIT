import Foundation
import GRDB

/// Orphaned 视频记录管理（软删除 + Hash 恢复 + 定时清理）
///
/// 文件消失时标记为 orphaned（保留索引数据），
/// 文件重现时通过 fileHash 匹配恢复，过期后才真正清理。
public enum OrphanRecovery {

    // MARK: - Result Types

    /// 软删除结果
    public struct MarkResult: Sendable {
        /// 标记为 orphaned 的视频数
        public let markedCount: Int
        /// 从全局库删除的 clips 数
        public let globalClipsRemoved: Int
    }

    /// 恢复结果
    public struct RecoveryResult: Sendable {
        /// 恢复的视频 ID
        public let recoveredVideoId: Int64
        /// 该视频关联的 clips 数
        public let clipCount: Int
    }

    /// 清理结果
    public struct CleanupResult: Sendable {
        /// 硬删除的过期记录数
        public let removedCount: Int
    }

    // MARK: - Mark Orphaned

    /// 将单个视频标记为 orphaned（软删除）
    ///
    /// 文件夹库: UPDATE status='orphaned', orphaned_at=now
    /// 全局库: DELETE clips + videos（搜索不可见）
    /// 文件系统: 保留缩略图和 SRT（恢复时复用）
    ///
    /// - Returns: MarkResult（markedCount=1）, nil 表示未找到该视频
    @discardableResult
    public static func markOrphaned(
        videoPath: String,
        folderPath: String,
        folderDB: DatabaseWriter,
        globalDB: DatabaseWriter? = nil
    ) throws -> MarkResult? {
        // 1. 查找视频记录
        guard let video = try folderDB.read({ db in
            try Video.fetchByPath(db, path: videoPath)
        }) else {
            return nil
        }

        guard let videoId = video.videoId else { return nil }

        // 2. 文件夹库: 标记为 orphaned
        let now = Clip.sqliteDatetime()
        try folderDB.write { db in
            try db.execute(
                sql: """
                    UPDATE videos
                    SET index_status = 'orphaned', orphaned_at = ?
                    WHERE video_id = ?
                    """,
                arguments: [now, videoId]
            )
        }

        // 3. 全局库: 删除（搜索不可见）
        var globalClips = 0
        if let globalDB = globalDB {
            globalClips = try cleanGlobalRecords(
                folderPath: folderPath,
                sourceVideoId: videoId,
                globalDB: globalDB
            )
        }

        return MarkResult(markedCount: 1, globalClipsRemoved: globalClips)
    }

    /// 批量标记为 orphaned
    @discardableResult
    public static func markOrphanedBatch(
        videoPaths: [String],
        folderPath: String,
        folderDB: DatabaseWriter,
        globalDB: DatabaseWriter? = nil
    ) throws -> MarkResult {
        var totalMarked = 0
        var totalGlobalClips = 0

        for path in videoPaths {
            do {
                if let result = try markOrphaned(
                    videoPath: path,
                    folderPath: folderPath,
                    folderDB: folderDB,
                    globalDB: globalDB
                ) {
                    totalMarked += result.markedCount
                    totalGlobalClips += result.globalClipsRemoved
                }
            } catch {
                print("[OrphanRecovery] 标记失败: \(path) - \(error)")
            }
        }

        return MarkResult(
            markedCount: totalMarked,
            globalClipsRemoved: totalGlobalClips
        )
    }

    // MARK: - Recovery

    /// 尝试通过 fileHash 恢复 orphaned 记录
    ///
    /// 查询文件夹库中 hash 匹配的最新 orphaned 记录，
    /// 若匹配则更新路径/状态，并删除 processVideo 创建的重复 pending 记录。
    ///
    /// - Parameters:
    ///   - fileHash: 新发现文件的 hash
    ///   - newVideoPath: 新文件路径
    ///   - pendingVideoId: registerVideo 创建的 pending 记录 ID（将被删除）
    ///   - folderDB: 文件夹级数据库连接
    /// - Returns: RecoveryResult, nil 表示无匹配
    public static func attemptRecovery(
        fileHash: String,
        newVideoPath: String,
        pendingVideoId: Int64,
        folderDB: DatabaseWriter
    ) throws -> RecoveryResult? {
        // 1. 查找匹配的 orphaned 记录（取最近的）
        guard let orphaned = try folderDB.read({ db in
            try Row.fetchOne(db, sql: """
                SELECT video_id FROM videos
                WHERE file_hash = ? AND index_status = 'orphaned'
                ORDER BY orphaned_at DESC LIMIT 1
                """, arguments: [fileHash])
        }) else {
            return nil
        }

        let orphanedVideoId: Int64 = orphaned["video_id"]

        // 不恢复自身
        if orphanedVideoId == pendingVideoId { return nil }

        // 2. 获取文件信息
        let newFileName = (newVideoPath as NSString).lastPathComponent
        let attrs = try? FileManager.default.attributesOfItem(atPath: newVideoPath)
        let newFileSize = attrs?[.size] as? Int64
        let newFileMtime = (attrs?[.modificationDate] as? Date)
            .map { Clip.sqliteDatetime($0) }

        // 3. 先删 pending（释放 file_path UNIQUE 约束），再恢复 orphaned
        try folderDB.write { db in
            try db.execute(
                sql: "DELETE FROM videos WHERE video_id = ?",
                arguments: [pendingVideoId]
            )

            try db.execute(
                sql: """
                    UPDATE videos
                    SET file_path = ?, file_name = ?, file_size = ?,
                        file_modified = ?, index_status = 'completed',
                        orphaned_at = NULL
                    WHERE video_id = ?
                    """,
                arguments: [newVideoPath, newFileName, newFileSize,
                            newFileMtime, orphanedVideoId]
            )
        }

        // 5. 统计关联 clips
        let clipCount = try folderDB.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM clips WHERE video_id = ?
                """, arguments: [orphanedVideoId]) ?? 0
        }

        return RecoveryResult(
            recoveredVideoId: orphanedVideoId,
            clipCount: clipCount
        )
    }

    // MARK: - Cleanup

    /// 清理过期 orphaned 记录
    ///
    /// 硬删除 orphaned_at 超过 retentionDays 的视频及其 clips，
    /// 并清理关联的缩略图目录和 SRT 文件。
    /// 文件 I/O 在 GRDB write 事务之外执行。
    public static func cleanupExpired(
        retentionDays: Int,
        folderPath: String,
        folderDB: DatabaseWriter
    ) throws -> CleanupResult {
        guard retentionDays > 0 else {
            return CleanupResult(removedCount: 0)
        }

        // 计算截止日期
        let cutoffDate = Calendar.current.date(
            byAdding: .day, value: -retentionDays, to: Date()
        )!
        let cutoff = Clip.sqliteDatetime(cutoffDate)

        // 1. 读取过期记录（在事务外收集文件路径）
        struct ExpiredVideo {
            let videoId: Int64
            let srtPath: String?
        }

        let expired: [ExpiredVideo] = try folderDB.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT video_id, srt_path FROM videos
                WHERE index_status = 'orphaned' AND orphaned_at < ?
                """, arguments: [cutoff])
            return rows.map {
                ExpiredVideo(videoId: $0["video_id"], srtPath: $0["srt_path"])
            }
        }

        guard !expired.isEmpty else {
            return CleanupResult(removedCount: 0)
        }

        // 2. 硬删除数据库记录（CASCADE 自动删除 clips）
        try folderDB.write { db in
            for record in expired {
                try db.execute(
                    sql: "DELETE FROM videos WHERE video_id = ?",
                    arguments: [record.videoId]
                )
            }
        }

        // 3. 清理文件系统（事务外，失败不影响数据库操作）
        let fm = FileManager.default
        for record in expired {
            // 缩略图目录
            let thumbDir = PipelineManager.thumbnailDirectory(
                folderPath: folderPath, videoId: record.videoId
            )
            try? fm.removeItem(atPath: thumbDir)

            // SRT 文件（仅 App Support 下的降级路径）
            if let srtPath = record.srtPath {
                let videoDir = (srtPath as NSString).deletingLastPathComponent
                let appSupport = NSSearchPathForDirectoriesInDomains(
                    .applicationSupportDirectory, .userDomainMask, true
                ).first ?? ""
                if videoDir.hasPrefix(appSupport) {
                    try? fm.removeItem(atPath: srtPath)
                }
            }
        }

        return CleanupResult(removedCount: expired.count)
    }

    // MARK: - Private

    /// 从全局库删除指定视频的 clips 和 video 记录
    @discardableResult
    private static func cleanGlobalRecords(
        folderPath: String,
        sourceVideoId: Int64,
        globalDB: DatabaseWriter
    ) throws -> Int {
        try globalDB.write { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT video_id FROM videos
                WHERE source_folder = ? AND source_video_id = ?
                """, arguments: [folderPath, sourceVideoId])

            guard let globalVideoId: Int64 = row?["video_id"] else { return 0 }

            // 删除 clips（FTS5 触发器自动更新索引）
            try db.execute(
                sql: "DELETE FROM clips WHERE video_id = ?",
                arguments: [globalVideoId]
            )
            let clipsRemoved = db.changesCount

            // 删除 video
            try db.execute(
                sql: "DELETE FROM videos WHERE video_id = ?",
                arguments: [globalVideoId]
            )

            return clipsRemoved
        }
    }
}
