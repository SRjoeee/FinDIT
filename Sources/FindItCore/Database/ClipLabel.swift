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

    /// macOS Finder 标签编号
    ///
    /// 映射: 0=none, 1=gray, 2=green, 3=purple, 4=blue, 5=yellow, 6=red, 7=orange
    public var finderLabelNumber: Int {
        switch self {
        case .gray:   return 1
        case .green:  return 2
        case .purple: return 3
        case .blue:   return 4
        case .yellow: return 5
        case .red:    return 6
        case .orange: return 7
        }
    }

    /// Finder 标签系统中的英文名称
    ///
    /// DaVinci Resolve（"Import Finder tags as Keywords"）和 Final Cut Pro
    ///（"From Finder Tags"）均读取此名称作为关键词导入。
    public var finderTagName: String {
        rawValue.capitalized
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

    /// 查询视频的有效颜色标签
    ///
    /// 返回该视频所有片段中最近设置的颜色标签。
    /// 用于清除单个片段颜色时决定文件的 Finder 标签。
    public static func effectiveVideoColor(_ db: Database, videoId: Int64) throws -> ColorLabel? {
        let row = try Row.fetchOne(db, sql: """
            SELECT color_label FROM clips
            WHERE video_id = ? AND color_label IS NOT NULL
            ORDER BY clip_id DESC LIMIT 1
            """, arguments: [videoId])
        guard let raw: String = row?["color_label"] else { return nil }
        return ColorLabel(rawValue: raw)
    }

    /// 同步颜色标签到 macOS Finder 标签系统
    ///
    /// 通过 `tagNamesKey` 的 `"Name\nNumber"` 格式同时控制：
    /// - Finder 颜色色点（通过 `\n{number}` 后缀）
    /// - 标签名称（DaVinci Resolve / Final Cut Pro 导入为关键词）
    /// 保留文件已有的非颜色标签不受影响。
    public static func syncFinderTag(filePath: String, label: ColorLabel?) throws {
        let nsurl = URL(fileURLWithPath: filePath) as NSURL

        // 读取现有标签
        var tagValue: AnyObject?
        try nsurl.getResourceValue(&tagValue, forKey: .tagNamesKey)
        var tags = (tagValue as? [String]) ?? []

        // 移除已有的颜色标签（保留用户自定义标签如 "B-roll"）
        let colorNames = Set(ColorLabel.allCases.map(\.finderTagName))
        tags.removeAll { colorNames.contains($0) }

        // 添加新颜色标签（"Name\nNumber" 格式驱动 Finder 色点 + NLE 关键词）
        if let label = label {
            tags.append("\(label.finderTagName)\n\(label.finderLabelNumber)")
        }

        try nsurl.setResourceValue(tags, forKey: .tagNamesKey)
    }
}
