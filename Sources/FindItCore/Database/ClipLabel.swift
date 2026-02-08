import Foundation
import GRDB

/// 颜色标签
///
/// 7 种颜色 + nil（无标签），与 Finder / FCP / Resolve 颜色体系一致。
public enum ColorLabel: String, CaseIterable, Codable, Sendable {
    case red, orange, yellow, green, blue, purple, gray

    /// 中文显示名
    public var displayName: String {
        switch self {
        case .red:    return "红色"
        case .orange: return "橙色"
        case .yellow: return "黄色"
        case .green:  return "绿色"
        case .blue:   return "蓝色"
        case .purple: return "紫色"
        case .gray:   return "灰色"
        }
    }

    /// RGB 颜色值 (0-1)
    public var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .red:    return (0.94, 0.27, 0.27)
        case .orange: return (0.96, 0.58, 0.18)
        case .yellow: return (0.95, 0.83, 0.21)
        case .green:  return (0.32, 0.76, 0.39)
        case .blue:   return (0.25, 0.56, 0.95)
        case .purple: return (0.60, 0.36, 0.87)
        case .gray:   return (0.60, 0.60, 0.60)
        }
    }
}

/// 片段评分与颜色标签操作
public enum ClipLabel {

    /// 更新评分（0-5，0=未评分）
    public static func updateRating(_ db: Database, clipId: Int64, rating: Int) throws {
        let clamped = max(0, min(5, rating))
        try db.execute(sql: """
            UPDATE clips SET rating = ? WHERE clip_id = ?
            """, arguments: [clamped, clipId])
    }

    /// 更新颜色标签（nil = 移除）
    public static func updateColorLabel(_ db: Database, clipId: Int64, label: ColorLabel?) throws {
        try db.execute(sql: """
            UPDATE clips SET color_label = ? WHERE clip_id = ?
            """, arguments: [label?.rawValue, clipId])
    }

    /// 查询评分
    public static func fetchRating(_ db: Database, clipId: Int64) throws -> Int {
        let row = try Row.fetchOne(db, sql: """
            SELECT rating FROM clips WHERE clip_id = ?
            """, arguments: [clipId])
        return row?["rating"] ?? 0
    }

    /// 查询颜色标签
    public static func fetchColorLabel(_ db: Database, clipId: Int64) throws -> ColorLabel? {
        let row = try Row.fetchOne(db, sql: """
            SELECT color_label FROM clips WHERE clip_id = ?
            """, arguments: [clipId])
        guard let raw: String = row?["color_label"] else { return nil }
        return ColorLabel(rawValue: raw)
    }
}
