import Foundation
import GRDB

/// 搜索引擎
///
/// 提供 FTS5 全文搜索和向量语义搜索的混合搜索能力。
/// 支持多种搜索模式和自适应权重调整（ADR-009 / PRODUCT_SPEC 4.3）。
public enum SearchEngine {

    // MARK: - 搜索模式

    /// 搜索模式
    public enum SearchMode: String, CaseIterable {
        /// 纯 FTS5 关键词搜索
        case fts
        /// 纯向量语义搜索
        case vector
        /// 混合搜索（FTS5 + 向量融合）
        case hybrid
        /// 自适应（引号→FTS优先，长句→向量优先）
        case auto
    }

    /// 搜索权重配置
    public struct SearchWeights: Sendable {
        /// FTS5 分数权重
        public var ftsWeight: Double
        /// 向量相似度权重
        public var vectorWeight: Double

        /// 默认权重：语义优先
        public static let `default` = SearchWeights(ftsWeight: 0.4, vectorWeight: 0.6)
        /// 精确匹配优先（引号搜索）
        public static let exactMatch = SearchWeights(ftsWeight: 0.9, vectorWeight: 0.1)
        /// 语义主导（长描述性查询）
        public static let semantic = SearchWeights(ftsWeight: 0.2, vectorWeight: 0.8)
    }

    // MARK: - 搜索结果

    /// 搜索结果
    public struct SearchResult: Sendable {
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
        /// 缩略图文件路径
        public let thumbnailPath: String?
        /// FTS5 BM25 排名分数（越小越相关，负数）
        public let rank: Double
        /// 向量余弦相似度（0-1，越大越相似）
        public let similarity: Double?
        /// 融合后的最终得分（0-1，越大越相关）
        public let finalScore: Double?
    }

    // MARK: - FTS5 搜索

    /// FTS5 全文搜索
    ///
    /// 在全局搜索索引中搜索匹配的片段。支持 FTS5 查询语法：
    /// - 关键词：`海滩 日落`（隐式 AND）
    /// - 前缀匹配：`海滩*`
    /// - 精确短语：`"海滩日落"`
    /// - 排除：`海滩 NOT 雨天`
    /// - 列过滤：`tags:海滩`
    public static func search(_ db: Database, query: String, limit: Int = 50) throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let rows = try Row.fetchAll(db, sql: """
            SELECT c.clip_id, c.source_folder, c.source_clip_id, c.video_id,
                   v.file_path, v.file_name,
                   c.start_time, c.end_time, c.scene, c.description,
                   c.tags, c.transcript, c.thumbnail_path,
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
                thumbnailPath: row["thumbnail_path"],
                rank: row["rank"],
                similarity: nil,
                finalScore: nil
            )
        }
    }

    // MARK: - 混合搜索

    /// 混合搜索入口
    ///
    /// 结合 FTS5 关键词搜索和向量语义搜索，通过融合排序返回最相关结果。
    ///
    /// - Parameters:
    ///   - db: 全局库数据库连接
    ///   - query: 搜索关键词
    ///   - queryEmbedding: 查询文本的嵌入向量（nil = 退化为纯 FTS5）
    ///   - embeddingModel: 嵌入模型名称（只匹配此模型的向量）
    ///   - vectorStoreResults: VectorStore 预计算的 (clipId, similarity) 对（nil = 回退逐行扫描）
    ///   - mode: 搜索模式
    ///   - limit: 最大返回条数
    /// - Returns: 按融合得分排序的搜索结果
    public static func hybridSearch(
        _ db: Database,
        query: String,
        queryEmbedding: [Float]? = nil,
        embeddingModel: String? = nil,
        vectorStoreResults: [(clipId: Int64, similarity: Float)]? = nil,
        mode: SearchMode = .auto,
        limit: Int = 50
    ) throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 根据模式决定权重
        let weights = resolveWeights(query: trimmed, mode: mode, hasEmbedding: queryEmbedding != nil)

        // 纯向量模式
        if mode == .vector || (mode == .auto && weights.ftsWeight == 0) {
            if let storeResults = vectorStoreResults {
                return try vectorSearchFromStore(db, storeResults: storeResults, limit: limit)
            }
            guard let embedding = queryEmbedding, let model = embeddingModel else {
                return [] // 无向量时返回空
            }
            return try vectorSearch(db, queryEmbedding: embedding, embeddingModel: model, limit: limit)
        }

        // 纯 FTS 模式或无向量
        if mode == .fts || queryEmbedding == nil {
            return try search(db, query: trimmed, limit: limit)
        }

        // 混合模式
        guard let embedding = queryEmbedding, let model = embeddingModel else {
            return try search(db, query: trimmed, limit: limit)
        }

        return try fusionSearch(
            db,
            query: trimmed,
            queryEmbedding: embedding,
            embeddingModel: model,
            vectorStoreResults: vectorStoreResults,
            weights: weights,
            limit: limit
        )
    }

    // MARK: - 向量搜索

    /// 纯向量搜索
    ///
    /// 加载所有匹配 embeddingModel 的 clips，计算余弦相似度排序。
    static func vectorSearch(
        _ db: Database,
        queryEmbedding: [Float],
        embeddingModel: String,
        limit: Int = 50
    ) throws -> [SearchResult] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT c.clip_id, c.source_folder, c.source_clip_id, c.video_id,
                   v.file_path, v.file_name,
                   c.start_time, c.end_time, c.scene, c.description,
                   c.tags, c.transcript, c.thumbnail_path, c.embedding
            FROM clips c
            LEFT JOIN videos v ON v.video_id = c.video_id
            WHERE c.embedding IS NOT NULL AND c.embedding_model = ?
            """, arguments: [embeddingModel])

        var results: [(SearchResult, Double)] = []

        for row in rows {
            guard let embeddingData = row["embedding"] as? Data else { continue }
            let clipEmbedding = EmbeddingUtils.deserializeEmbedding(embeddingData)
            let similarity = Double(EmbeddingUtils.cosineSimilarity(queryEmbedding, clipEmbedding))

            let result = SearchResult(
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
                thumbnailPath: row["thumbnail_path"],
                rank: 0.0,
                similarity: similarity,
                finalScore: similarity
            )
            results.append((result, similarity))
        }

        // 按相似度降序排列（同分时按 clipId 升序保证稳定性）
        results.sort { $0.1 > $1.1 || ($0.1 == $1.1 && $0.0.clipId < $1.0.clipId) }
        return Array(results.prefix(limit).map { $0.0 })
    }

    // MARK: - VectorStore 加速搜索

    /// 从 VectorStore 预计算结果构建 SearchResult
    ///
    /// VectorStore 只返回 (clipId, similarity)，此方法从数据库查询元数据补全。
    static func vectorSearchFromStore(
        _ db: Database,
        storeResults: [(clipId: Int64, similarity: Float)],
        limit: Int = 50
    ) throws -> [SearchResult] {
        guard !storeResults.isEmpty else { return [] }

        let topK = Array(storeResults.prefix(limit))
        let similarities = Dictionary(uniqueKeysWithValues: topK.map { ($0.clipId, Double($0.similarity)) })
        let clipIds = topK.map { $0.clipId }

        // 查询元数据
        let placeholders = clipIds.map { _ in "?" }.joined(separator: ", ")
        var args = StatementArguments()
        for id in clipIds { args += [id] }

        let rows = try Row.fetchAll(db, sql: """
            SELECT c.clip_id, c.source_folder, c.source_clip_id, c.video_id,
                   v.file_path, v.file_name,
                   c.start_time, c.end_time, c.scene, c.description,
                   c.tags, c.transcript, c.thumbnail_path
            FROM clips c
            LEFT JOIN videos v ON v.video_id = c.video_id
            WHERE c.clip_id IN (\(placeholders))
            """, arguments: args)

        // 构建结果并按相似度排序
        var results: [SearchResult] = []
        for row in rows {
            let clipId: Int64 = row["clip_id"]
            let sim = similarities[clipId] ?? 0.0
            results.append(SearchResult(
                clipId: clipId,
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
                thumbnailPath: row["thumbnail_path"],
                rank: 0.0,
                similarity: sim,
                finalScore: sim
            ))
        }

        results.sort { ($0.similarity ?? 0) > ($1.similarity ?? 0) }
        return results
    }

    // MARK: - 融合搜索

    /// FTS5 + 向量融合搜索
    static func fusionSearch(
        _ db: Database,
        query: String,
        queryEmbedding: [Float],
        embeddingModel: String,
        vectorStoreResults: [(clipId: Int64, similarity: Float)]? = nil,
        weights: SearchWeights,
        limit: Int
    ) throws -> [SearchResult] {
        // 1. FTS5 搜索
        let ftsResults = try search(db, query: query, limit: limit * 2)

        // 2. 向量搜索（VectorStore 加速或逐行扫描回退）
        let vectorResults: [SearchResult]
        if let storeResults = vectorStoreResults {
            vectorResults = try vectorSearchFromStore(db, storeResults: storeResults, limit: limit * 2)
        } else {
            vectorResults = try vectorSearch(
                db, queryEmbedding: queryEmbedding,
                embeddingModel: embeddingModel, limit: limit * 2
            )
        }

        // 3. 构建 clipId → 数据映射
        var ftsScores: [Int64: Double] = [:]
        var vectorScores: [Int64: Double] = [:]
        var resultData: [Int64: SearchResult] = [:]

        for result in ftsResults {
            ftsScores[result.clipId] = result.rank
            resultData[result.clipId] = result
        }
        for result in vectorResults {
            vectorScores[result.clipId] = result.similarity ?? 0.0
            if resultData[result.clipId] == nil {
                resultData[result.clipId] = result
            }
        }

        // 4. 归一化（直接对 key-value 就地计算，不依赖 Dictionary 迭代顺序）
        // FTS5 rank 是负数（越小越好），取反后做 min-max 归一化
        let normalizedFTSMap: [Int64: Double]
        if let rawMax = ftsScores.values.max(), let rawMin = ftsScores.values.min() {
            let negatedMin = -rawMax  // 取反后最小值
            let negatedMax = -rawMin  // 取反后最大值
            let range = negatedMax - negatedMin
            if range > 0 {
                normalizedFTSMap = ftsScores.mapValues { (-$0 - negatedMin) / range }
            } else {
                normalizedFTSMap = ftsScores.mapValues { _ in 0.0 }
            }
        } else {
            normalizedFTSMap = [:]
        }

        // 向量相似度已在 [0, 1] 范围，但仍归一化以确保一致性
        let normalizedVecMap: [Int64: Double]
        if let vecMin = vectorScores.values.min(), let vecMax = vectorScores.values.max() {
            let range = vecMax - vecMin
            if range > 0 {
                normalizedVecMap = vectorScores.mapValues { ($0 - vecMin) / range }
            } else {
                normalizedVecMap = vectorScores.mapValues { _ in 0.0 }
            }
        } else {
            normalizedVecMap = [:]
        }

        // 5. 融合排序
        let allClipIds = Set(ftsScores.keys).union(vectorScores.keys)
        var fusedResults: [(SearchResult, Double)] = []

        for clipId in allClipIds {
            guard let data = resultData[clipId] else { continue }

            let ftsNorm = normalizedFTSMap[clipId] ?? 0.0
            let vecNorm = normalizedVecMap[clipId] ?? 0.0
            let finalScore = weights.ftsWeight * ftsNorm + weights.vectorWeight * vecNorm

            let merged = SearchResult(
                clipId: data.clipId,
                sourceFolder: data.sourceFolder,
                sourceClipId: data.sourceClipId,
                videoId: data.videoId,
                filePath: data.filePath,
                fileName: data.fileName,
                startTime: data.startTime,
                endTime: data.endTime,
                scene: data.scene,
                clipDescription: data.clipDescription,
                tags: data.tags,
                transcript: data.transcript,
                thumbnailPath: data.thumbnailPath,
                rank: ftsScores[clipId] ?? 0.0,
                similarity: vectorScores[clipId],
                finalScore: finalScore
            )
            fusedResults.append((merged, finalScore))
        }

        // 按融合得分降序（同分时按 clipId 升序保证稳定性）
        fusedResults.sort { $0.1 > $1.1 || ($0.1 == $1.1 && $0.0.clipId < $1.0.clipId) }
        return Array(fusedResults.prefix(limit).map { $0.0 })
    }

    // MARK: - 权重解析

    /// 根据搜索模式和查询内容解析权重
    ///
    /// 自适应规则（PRODUCT_SPEC 4.3）：
    /// - 带引号：α=0.9, β=0.1（精确匹配优先）
    /// - 长句（CJK >5字 / 其他 >10字）：α=0.2, β=0.8（语义主导）
    /// - 默认：α=0.4, β=0.6（语义优先）
    static func resolveWeights(query: String, mode: SearchMode, hasEmbedding: Bool) -> SearchWeights {
        switch mode {
        case .fts:
            return SearchWeights(ftsWeight: 1.0, vectorWeight: 0.0)
        case .vector:
            return SearchWeights(ftsWeight: 0.0, vectorWeight: 1.0)
        case .hybrid:
            return .default
        case .auto:
            if !hasEmbedding {
                return SearchWeights(ftsWeight: 1.0, vectorWeight: 0.0)
            }
            // 引号精确搜索
            if query.contains("\"") {
                return .exactMatch
            }
            // 长描述性语句：CJK 字符语义密度高，用较低阈值
            let threshold = containsCJK(query) ? 5 : 10
            if query.count > threshold {
                return .semantic
            }
            return .default
        }
    }

    /// 检测字符串是否包含 CJK（中日韩）字符
    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // CJK Unified Ideographs + Extension A/B + CJK Compatibility
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3400...0x4DBF).contains(scalar.value) ||
            // Hiragana + Katakana
            (0x3040...0x30FF).contains(scalar.value) ||
            // Hangul Syllables
            (0xAC00...0xD7AF).contains(scalar.value)
        }
    }

    // MARK: - 文件夹统计

    /// 文件夹统计信息
    public struct FolderStats: Sendable {
        /// 视频文件数
        public let videoCount: Int
        /// 片段数
        public let clipCount: Int
    }

    /// 查询指定文件夹在全局库中的视频和片段统计
    ///
    /// - Parameters:
    ///   - db: 全局搜索索引数据库连接
    ///   - folderPath: 文件夹路径（对应 `clips.source_folder`）
    /// - Returns: 视频数和片段数
    public static func folderStats(_ db: Database, folderPath: String) throws -> FolderStats {
        let row = try Row.fetchOne(db, sql: """
            SELECT COUNT(DISTINCT video_id) AS video_count,
                   COUNT(*) AS clip_count
            FROM clips
            WHERE source_folder = ?
            """, arguments: [folderPath])

        return FolderStats(
            videoCount: row?["video_count"] ?? 0,
            clipCount: row?["clip_count"] ?? 0
        )
    }

    // MARK: - 搜索历史

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
