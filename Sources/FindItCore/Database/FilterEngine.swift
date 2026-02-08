import Foundation
import GRDB

/// 搜索过滤引擎
///
/// 提供搜索结果的多维度过滤（评分、颜色标签、镜头类型、情绪）和排序能力。
/// 过滤在内存中应用于 SearchEngine 返回的结果，排序同理。
public enum FilterEngine {

    // MARK: - 过滤条件

    /// 搜索过滤条件
    public struct SearchFilter: Sendable, Equatable {
        /// 最低评分（nil = 不限）
        public var minRating: Int?
        /// 颜色标签过滤（nil = 不限）
        public var colorLabels: Set<ColorLabel>?
        /// 镜头类型过滤（nil = 不限）
        public var shotTypes: Set<String>?
        /// 情绪过滤（nil = 不限）
        public var moods: Set<String>?
        /// 排序字段
        public var sortBy: SortField = .relevance
        /// 排序方向
        public var sortOrder: SortOrder = .descending

        /// 是否为空过滤器（无任何约束且使用默认排序）
        public var isEmpty: Bool {
            minRating == nil && colorLabels == nil && shotTypes == nil && moods == nil && sortBy == .relevance
        }

        /// 活跃过滤条件数量（不含排序）
        public var activeFilterCount: Int {
            var count = 0
            if minRating != nil { count += 1 }
            if colorLabels != nil { count += 1 }
            if shotTypes != nil { count += 1 }
            if moods != nil { count += 1 }
            return count
        }

        public init(
            minRating: Int? = nil,
            colorLabels: Set<ColorLabel>? = nil,
            shotTypes: Set<String>? = nil,
            moods: Set<String>? = nil,
            sortBy: SortField = .relevance,
            sortOrder: SortOrder = .descending
        ) {
            self.minRating = minRating
            self.colorLabels = colorLabels
            self.shotTypes = shotTypes
            self.moods = moods
            self.sortBy = sortBy
            self.sortOrder = sortOrder
        }
    }

    /// 排序字段
    public enum SortField: String, CaseIterable, Sendable {
        case relevance = "relevance"
        case date = "date"
        case duration = "duration"
        case rating = "rating"

        public var displayName: String {
            switch self {
            case .relevance: return "相关度"
            case .date: return "时间"
            case .duration: return "时长"
            case .rating: return "评分"
            }
        }
    }

    /// 排序方向
    public enum SortOrder: String, CaseIterable, Sendable {
        case ascending, descending

        public var displayName: String {
            switch self {
            case .ascending: return "升序"
            case .descending: return "降序"
            }
        }
    }

    // MARK: - 内存过滤

    /// 对搜索结果应用过滤条件
    ///
    /// 在内存中过滤 SearchEngine 返回的结果。不修改排序。
    public static func applyFilter(
        _ results: [SearchEngine.SearchResult],
        filter: SearchFilter
    ) -> [SearchEngine.SearchResult] {
        guard !filter.isEmpty || filter.sortBy != .relevance else { return results }

        var filtered = results

        // 评分过滤
        if let minRating = filter.minRating, minRating > 0 {
            filtered = filtered.filter { $0.rating >= minRating }
        }

        // 颜色标签过滤
        if let colors = filter.colorLabels, !colors.isEmpty {
            let rawColors = Set(colors.map(\.rawValue))
            filtered = filtered.filter {
                guard let label = $0.colorLabel else { return false }
                return rawColors.contains(label)
            }
        }

        // 镜头类型过滤
        if let shots = filter.shotTypes, !shots.isEmpty {
            filtered = filtered.filter {
                guard let st = $0.shotType else { return false }
                return shots.contains(st)
            }
        }

        // 情绪过滤
        if let moods = filter.moods, !moods.isEmpty {
            filtered = filtered.filter {
                guard let m = $0.mood else { return false }
                return moods.contains(m)
            }
        }

        // 排序
        if filter.sortBy != .relevance {
            filtered = applySortToResults(filtered, sortBy: filter.sortBy, sortOrder: filter.sortOrder)
        }

        return filtered
    }

    /// 对搜索结果应用排序
    ///
    /// relevance 保持原始排序（由 SearchEngine 的 rank/similarity 决定）。
    public static func applySortToResults(
        _ results: [SearchEngine.SearchResult],
        sortBy: SortField,
        sortOrder: SortOrder
    ) -> [SearchEngine.SearchResult] {
        guard sortBy != .relevance else { return results }

        return results.sorted { a, b in
            let comparison: Bool
            switch sortBy {
            case .relevance:
                return false
            case .date:
                comparison = a.startTime < b.startTime
            case .duration:
                let durA = a.endTime - a.startTime
                let durB = b.endTime - b.startTime
                comparison = durA < durB
            case .rating:
                comparison = a.rating < b.rating
            }
            return sortOrder == .ascending ? comparison : !comparison
        }
    }

    // MARK: - 分面统计

    /// 分面统计结果
    public struct FacetCounts: Sendable {
        /// 镜头类型及其计数
        public let shotTypes: [(value: String, count: Int)]
        /// 情绪及其计数
        public let moods: [(value: String, count: Int)]
        /// 评分分布（rating → count）
        public let ratingCounts: [Int: Int]
        /// 颜色标签及其计数
        public let colorLabelCounts: [(value: ColorLabel, count: Int)]
    }

    /// 查询各过滤维度的可用值和计数
    ///
    /// 从全局搜索索引中统计各维度的不同值及其出现次数。
    /// 用于填充 FilterBar 的菜单选项。
    public static func availableFacets(
        _ db: Database,
        folderPaths: Set<String>? = nil
    ) throws -> FacetCounts {
        let whereClause: String
        var baseArgs: [DatabaseValueConvertible?] = []

        if let paths = folderPaths, !paths.isEmpty {
            let placeholders = paths.map { _ in "?" }.joined(separator: ", ")
            whereClause = "WHERE source_folder IN (\(placeholders))"
            for path in paths.sorted() {
                baseArgs.append(path)
            }
        } else {
            whereClause = "WHERE 1=1"
        }

        // 镜头类型
        let shotRows = try Row.fetchAll(db, sql: """
            SELECT shot_type, COUNT(*) as cnt FROM clips
            \(whereClause) AND shot_type IS NOT NULL AND shot_type != ''
            GROUP BY shot_type ORDER BY cnt DESC LIMIT 20
            """, arguments: StatementArguments(baseArgs))
        let shotTypes = shotRows.map {
            (value: $0["shot_type"] as String, count: $0["cnt"] as Int)
        }

        // 情绪
        let moodRows = try Row.fetchAll(db, sql: """
            SELECT mood, COUNT(*) as cnt FROM clips
            \(whereClause) AND mood IS NOT NULL AND mood != ''
            GROUP BY mood ORDER BY cnt DESC LIMIT 20
            """, arguments: StatementArguments(moodQueryArgs(baseArgs)))
        let moods = moodRows.map {
            (value: $0["mood"] as String, count: $0["cnt"] as Int)
        }

        // 评分分布
        let ratingRows = try Row.fetchAll(db, sql: """
            SELECT rating, COUNT(*) as cnt FROM clips
            \(whereClause) AND rating > 0
            GROUP BY rating ORDER BY rating DESC
            """, arguments: StatementArguments(ratingQueryArgs(baseArgs)))
        var ratingCounts: [Int: Int] = [:]
        for row in ratingRows {
            ratingCounts[row["rating"] as Int] = row["cnt"] as Int
        }

        // 颜色标签
        let colorRows = try Row.fetchAll(db, sql: """
            SELECT color_label, COUNT(*) as cnt FROM clips
            \(whereClause) AND color_label IS NOT NULL
            GROUP BY color_label ORDER BY cnt DESC
            """, arguments: StatementArguments(colorQueryArgs(baseArgs)))
        let colorLabelCounts: [(value: ColorLabel, count: Int)] = colorRows.compactMap { row in
            guard let raw = row["color_label"] as? String,
                  let label = ColorLabel(rawValue: raw) else { return nil }
            return (value: label, count: row["cnt"] as Int)
        }

        return FacetCounts(
            shotTypes: shotTypes,
            moods: moods,
            ratingCounts: ratingCounts,
            colorLabelCounts: colorLabelCounts
        )
    }

    // MARK: - 辅助

    /// 复制 baseArgs（每个查询需要独立的参数副本）
    private static func moodQueryArgs(_ base: [DatabaseValueConvertible?]) -> [DatabaseValueConvertible?] { base }
    private static func ratingQueryArgs(_ base: [DatabaseValueConvertible?]) -> [DatabaseValueConvertible?] { base }
    private static func colorQueryArgs(_ base: [DatabaseValueConvertible?]) -> [DatabaseValueConvertible?] { base }
}
