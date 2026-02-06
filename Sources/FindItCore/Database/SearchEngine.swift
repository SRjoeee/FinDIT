import Foundation
import GRDB

/// FTS5 全文搜索引擎
///
/// 操作全局搜索索引数据库，提供基于 FTS5 的关键词搜索。
/// 支持 FTS5 查询语法：关键词、前缀匹配（`term*`）、
/// 精确短语（`"exact phrase"`）、排除（`NOT term`）。
///
/// 后续 Stage 将加入向量语义搜索和融合排序（ADR-009）。
public enum SearchEngine {

    /// 搜索结果
    public struct SearchResult {
        /// 全局库 clip_id
        public let clipId: Int64
        /// 来源文件夹路径
        public let sourceFolder: String
        /// 文件夹库中的原始 clip_id
        public let sourceClipId: Int64
        /// 全局库 video_id
        public let videoId: Int64?
        /// 视频文件路径
        public let filePath: String?
        /// 视频文件名
        public let fileName: String?
        /// 片段起始时间（秒）
        public let startTime: Double
        /// 片段结束时间（秒）
        public let endTime: Double
        /// 场景描述
        public let scene: String?
        /// 自然语言描述
        public let clipDescription: String?
        /// 标签
        public let tags: String?
        /// 转录文本
        public let transcript: String?
        /// FTS5 BM25 排名分数（越小越相关，负数）
        public let rank: Double
    }

    /// FTS5 全文搜索
    ///
    /// 在全局搜索索引中搜索匹配的片段。支持 FTS5 查询语法：
    /// - 关键词：`海滩 日落`（隐式 AND）
    /// - 前缀匹配：`海滩*`
    /// - 精确短语：`"海滩日落"`
    /// - 排除：`海滩 NOT 雨天`
    /// - 列过滤：`tags:海滩`
    ///
    /// - Parameters:
    ///   - db: 全局库数据库连接
    ///   - query: 搜索关键词（FTS5 语法）
    ///   - limit: 最大返回条数
    /// - Returns: 按相关度排序的搜索结果
    public static func search(_ db: Database, query: String, limit: Int = 50) throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let rows = try Row.fetchAll(db, sql: """
            SELECT c.clip_id, c.source_folder, c.source_clip_id, c.video_id,
                   v.file_path, v.file_name,
                   c.start_time, c.end_time, c.scene, c.description,
                   c.tags, c.transcript,
                   clips_fts.rank
            FROM clips_fts
            JOIN clips c ON c.clip_id = clips_fts.rowid
            LEFT JOIN videos v ON v.video_id = c.video_id
            WHERE clips_fts MATCH ?
            ORDER BY clips_fts.rank
            LIMIT ?
            """, arguments: [trimmed, limit])

        return rows.map { row in
            SearchResult(
                clipId: row["clip_id"],
                sourceFolder: row["source_folder"],
                sourceClipId: row["source_clip_id"],
                videoId: row["video_id"],
                filePath: row["file_path"],
                fileName: row["file_name"],
                startTime: row["start_time"],
                endTime: row["end_time"],
                scene: row["scene"],
                clipDescription: row["description"],
                tags: row["tags"],
                transcript: row["transcript"],
                rank: row["rank"]
            )
        }
    }

    /// 记录搜索历史
    public static func recordSearch(_ db: Database, query: String, resultCount: Int) throws {
        try db.execute(
            sql: "INSERT INTO search_history (query, result_count) VALUES (?, ?)",
            arguments: [query, resultCount]
        )
    }

    /// 获取最近的搜索历史
    public static func recentSearches(_ db: Database, limit: Int = 20) throws -> [(query: String, searchedAt: String, resultCount: Int)] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT query, searched_at, result_count
            FROM search_history
            ORDER BY id DESC
            LIMIT ?
            """, arguments: [limit])

        return rows.map { row in
            (query: row["query"] as String,
             searchedAt: row["searched_at"] as String,
             resultCount: row["result_count"] as Int)
        }
    }
}
