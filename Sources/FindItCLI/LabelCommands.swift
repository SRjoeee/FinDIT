import ArgumentParser
import Foundation
import FindItCore
import GRDB

/// 评分与颜色标签管理（label rate / label color / label get）
struct LabelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "label",
        abstract: "管理片段的评分和颜色标签",
        subcommands: [
            LabelRateCommand.self,
            LabelColorCommand.self,
            LabelGetCommand.self,
        ]
    )
}

// MARK: - label rate

struct LabelRateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rate",
        abstract: "设置片段的星级评分 (0-5, 0=清除评分)"
    )

    @Argument(help: "片段 ID (文件夹库 clip_id)")
    var clipId: Int64

    @Option(name: .long, help: "素材文件夹路径")
    var folder: String

    @Option(name: .long, help: "评分 (0-5)")
    var rating: Int

    func run() throws {
        guard (0...5).contains(rating) else {
            print("错误: 评分必须在 0-5 之间")
            throw ExitCode.failure
        }

        let folderPath = (folder as NSString).standardizingPath
        let folderDB = try DatabaseManager.openFolderDatabase(at: folderPath)

        try folderDB.write { db in
            guard try Clip.filter(Column("clip_id") == clipId).fetchOne(db) != nil else {
                print("错误: 未找到 clip_id=\(clipId)")
                throw ExitCode.failure
            }
            try ClipLabel.updateRating(db, clipId: clipId, rating: rating)
        }

        if rating == 0 {
            print("✓ 已清除 clip \(clipId) 的评分")
        } else {
            let stars = String(repeating: "★", count: rating)
                + String(repeating: "☆", count: 5 - rating)
            print("✓ clip \(clipId) 评分: \(stars)")
        }
    }
}

// MARK: - label color

struct LabelColorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "color",
        abstract: "设置片段的颜色标签 (red/orange/yellow/green/blue/purple/gray, none=清除)"
    )

    @Argument(help: "片段 ID (文件夹库 clip_id)")
    var clipId: Int64

    @Option(name: .long, help: "素材文件夹路径")
    var folder: String

    @Option(name: .long, help: "颜色: red, orange, yellow, green, blue, purple, gray, none")
    var color: String

    func run() throws {
        let folderPath = (folder as NSString).standardizingPath
        let folderDB = try DatabaseManager.openFolderDatabase(at: folderPath)

        let label: ColorLabel?
        if color.lowercased() == "none" {
            label = nil
        } else {
            guard let parsed = ColorLabel(rawValue: color.lowercased()) else {
                print("错误: 无效颜色 \"\(color)\"")
                print("可选: red, orange, yellow, green, blue, purple, gray, none")
                throw ExitCode.failure
            }
            label = parsed
        }

        try folderDB.write { db in
            guard try Clip.filter(Column("clip_id") == clipId).fetchOne(db) != nil else {
                print("错误: 未找到 clip_id=\(clipId)")
                throw ExitCode.failure
            }
            try ClipLabel.updateColorLabel(db, clipId: clipId, label: label)
        }

        if let label = label {
            print("✓ clip \(clipId) 颜色标签: \(label.rawValue) (\(label.displayName))")
        } else {
            print("✓ 已清除 clip \(clipId) 的颜色标签")
        }
    }
}

// MARK: - label get

struct LabelGetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "查看片段的评分和颜色标签"
    )

    @Argument(help: "片段 ID (文件夹库 clip_id)")
    var clipId: Int64

    @Option(name: .long, help: "素材文件夹路径")
    var folder: String

    @Option(name: .long, help: "输出格式: text, json")
    var format: OutputFormat = .text

    func run() throws {
        let folderPath = (folder as NSString).standardizingPath
        let folderDB = try DatabaseManager.openFolderDatabase(at: folderPath)

        let (rating, colorLabel) = try folderDB.read { db -> (Int, ColorLabel?) in
            guard try Clip.filter(Column("clip_id") == clipId).fetchOne(db) != nil else {
                print("错误: 未找到 clip_id=\(clipId)")
                throw ExitCode.failure
            }
            let r = try ClipLabel.fetchRating(db, clipId: clipId)
            let c = try ClipLabel.fetchColorLabel(db, clipId: clipId)
            return (r, c)
        }

        switch format {
        case .json:
            struct LabelOutput: Codable {
                let clipId: Int64
                let rating: Int
                let colorLabel: String?
            }
            try JSONOutput.print(LabelOutput(
                clipId: clipId,
                rating: rating,
                colorLabel: colorLabel?.rawValue
            ))
        case .text:
            print("Clip #\(clipId) 标注:")
            if rating > 0 {
                let stars = String(repeating: "★", count: rating)
                    + String(repeating: "☆", count: 5 - rating)
                print("  评分:     \(stars) (\(rating)/5)")
            } else {
                print("  评分:     未评分")
            }
            if let c = colorLabel {
                print("  颜色标签: \(c.rawValue) (\(c.displayName))")
            } else {
                print("  颜色标签: 无")
            }
        }
    }
}
