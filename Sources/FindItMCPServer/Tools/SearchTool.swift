import Foundation
import MCP
import GRDB
import FindItCore

/// 搜索视频片段
///
/// 使用 FTS5 全文搜索 + 向量语义搜索的混合引擎，
/// 支持过滤、排序等后处理操作。
enum SearchTool {

    static func execute(params: CallTool.Parameters, context: DatabaseContext) async throws -> CallTool.Result {
        let query = try ParamHelpers.requireString(params, key: "query")
        let modeStr = ParamHelpers.optionalString(params, key: "mode") ?? "auto"
        let limit = ParamHelpers.optionalInt(params, key: "limit") ?? 20

        let mode = SearchEngine.SearchMode(rawValue: modeStr) ?? .auto

        // 计算查询向量（embedding 失败时降级为纯 FTS5）
        var queryEmbedding: [Float]?
        var embeddingModel: String?
        var vectorStoreResults: [(clipId: Int64, similarity: Float)]?

        if mode != .fts, let provider = context.getEmbeddingProvider() {
            queryEmbedding = try? await provider.embed(text: query)
            embeddingModel = provider.name

            if let embedding = queryEmbedding,
               let store = try? await context.getVectorStore(provider: provider) {
                vectorStoreResults = await store.search(query: embedding, limit: limit * 2)
            }
        }

        // 绑定为 let 以满足 Swift 6 Sendable 闭包要求
        let finalEmbedding = queryEmbedding
        let finalModel = embeddingModel
        let finalStoreResults = vectorStoreResults

        // 搜索
        var results = try await context.globalDB.read { db in
            try SearchEngine.hybridSearch(
                db,
                query: query,
                queryEmbedding: finalEmbedding,
                embeddingModel: finalModel,
                vectorStoreResults: finalStoreResults,
                mode: mode,
                limit: limit
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
            let subjects: String?
            let actions: String?
            let objects: String?
            let tags: String?
            let transcript: String?
            let mood: String?
            let shotType: String?
            let lighting: String?
            let colors: String?
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
                subjects: $0.subjects,
                actions: $0.actions,
                objects: $0.objects,
                tags: $0.tags,
                transcript: $0.transcript,
                mood: $0.mood,
                shotType: $0.shotType,
                lighting: $0.lighting,
                colors: $0.colors,
                rating: $0.rating,
                colorLabel: $0.colorLabel,
                score: $0.finalScore
            )
        }

        let json = try ParamHelpers.toJSON(items)
        return CallTool.Result(content: [.text("Found \(items.count) results for '\(query)':\n\(json)")])
    }
}
