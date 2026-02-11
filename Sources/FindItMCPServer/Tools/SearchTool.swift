import Foundation
import MCP
import GRDB
import FindItCore

/// 搜索视频片段
///
/// 使用 FTS5 全文搜索 + 向量语义搜索的混合引擎，
/// 支持过滤、排序、分页等后处理操作。
enum SearchTool {

    static func execute(params: CallTool.Parameters, context: DatabaseContext) async throws -> CallTool.Result {
        let query = try ParamHelpers.requireString(params, key: "query")
        let modeStr = ParamHelpers.optionalString(params, key: "mode") ?? "auto"
        let limit = min(max(ParamHelpers.optionalInt(params, key: "limit") ?? 20, 1), 200)
        let offset = max(ParamHelpers.optionalInt(params, key: "offset") ?? 0, 0)
        let folder = ParamHelpers.optionalString(params, key: "folder")

        let mode = SearchEngine.SearchMode(rawValue: modeStr) ?? .auto

        // 准备向量搜索（如果需要）
        var queryEmbedding: [Float]?
        var embeddingModel: String?
        var vectorStoreResults: [(clipId: Int64, similarity: Float)]?

        if mode != .fts, let provider = context.getEmbeddingProvider() {
            do {
                queryEmbedding = try await provider.embed(text: query)
                embeddingModel = provider.name

                // 从 VectorStore 获取预排序结果
                let store = try await context.getVectorStore(provider: provider)
                if await !store.isEmpty {
                    vectorStoreResults = await store.search(
                        query: queryEmbedding!,
                        limit: limit + offset
                    )
                }
            } catch {
                // Embedding 失败不致命，退化为纯 FTS
            }
        }

        // 构建文件夹过滤
        let folderPaths: Set<String>? = folder.map { Set([$0]) }

        // 搜索
        let capturedEmbedding = queryEmbedding
        let capturedModel = embeddingModel
        let capturedVectorResults = vectorStoreResults
        var results = try await context.globalDB.read { db in
            try SearchEngine.hybridSearch(
                db,
                query: query,
                queryEmbedding: capturedEmbedding,
                embeddingModel: capturedModel,
                vectorStoreResults: capturedVectorResults,
                mode: mode,
                folderPaths: folderPaths,
                limit: limit + offset
            )
        }

        // 记录搜索历史
        let resultCount = results.count
        try? await context.globalDB.write { db in
            try SearchEngine.recordSearch(db, query: query, resultCount: resultCount)
        }

        // 过滤
        let minRating = ParamHelpers.optionalInt(params, key: "min_rating")
        let colorLabels = ParamHelpers.optionalStringArray(params, key: "color_labels")
        let shotTypes = ParamHelpers.optionalStringArray(params, key: "shot_types")
        let moods = ParamHelpers.optionalStringArray(params, key: "moods")
        let sortByStr = ParamHelpers.optionalString(params, key: "sort_by")

        let filter = FilterEngine.SearchFilter(
            minRating: minRating,
            colorLabels: colorLabels.map { Set($0.compactMap { ColorLabel(rawValue: $0) }) },
            shotTypes: shotTypes.map { Set($0) },
            moods: moods.map { Set($0) },
            sortBy: FilterEngine.SortField(rawValue: sortByStr ?? "relevance") ?? .relevance
        )

        if !filter.isEmpty {
            results = FilterEngine.applyFilter(results, filter: filter)
        }

        // 分页（内存切片）
        if offset > 0 {
            results = Array(results.dropFirst(offset))
        }
        if results.count > limit {
            results = Array(results.prefix(limit))
        }

        // 构造输出
        struct ResultItem: Codable {
            let clipId: Int64
            let sourceFolder: String
            let filePath: String?
            let fileName: String?
            let startTime: Double
            let endTime: Double
            let scene: String?
            let description: String?
            let subjects: [String]
            let actions: [String]
            let objects: [String]
            let tags: [String]
            let userTags: [String]
            let transcript: String?
            let mood: String?
            let shotType: String?
            let lighting: String?
            let colors: [String]
            let rating: Int
            let colorLabel: String?
            let score: Double?
        }

        let items = results.map {
            ResultItem(
                clipId: $0.clipId,
                sourceFolder: $0.sourceFolder,
                filePath: $0.filePath,
                fileName: $0.fileName,
                startTime: $0.startTime,
                endTime: $0.endTime,
                scene: $0.scene,
                description: $0.clipDescription,
                subjects: TagParsingHelpers.parseTagsFromGlobalDB($0.subjects),
                actions: TagParsingHelpers.parseTagsFromGlobalDB($0.actions),
                objects: TagParsingHelpers.parseTagsFromGlobalDB($0.objects),
                tags: TagParsingHelpers.parseTagsFromGlobalDB($0.tags),
                userTags: TagParsingHelpers.parseTagsFromGlobalDB($0.userTags),
                transcript: $0.transcript,
                mood: $0.mood,
                shotType: $0.shotType,
                lighting: $0.lighting,
                colors: TagParsingHelpers.parseTagsFromGlobalDB($0.colors),
                rating: $0.rating,
                colorLabel: $0.colorLabel,
                score: $0.finalScore
            )
        }

        let json = try ParamHelpers.toJSON(items)
        let modeLabel = embeddingModel != nil ? "hybrid(\(embeddingModel!))" : "fts"
        return CallTool.Result(content: [.text("Found \(items.count) results for '\(query)' [mode=\(modeLabel)]:\n\(json)")])
    }
}
