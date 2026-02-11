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

    /// 搜索权重配置（三路融合）
    ///
    /// 三路权重: CLIP 视觉相似度 + FTS5 关键词 + 文本嵌入语义。
    /// 权重之和应为 1.0，但不强制（内部会按比例使用）。
    public struct SearchWeights: Sendable, Equatable {
        /// CLIP 视觉相似度权重（SigLIP2 跨模态搜索）
        public var clipWeight: Double
        /// FTS5 关键词匹配权重
        public var ftsWeight: Double
        /// 文本嵌入语义相似度权重
        public var textEmbWeight: Double

        /// 向后兼容：旧 vectorWeight 映射到 textEmbWeight
        public var vectorWeight: Double { textEmbWeight }

        public init(clipWeight: Double, ftsWeight: Double, textEmbWeight: Double) {
            self.clipWeight = clipWeight
            self.ftsWeight = ftsWeight
            self.textEmbWeight = textEmbWeight
        }

        /// 向后兼容的二路构造器（clipWeight = 0）
        public init(ftsWeight: Double, vectorWeight: Double) {
            self.clipWeight = 0.0
            self.ftsWeight = ftsWeight
            self.textEmbWeight = vectorWeight
        }

        /// 默认三路权重: CLIP 主导 + FTS5 + 文本嵌入
        public static let `default` = SearchWeights(clipWeight: 0.5, ftsWeight: 0.2, textEmbWeight: 0.3)
        /// 精确匹配优先（引号搜索）
        public static let exactMatch = SearchWeights(clipWeight: 0.1, ftsWeight: 0.8, textEmbWeight: 0.1)
        /// 语义主导（长描述性查询）
        public static let semantic = SearchWeights(clipWeight: 0.6, ftsWeight: 0.1, textEmbWeight: 0.3)

        /// 仅 CLIP（以图搜视频）
        public static let clipOnly = SearchWeights(clipWeight: 1.0, ftsWeight: 0.0, textEmbWeight: 0.0)
        /// 仅 FTS5（纯关键词）
        public static let ftsOnly = SearchWeights(clipWeight: 0.0, ftsWeight: 1.0, textEmbWeight: 0.0)
        /// 仅文本嵌入
        public static let textEmbOnly = SearchWeights(clipWeight: 0.0, ftsWeight: 0.0, textEmbWeight: 1.0)

        /// 二路回退: 无 CLIP 时 (FTS5 + TextEmb)
        public static let twoWayNoClip = SearchWeights(clipWeight: 0.0, ftsWeight: 0.4, textEmbWeight: 0.6)
        /// 二路回退: 无 TextEmb 时 (CLIP + FTS5)
        public static let twoWayNoTextEmb = SearchWeights(clipWeight: 0.7, ftsWeight: 0.3, textEmbWeight: 0.0)
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
        /// 主体（JSON 数组字符串）
        public let subjects: String?
        /// 动作（JSON 数组字符串）
        public let actions: String?
        /// 物体（JSON 数组字符串）
        public let objects: String?
        /// 标签
        public let tags: String?
        /// 转录文本
        public let transcript: String?
        /// 缩略图文件路径
        public let thumbnailPath: String?
        /// 用户自定义标签
        public let userTags: String?
        /// 星级评分 (0-5, 0=未评分)
        public var rating: Int
        /// 颜色标签
        public var colorLabel: String?
        /// 镜头类型
        public let shotType: String?
        /// 情绪/氛围
        public let mood: String?
        /// 光线条件
        public let lighting: String?
        /// 主色调（JSON 数组字符串）
        public let colors: String?
        /// FTS5 BM25 排名分数（越小越相关，负数）
        public let rank: Double
        /// 向量余弦相似度（0-1，越大越相似）
        public let similarity: Double?
        /// 融合后的最终得分（0-1，越大越相关）
        public let finalScore: Double?

        /// 从 GRDB Row 构造 SearchResult（统一字段映射）
        ///
        /// 集中 20+ 字段的 Row→SearchResult 映射，避免在每个搜索方法中重复构造。
        /// SQL 查询的列名约定：clip_id, source_folder, source_clip_id, video_id,
        /// file_path, file_name, start_time, end_time, scene, description,
        /// subjects, actions, objects, tags, transcript, thumbnail_path,
        /// user_tags, rating, color_label, shot_type, mood, lighting, colors
        static func from(
            row: Row,
            rank: Double = 0.0,
            similarity: Double? = nil,
            finalScore: Double? = nil
        ) -> SearchResult {
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
                subjects: row["subjects"],
                actions: row["actions"],
                objects: row["objects"],
                tags: row["tags"],
                transcript: row["transcript"],
                thumbnailPath: row["thumbnail_path"],
                userTags: row["user_tags"],
                rating: row["rating"] ?? 0,
                colorLabel: row["color_label"],
                shotType: row["shot_type"],
                mood: row["mood"],
                lighting: row["lighting"],
                colors: row["colors"],
                rank: rank,
                similarity: similarity,
                finalScore: finalScore
            )
        }

        /// 复制当前结果并更新分数（用于 threeWaySearch 融合）
        func withScores(
            rank: Double,
            similarity: Double?,
            finalScore: Double?
        ) -> SearchResult {
            SearchResult(
                clipId: clipId,
                sourceFolder: sourceFolder,
                sourceClipId: sourceClipId,
                videoId: videoId,
                filePath: filePath,
                fileName: fileName,
                startTime: startTime,
                endTime: endTime,
                scene: scene,
                clipDescription: clipDescription,
                subjects: subjects,
                actions: actions,
                objects: objects,
                tags: tags,
                transcript: transcript,
                thumbnailPath: thumbnailPath,
                userTags: userTags,
                rating: rating,
                colorLabel: colorLabel,
                shotType: shotType,
                mood: mood,
                lighting: lighting,
                colors: colors,
                rank: rank,
                similarity: similarity,
                finalScore: finalScore
            )
        }
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
    public static func search(
        _ db: Database,
        query: String,
        folderPaths: Set<String>? = nil,
        pathPrefixFilter: String? = nil,
        limit: Int = 50
    ) throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let filterSQL = folderFilterSQL(folderPaths: folderPaths)
        let prefixSQL = pathPrefixFilterSQL(pathPrefixFilter)
        var args = StatementArguments()
        args += [trimmed]
        appendFolderArgs(&args, folderPaths: folderPaths)
        appendPrefixArgs(&args, pathPrefixFilter: pathPrefixFilter)
        args += [limit]

        // bm25() 列权重（对应 FTS5 列顺序）:
        //   tags(10), description(5), transcript(3), user_tags(8),
        //   scene(4), subjects(3), actions(3), objects(2), mood(2), shot_type(1)
        let rows = try Row.fetchAll(db, sql: """
            SELECT c.clip_id, c.source_folder, c.source_clip_id, c.video_id,
                   v.file_path, v.file_name,
                   c.start_time, c.end_time, c.scene, c.description,
                   c.subjects, c.actions, c.objects,
                   c.tags, c.transcript, c.thumbnail_path, c.user_tags,
                   c.rating, c.color_label, c.shot_type, c.mood,
                   c.lighting, c.colors,
                   bm25(clips_fts, 10, 5, 3, 8, 4, 3, 3, 2, 2, 1) AS rank
            FROM clips_fts
            JOIN clips c ON c.clip_id = clips_fts.rowid
            LEFT JOIN videos v ON v.video_id = c.video_id
            WHERE clips_fts MATCH ?\(filterSQL)\(prefixSQL)
            ORDER BY bm25(clips_fts, 10, 5, 3, 8, 4, 3, 3, 2, 2, 1)
            LIMIT ?
            """, arguments: args)

        return rows.map { SearchResult.from(row: $0, rank: $0["rank"]) }
    }

    // MARK: - 混合搜索

    /// 混合搜索入口（向后兼容）
    ///
    /// 结合 FTS5 关键词搜索和向量语义搜索，通过融合排序返回最相关结果。
    /// 内部委托给 `threeWaySearch`（clipResults = nil，仅 FTS5 + 文本嵌入两路融合）。
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
        folderPaths: Set<String>? = nil,
        pathPrefixFilter: String? = nil,
        limit: Int = 50
    ) throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 根据模式决定权重
        let weights = resolveWeights(query: trimmed, mode: mode, hasEmbedding: queryEmbedding != nil)

        // 纯向量模式
        if mode == .vector || (mode == .auto && weights.ftsWeight == 0) {
            if let storeResults = vectorStoreResults {
                return try vectorSearchFromStore(db, storeResults: storeResults, folderPaths: folderPaths, pathPrefixFilter: pathPrefixFilter, limit: limit)
            }
            guard let embedding = queryEmbedding, let model = embeddingModel else {
                return [] // 无向量时返回空
            }
            return try vectorSearch(db, queryEmbedding: embedding, embeddingModels: [model], folderPaths: folderPaths, pathPrefixFilter: pathPrefixFilter, limit: limit)
        }

        // 纯 FTS 模式或无向量
        if mode == .fts || queryEmbedding == nil {
            return try search(db, query: trimmed, folderPaths: folderPaths, pathPrefixFilter: pathPrefixFilter, limit: limit)
        }

        // 混合模式 → 委托给 threeWaySearch (clipResults = nil)
        let parsed = QueryParser.parse(trimmed)

        // 将旧格式向量结果转为 VectorSearchResult
        var textEmbResults: [VectorSearchResult]?
        if let storeResults = vectorStoreResults {
            textEmbResults = storeResults.map {
                VectorSearchResult(clipId: $0.clipId, similarity: $0.similarity)
            }
        } else if let embedding = queryEmbedding, let model = embeddingModel {
            // SQLite 全表扫描回退：先查出完整结果，再提取分数
            let rawResults = try vectorSearch(
                db, queryEmbedding: embedding, embeddingModels: [model],
                folderPaths: folderPaths, pathPrefixFilter: pathPrefixFilter, limit: limit * 2
            )
            textEmbResults = rawResults.compactMap { r in
                guard let sim = r.similarity else { return nil }
                return VectorSearchResult(clipId: r.clipId, similarity: Float(sim))
            }
        }

        return try threeWaySearch(
            db,
            query: parsed,
            clipResults: nil,
            textEmbResults: textEmbResults,
            weights: weights,
            folderPaths: folderPaths,
            pathPrefixFilter: pathPrefixFilter,
            limit: limit
        )
    }

    // MARK: - 三路融合搜索

    /// 三路融合搜索入口
    ///
    /// 结合 CLIP 视觉搜索、FTS5 关键词搜索、文本嵌入语义搜索，
    /// 通过加权融合排序返回最相关结果。
    ///
    /// 调用方负责:
    /// 1. 用 QueryParser 解析查询
    /// 2. 用 CLIP text encoder 编码 → 搜索 USearch clip 索引 → clipResults
    /// 3. 用 text embedding 编码 → 搜索 USearch text 索引 → textEmbResults
    /// 4. 传入本方法做融合
    ///
    /// - Parameters:
    ///   - db: 全局库数据库连接
    ///   - query: 解析后的查询
    ///   - clipResults: CLIP 向量搜索结果（nil = 无 CLIP 层）
    ///   - textEmbResults: 文本嵌入向量搜索结果（nil = 无文本嵌入层）
    ///   - weights: 三路融合权重
    ///   - folderPaths: 文件夹过滤
    ///   - pathPrefixFilter: 路径前缀过滤
    ///   - limit: 最大返回条数
    /// - Returns: 按融合得分排序的搜索结果
    public static func threeWaySearch(
        _ db: Database,
        query: ParsedQuery,
        expandedQuery: QueryPipeline.ExpandedQuery? = nil,
        clipResults: [VectorSearchResult]? = nil,
        textEmbResults: [VectorSearchResult]? = nil,
        weights: SearchWeights,
        folderPaths: Set<String>? = nil,
        pathPrefixFilter: String? = nil,
        limit: Int = 50
    ) throws -> [SearchResult] {
        // 空文本 + 无向量结果 → 空
        let hasVectorResults = (clipResults != nil && !clipResults!.isEmpty)
            || (textEmbResults != nil && !textEmbResults!.isEmpty)
        guard !query.isEmpty || hasVectorResults else { return [] }

        // 收集各路分数
        var clipScores: [Int64: Double] = [:]
        var ftsScores: [Int64: Double] = [:]
        var textEmbScores: [Int64: Double] = [:]
        var resultData: [Int64: SearchResult] = [:]

        // 1. CLIP 向量搜索结果
        if let clipResults, weights.clipWeight > 0 {
            let clipMetadata = try fetchMetadata(
                db, clipIds: clipResults.map { $0.clipId },
                folderPaths: folderPaths, pathPrefixFilter: pathPrefixFilter
            )
            for vr in clipResults {
                let clipId = vr.clipId
                clipScores[clipId] = Double(vr.similarity)
                if let meta = clipMetadata[clipId] {
                    resultData[clipId] = meta
                }
            }
        }

        // 2. FTS5 关键词搜索
        if weights.ftsWeight > 0 && !query.positiveText.isEmpty {
            // 2a. 原始语言搜索
            let ftsResults = try search(
                db, query: query.ftsQuery,
                folderPaths: folderPaths,
                pathPrefixFilter: pathPrefixFilter,
                limit: limit * 2
            )
            for result in ftsResults {
                ftsScores[result.clipId] = result.rank
                if resultData[result.clipId] == nil {
                    resultData[result.clipId] = result
                }
            }
            // 2b. 跨语言翻译扩展搜索
            if let translatedFTS = expandedQuery?.translatedFTSQuery {
                let translatedResults = try search(
                    db, query: translatedFTS,
                    folderPaths: folderPaths,
                    pathPrefixFilter: pathPrefixFilter,
                    limit: limit * 2
                )
                for result in translatedResults {
                    if ftsScores[result.clipId] == nil {
                        // 翻译命中的权重略低于原始命中 (0.8x)
                        ftsScores[result.clipId] = result.rank * 0.8
                        if resultData[result.clipId] == nil {
                            resultData[result.clipId] = result
                        }
                    }
                }
            }
        }

        // 3. 文本嵌入搜索结果
        if let textEmbResults, weights.textEmbWeight > 0 {
            let textMetadata = try fetchMetadata(
                db, clipIds: textEmbResults.map { $0.clipId },
                folderPaths: folderPaths, pathPrefixFilter: pathPrefixFilter
            )
            for vr in textEmbResults {
                let clipId = vr.clipId
                textEmbScores[clipId] = Double(vr.similarity)
                if resultData[clipId] == nil, let meta = textMetadata[clipId] {
                    resultData[clipId] = meta
                }
            }
        }

        // 4. 如果三路都没有结果，返回空
        if resultData.isEmpty { return [] }

        // 5. 归一化各路分数
        let normClip = normalizeScores(clipScores, isNegatedRank: false)
        let normFTS = normalizeScores(ftsScores, isNegatedRank: true)
        let normTextEmb = normalizeScores(textEmbScores, isNegatedRank: false)

        // 6. 融合排序
        let allClipIds = Set(clipScores.keys)
            .union(ftsScores.keys)
            .union(textEmbScores.keys)

        var fusedResults: [(SearchResult, Double)] = []

        for clipId in allClipIds {
            guard let data = resultData[clipId] else { continue }

            let cScore = normClip[clipId] ?? 0.0
            let fScore = normFTS[clipId] ?? 0.0
            let tScore = normTextEmb[clipId] ?? 0.0

            let finalScore = weights.clipWeight * cScore
                + weights.ftsWeight * fScore
                + weights.textEmbWeight * tScore

            // 取最高的向量相似度作为 similarity 字段
            let bestSimilarity = max(
                clipScores[clipId] ?? 0.0,
                textEmbScores[clipId] ?? 0.0
            )

            let merged = data.withScores(
                rank: ftsScores[clipId] ?? 0.0,
                similarity: bestSimilarity > 0 ? bestSimilarity : nil,
                finalScore: finalScore
            )
            fusedResults.append((merged, finalScore))
        }

        fusedResults.sort { $0.1 > $1.1 || ($0.1 == $1.1 && $0.0.clipId < $1.0.clipId) }
        return Array(fusedResults.prefix(limit).map { $0.0 })
    }

    // MARK: - 以图搜视频

    /// 以图搜视频（纯 CLIP 向量搜索）
    ///
    /// 使用 CLIP image embedding 在 USearch 索引中搜索相似片段，
    /// 然后从数据库补全元数据。权重固定为 clipOnly (1.0/0.0/0.0)。
    ///
    /// 调用方负责:
    /// 1. 用 CLIPEmbeddingProvider.encodeImage(data:) 编码图片 → [Float]
    /// 2. 用 USearchVectorIndex.searchSimilarity(query:count:) 搜索 → [VectorSearchResult]
    /// 3. 传入本方法补全元数据并返回
    ///
    /// - Parameters:
    ///   - db: 全局库数据库连接
    ///   - clipResults: USearch CLIP 索引搜索结果
    ///   - folderPaths: 文件夹过滤
    ///   - pathPrefixFilter: 路径前缀过滤
    ///   - limit: 最大返回条数
    /// - Returns: 按 CLIP 相似度降序排列的搜索结果
    public static func imageSearch(
        _ db: Database,
        clipResults: [VectorSearchResult],
        folderPaths: Set<String>? = nil,
        pathPrefixFilter: String? = nil,
        limit: Int = 50
    ) throws -> [SearchResult] {
        let emptyQuery = ParsedQuery(
            positiveText: "",
            negativeTerms: [],
            hasQuotedPhrase: false,
            rawQuery: ""
        )
        return try threeWaySearch(
            db,
            query: emptyQuery,
            clipResults: clipResults,
            textEmbResults: nil,
            weights: .clipOnly,
            folderPaths: folderPaths,
            pathPrefixFilter: pathPrefixFilter,
            limit: limit
        )
    }

    // MARK: - 元数据批量查询

    /// 从数据库批量查询 clip 元数据
    ///
    /// 用于 USearch 搜索结果（只有 clipId + similarity）补全展示信息。
    static func fetchMetadata(
        _ db: Database,
        clipIds: [Int64],
        folderPaths: Set<String>? = nil,
        pathPrefixFilter: String? = nil
    ) throws -> [Int64: SearchResult] {
        guard !clipIds.isEmpty else { return [:] }

        let candidateIds = Array(clipIds.prefix(900))
        let placeholders = candidateIds.map { _ in "?" }.joined(separator: ", ")
        let filterSQL = folderFilterSQL(folderPaths: folderPaths)
        let prefixSQL = pathPrefixFilterSQL(pathPrefixFilter)
        var args = StatementArguments()
        for id in candidateIds { args += [id] }
        appendFolderArgs(&args, folderPaths: folderPaths)
        appendPrefixArgs(&args, pathPrefixFilter: pathPrefixFilter)

        let rows = try Row.fetchAll(db, sql: """
            SELECT c.clip_id, c.source_folder, c.source_clip_id, c.video_id,
                   v.file_path, v.file_name,
                   c.start_time, c.end_time, c.scene, c.description,
                   c.subjects, c.actions, c.objects,
                   c.tags, c.transcript, c.thumbnail_path, c.user_tags,
                   c.rating, c.color_label, c.shot_type, c.mood,
                   c.lighting, c.colors
            FROM clips c
            LEFT JOIN videos v ON v.video_id = c.video_id
            WHERE c.clip_id IN (\(placeholders))\(filterSQL)\(prefixSQL)
            """, arguments: args)

        var result: [Int64: SearchResult] = [:]
        for row in rows {
            let clipId: Int64 = row["clip_id"]
            result[clipId] = SearchResult.from(row: row)
        }
        return result
    }

    // MARK: - 分数归一化

    /// Min-Max 归一化分数映射
    ///
    /// 当只有一个结果（或所有分数相同）时 range == 0，返回 1.0 而非 0.0，
    /// 确保有命中的搜索路不会因归一化而被清零。
    ///
    /// - Parameters:
    ///   - scores: clipId → 原始分数
    ///   - isNegatedRank: 若为 true，取反后再归一化（FTS5 rank 是负数）
    /// - Returns: clipId → 归一化后分数 [0, 1]
    static func normalizeScores(
        _ scores: [Int64: Double],
        isNegatedRank: Bool
    ) -> [Int64: Double] {
        guard !scores.isEmpty else { return [:] }

        if isNegatedRank {
            // FTS5 rank 是负数（越小越好），取反后做 min-max
            guard let rawMax = scores.values.max(),
                  let rawMin = scores.values.min() else { return [:] }
            let negatedMin = -rawMax
            let negatedMax = -rawMin
            let range = negatedMax - negatedMin
            if range > 0 {
                return scores.mapValues { (-$0 - negatedMin) / range }
            } else {
                // 单一结果或全部相同：给满分，让权重决定贡献
                return scores.mapValues { _ in 1.0 }
            }
        } else {
            guard let minVal = scores.values.min(),
                  let maxVal = scores.values.max() else { return [:] }
            let range = maxVal - minVal
            if range > 0 {
                return scores.mapValues { ($0 - minVal) / range }
            } else {
                // 单一结果或全部相同：给满分，让权重决定贡献
                return scores.mapValues { _ in 1.0 }
            }
        }
    }

    // MARK: - 向量搜索

    /// 纯向量搜索
    ///
    /// 加载所有匹配 embeddingModels 的 clips，计算余弦相似度排序。
    /// 支持多模型名以兼容 Gemini / EmbeddingGemma 混合索引场景。
    static func vectorSearch(
        _ db: Database,
        queryEmbedding: [Float],
        embeddingModels: [String],
        folderPaths: Set<String>? = nil,
        pathPrefixFilter: String? = nil,
        limit: Int = 50
    ) throws -> [SearchResult] {
        guard !embeddingModels.isEmpty else { return [] }
        let filterSQL = folderFilterSQL(folderPaths: folderPaths)
        let prefixSQL = pathPrefixFilterSQL(pathPrefixFilter)
        let placeholders = embeddingModels.map { _ in "?" }.joined(separator: ", ")
        var args = StatementArguments()
        for model in embeddingModels { args += [model] }
        appendFolderArgs(&args, folderPaths: folderPaths)
        appendPrefixArgs(&args, pathPrefixFilter: pathPrefixFilter)

        let rows = try Row.fetchAll(db, sql: """
            SELECT c.clip_id, c.source_folder, c.source_clip_id, c.video_id,
                   v.file_path, v.file_name,
                   c.start_time, c.end_time, c.scene, c.description,
                   c.subjects, c.actions, c.objects,
                   c.tags, c.transcript, c.thumbnail_path, c.user_tags,
                   c.rating, c.color_label, c.shot_type, c.mood,
                   c.lighting, c.colors,
                   c.embedding
            FROM clips c
            LEFT JOIN videos v ON v.video_id = c.video_id
            WHERE c.embedding IS NOT NULL AND c.embedding_model IN (\(placeholders))\(filterSQL)\(prefixSQL)
            """, arguments: args)

        var results: [(SearchResult, Double)] = []

        for row in rows {
            guard let embeddingData = row["embedding"] as? Data else { continue }
            let clipEmbedding = EmbeddingUtils.deserializeEmbedding(embeddingData)
            let similarity = Double(EmbeddingUtils.cosineSimilarity(queryEmbedding, clipEmbedding))

            let result = SearchResult.from(row: row, similarity: similarity, finalScore: similarity)
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
        folderPaths: Set<String>? = nil,
        pathPrefixFilter: String? = nil,
        limit: Int = 50
    ) throws -> [SearchResult] {
        guard !storeResults.isEmpty else { return [] }

        // SQLite 默认变量上限通常为 999，预留少量参数给其他过滤条件
        let candidateResults = Array(storeResults.prefix(900))
        let similarities = Dictionary(uniqueKeysWithValues: candidateResults.map { ($0.clipId, Double($0.similarity)) })
        let clipIds = candidateResults.map { $0.clipId }

        // 查询元数据（含文件夹过滤）
        let placeholders = clipIds.map { _ in "?" }.joined(separator: ", ")
        let filterSQL = folderFilterSQL(folderPaths: folderPaths)
        let prefixSQL = pathPrefixFilterSQL(pathPrefixFilter)
        var args = StatementArguments()
        for id in clipIds { args += [id] }
        appendFolderArgs(&args, folderPaths: folderPaths)
        appendPrefixArgs(&args, pathPrefixFilter: pathPrefixFilter)

        let rows = try Row.fetchAll(db, sql: """
            SELECT c.clip_id, c.source_folder, c.source_clip_id, c.video_id,
                   v.file_path, v.file_name,
                   c.start_time, c.end_time, c.scene, c.description,
                   c.subjects, c.actions, c.objects,
                   c.tags, c.transcript, c.thumbnail_path, c.user_tags,
                   c.rating, c.color_label, c.shot_type, c.mood,
                   c.lighting, c.colors
            FROM clips c
            LEFT JOIN videos v ON v.video_id = c.video_id
            WHERE c.clip_id IN (\(placeholders))\(filterSQL)\(prefixSQL)
            """, arguments: args)

        // 构建结果并按相似度排序
        var results: [SearchResult] = []
        for row in rows {
            let clipId: Int64 = row["clip_id"]
            let sim = similarities[clipId] ?? 0.0
            results.append(SearchResult.from(row: row, similarity: sim, finalScore: sim))
        }

        results.sort {
            ($0.similarity ?? 0) > ($1.similarity ?? 0) ||
            (($0.similarity ?? 0) == ($1.similarity ?? 0) && $0.clipId < $1.clipId)
        }
        return Array(results.prefix(limit))
    }

    // MARK: - 权重解析

    /// 根据搜索模式和查询内容解析权重（向后兼容）
    ///
    /// 内部委托给 `resolveThreeWayWeights`。
    public static func resolveWeights(query: String, mode: SearchMode, hasEmbedding: Bool) -> SearchWeights {
        resolveThreeWayWeights(
            query: query,
            mode: mode,
            hasCLIP: true,        // 默认假设 CLIP 可用
            hasTextEmb: hasEmbedding
        )
    }

    /// 数据层感知的三路自适应权重策略
    ///
    /// 根据可用的数据层和查询特征自动选择最优权重：
    ///
    /// | 场景 | CLIP | FTS5 | TextEmb |
    /// |------|------|------|---------|
    /// | 默认三路 | 0.5 | 0.2 | 0.3 |
    /// | 引号精确 | 0.1 | 0.8 | 0.1 |
    /// | 长句语义 | 0.6 | 0.1 | 0.3 |
    /// | 无 CLIP | 0.0 | 0.4 | 0.6 |
    /// | 无 TextEmb | 0.7 | 0.3 | 0.0 |
    /// | 仅 FTS5 | 0.0 | 1.0 | 0.0 |
    /// | 以图搜 | 1.0 | 0.0 | 0.0 |
    ///
    /// - Parameters:
    ///   - query: 查询文本
    ///   - mode: 搜索模式（auto 时使用自适应逻辑）
    ///   - hasCLIP: CLIP 索引是否可用
    ///   - hasTextEmb: 文本嵌入是否可用
    ///   - isImageQuery: 是否为以图搜视频
    /// - Returns: 三路融合权重
    public static func resolveThreeWayWeights(
        query: String,
        mode: SearchMode = .auto,
        hasCLIP: Bool,
        hasTextEmb: Bool,
        isImageQuery: Bool = false
    ) -> SearchWeights {
        // 以图搜视频: 100% CLIP
        if isImageQuery {
            return .clipOnly
        }

        // 显式模式覆盖
        switch mode {
        case .fts:
            return .ftsOnly
        case .vector:
            // vector 模式: 优先 CLIP，回退 TextEmb
            if hasCLIP { return .clipOnly }
            if hasTextEmb { return .textEmbOnly }
            return .ftsOnly
        case .hybrid:
            // hybrid 使用默认三路（根据可用层调整）
            break
        case .auto:
            break
        }

        // 根据可用层降级
        if !hasCLIP && !hasTextEmb {
            return .ftsOnly
        }

        // 查询特征分析
        let isQuoted = query.contains("\"")
        let isLong: Bool = {
            let threshold = containsCJK(query) ? 5 : 10
            return query.count > threshold
        }()

        // 三路都可用
        if hasCLIP && hasTextEmb {
            if isQuoted { return .exactMatch }
            if isLong { return .semantic }
            return .default
        }

        // 无 CLIP，有 TextEmb
        if !hasCLIP && hasTextEmb {
            if isQuoted { return SearchWeights(clipWeight: 0.0, ftsWeight: 0.8, textEmbWeight: 0.2) }
            if isLong { return SearchWeights(clipWeight: 0.0, ftsWeight: 0.2, textEmbWeight: 0.8) }
            return .twoWayNoClip
        }

        // 有 CLIP，无 TextEmb
        if hasCLIP && !hasTextEmb {
            if isQuoted { return SearchWeights(clipWeight: 0.1, ftsWeight: 0.9, textEmbWeight: 0.0) }
            if isLong { return SearchWeights(clipWeight: 0.8, ftsWeight: 0.2, textEmbWeight: 0.0) }
            return .twoWayNoTextEmb
        }

        return .default
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

    // MARK: - 文件夹过滤辅助

    /// 生成文件夹过滤的 SQL WHERE 子句片段
    ///
    /// - `nil`: 不过滤（全局搜索）→ 返回空字符串
    /// - 空集: 过滤为"无文件夹"→ 返回 ` AND 0`（零结果）
    /// - 非空集: 返回 ` AND c.source_folder IN (?, ?, ...)`
    private static func folderFilterSQL(folderPaths: Set<String>?) -> String {
        guard let paths = folderPaths else { return "" }
        if paths.isEmpty { return " AND 0" }
        let placeholders = paths.map { _ in "?" }.joined(separator: ", ")
        return " AND c.source_folder IN (\(placeholders))"
    }

    /// 将文件夹路径追加到 StatementArguments
    ///
    /// 逐个 append 避免类型擦除问题（GRDB v6 StatementArguments 陷阱）。
    /// 排序保证确定性查询计划。
    private static func appendFolderArgs(_ args: inout StatementArguments, folderPaths: Set<String>?) {
        guard let paths = folderPaths else { return }
        for path in paths.sorted() {
            args += [path]
        }
    }

    // MARK: - 路径前缀过滤辅助

    /// 生成路径前缀过滤的 SQL WHERE 子句片段
    ///
    /// 用于子文件夹快捷入口：按 `v.file_path` 路径前缀过滤。
    /// - `nil`: 不过滤 → 返回空字符串
    /// - 非空: 返回 ` AND v.file_path LIKE ? || '/%'`
    private static func pathPrefixFilterSQL(_ prefix: String?) -> String {
        guard prefix != nil else { return "" }
        return " AND v.file_path LIKE ? || '/%'"
    }

    /// 将路径前缀追加到 StatementArguments
    private static func appendPrefixArgs(_ args: inout StatementArguments, pathPrefixFilter: String?) {
        guard let prefix = pathPrefixFilter else { return }
        args += [prefix]
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
