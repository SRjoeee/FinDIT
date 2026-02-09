import GRDB

/// 便携索引路径重定向工具
///
/// 当文件夹被移动到新路径后重新添加到 App 时，
/// 检测并修复文件夹级数据库中的所有绝对路径引用。
/// 确保跨机器/路径变更场景下索引数据的可复用性。
///
/// SQL 前缀替换模式复用自 `VolumeMonitor.updateFolderPath()`，
/// 使用 `? || substr(col, length(?) + 1)` 保证 Unicode 安全。
public enum PathRebaser {

    /// 路径重定向结果
    public struct RebaseResult: Sendable, Equatable {
        /// 旧文件夹路径（迁移前）
        public let oldPath: String
        /// 新文件夹路径（迁移后）
        public let newPath: String
        /// 重定向的视频记录数
        public let rebasedVideos: Int
        /// 重定向的片段记录数
        public let rebasedClips: Int
        /// 是否实际执行了重定向
        public let didRebase: Bool
    }

    // MARK: - 公开 API

    /// 检测文件夹级数据库是否需要路径重定向
    ///
    /// 读取 `watched_folders` 表中的第一条记录，
    /// 如果其 `folder_path` 与当前新路径不一致，则需要重定向。
    ///
    /// - Parameters:
    ///   - folderDB: 文件夹级数据库连接
    ///   - newPath: 当前文件夹的实际路径
    /// - Returns: 旧路径（如需重定向），`nil` 表示路径一致或无记录
    public static func detectMismatch(
        folderDB: DatabaseReader,
        newPath: String
    ) throws -> String? {
        let normalizedNew = normalize(newPath)

        let storedPath: String? = try folderDB.read { db in
            try String.fetchOne(db, sql:
                "SELECT folder_path FROM watched_folders ORDER BY folder_id LIMIT 1")
        }

        guard let stored = storedPath else { return nil }

        let normalizedStored = normalize(stored)
        return normalizedStored != normalizedNew ? normalizedStored : nil
    }

    /// 执行路径重定向（单事务原子操作）
    ///
    /// 在文件夹级数据库中将所有绝对路径从旧前缀替换为新前缀：
    /// - `watched_folders.folder_path`
    /// - `videos.file_path`（所有以 oldPath 开头的）
    /// - `videos.srt_path`（仅以 oldPath 开头的，`~/Library` 路径跳过）
    /// - `clips.thumbnail_path`（所有以 oldPath 开头的）
    ///
    /// - Parameters:
    ///   - folderDB: 文件夹级数据库连接
    ///   - oldPath: 旧文件夹路径前缀
    ///   - newPath: 新文件夹路径前缀
    /// - Returns: 重定向结果
    public static func rebase(
        folderDB: DatabaseWriter,
        oldPath: String,
        newPath: String
    ) throws -> RebaseResult {
        let normalizedOld = normalize(oldPath)
        let normalizedNew = normalize(newPath)

        guard normalizedOld != normalizedNew else {
            return RebaseResult(
                oldPath: normalizedOld,
                newPath: normalizedNew,
                rebasedVideos: 0,
                rebasedClips: 0,
                didRebase: false
            )
        }

        var rebasedVideos = 0
        var rebasedClips = 0

        try folderDB.write { db in
            // 1. watched_folders.folder_path
            try db.execute(sql: """
                UPDATE watched_folders SET folder_path = ?
                WHERE folder_path = ?
                """, arguments: [normalizedNew, normalizedOld])

            // 2. videos.file_path（前缀替换）
            try db.execute(sql: """
                UPDATE videos SET file_path = ? || substr(file_path, length(?) + 1)
                WHERE file_path LIKE ? || '%'
                """, arguments: [normalizedNew, normalizedOld, normalizedOld])
            rebasedVideos = db.changesCount

            // 3. videos.srt_path（仅文件夹内路径，跳过 ~/Library 的 fallback）
            try db.execute(sql: """
                UPDATE videos SET srt_path = ? || substr(srt_path, length(?) + 1)
                WHERE srt_path LIKE ? || '%'
                """, arguments: [normalizedNew, normalizedOld, normalizedOld])

            // 4. clips.thumbnail_path（前缀替换）
            try db.execute(sql: """
                UPDATE clips SET thumbnail_path = ? || substr(thumbnail_path, length(?) + 1)
                WHERE thumbnail_path LIKE ? || '%'
                """, arguments: [normalizedNew, normalizedOld, normalizedOld])
            rebasedClips = db.changesCount
        }

        print("[PathRebaser] 路径重定向: \(normalizedOld) → \(normalizedNew) " +
              "(videos: \(rebasedVideos), clips: \(rebasedClips))")

        return RebaseResult(
            oldPath: normalizedOld,
            newPath: normalizedNew,
            rebasedVideos: rebasedVideos,
            rebasedClips: rebasedClips,
            didRebase: true
        )
    }

    /// 检测并自动重定向（便利方法）
    ///
    /// 组合 `detectMismatch` + `rebase`。
    /// 如果路径一致，返回 `didRebase=false` 的结果。
    ///
    /// - Parameters:
    ///   - folderDB: 文件夹级数据库连接
    ///   - newPath: 当前文件夹的实际路径
    /// - Returns: 重定向结果
    public static func rebaseIfNeeded(
        folderDB: DatabaseWriter,
        newPath: String
    ) throws -> RebaseResult {
        let normalizedNew = normalize(newPath)

        guard let oldPath = try detectMismatch(folderDB: folderDB, newPath: normalizedNew) else {
            return RebaseResult(
                oldPath: normalizedNew,
                newPath: normalizedNew,
                rebasedVideos: 0,
                rebasedClips: 0,
                didRebase: false
            )
        }

        return try rebase(folderDB: folderDB, oldPath: oldPath, newPath: normalizedNew)
    }

    // MARK: - 内部工具

    /// 路径规范化：移除尾部斜杠
    static func normalize(_ path: String) -> String {
        var p = path
        while p.hasSuffix("/") && p.count > 1 {
            p.removeLast()
        }
        return p
    }
}
