import ArgumentParser
import Foundation
import FindItCore
import GRDB

/// 用户标签管理（tag add / tag remove / tag list / tag popular）
struct TagCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tag",
        abstract: "管理片段的用户标签",
        subcommands: [
            TagAddCommand.self,
            TagRemoveCommand.self,
            TagListCommand.self,
            TagPopularCommand.self,
        ]
    )
}

// MARK: - tag add

struct TagAddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "给片段添加用户标签"
    )

    @Argument(help: "片段 ID (文件夹库 clip_id)")
    var clipId: Int64

    @Option(name: .long, help: "素材文件夹路径")
    var folder: String

    @Option(name: .long, help: "标签，逗号分隔")
    var tags: String

    func run() throws {
        let folderPath = (folder as NSString).standardizingPath
        let folderDB = try DatabaseManager.openFolderDatabase(at: folderPath)
        let tagList = tags.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespaces)
        }

        guard !tagList.isEmpty else {
            print("错误: 请提供至少一个标签")
            throw ExitCode.failure
        }

        try folderDB.write { db in
            // 验证 clip 存在
            guard try Clip.filter(Column("clip_id") == clipId).fetchOne(db) != nil else {
                print("错误: 未找到 clip_id=\(clipId)")
                throw ExitCode.failure
            }
            try TagManager.addTags(db, clipId: clipId, tags: tagList)
        }

        let current = try folderDB.read { db in
            try TagManager.fetchUserTags(db, clipId: clipId)
        }
        print("✓ 已添加标签到 clip \(clipId)")
        print("  当前标签: \(current.joined(separator: ", "))")
    }
}

// MARK: - tag remove

struct TagRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "移除片段的指定用户标签"
    )

    @Argument(help: "片段 ID (文件夹库 clip_id)")
    var clipId: Int64

    @Option(name: .long, help: "素材文件夹路径")
    var folder: String

    @Option(name: .long, help: "要移除的标签，逗号分隔")
    var tags: String

    func run() throws {
        let folderPath = (folder as NSString).standardizingPath
        let folderDB = try DatabaseManager.openFolderDatabase(at: folderPath)
        let tagList = tags.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespaces)
        }

        try folderDB.write { db in
            guard try Clip.filter(Column("clip_id") == clipId).fetchOne(db) != nil else {
                print("错误: 未找到 clip_id=\(clipId)")
                throw ExitCode.failure
            }
            try TagManager.removeTags(db, clipId: clipId, tags: tagList)
        }

        let current = try folderDB.read { db in
            try TagManager.fetchUserTags(db, clipId: clipId)
        }
        print("✓ 已移除标签")
        if current.isEmpty {
            print("  clip \(clipId) 当前无用户标签")
        } else {
            print("  clip \(clipId) 剩余标签: \(current.joined(separator: ", "))")
        }
    }
}

// MARK: - tag list

struct TagListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "查看片段的所有标签（自动 + 用户）"
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

        guard let clip: Clip = try folderDB.read({ db in
            try Clip.filter(Column("clip_id") == clipId).fetchOne(db)
        }) else {
            print("错误: 未找到 clip_id=\(clipId)")
            throw ExitCode.failure
        }

        switch format {
        case .json:
            struct TagOutput: Codable {
                let clipId: Int64
                let autoTags: [String]
                let userTags: [String]
                let allTags: [String]
            }
            try JSONOutput.print(TagOutput(
                clipId: clipId,
                autoTags: clip.tagsArray,
                userTags: clip.userTagsArray,
                allTags: clip.allTagsArray
            ))
        case .text:
            print("Clip #\(clipId) 标签:")
            let auto = clip.tagsArray
            let user = clip.userTagsArray
            if !auto.isEmpty {
                print("  自动标签: \(auto.joined(separator: ", "))")
            }
            if !user.isEmpty {
                print("  用户标签: \(user.joined(separator: ", "))")
            }
            if auto.isEmpty && user.isEmpty {
                print("  (无标签)")
            }
        }
    }
}

// MARK: - tag popular

struct TagPopularCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "popular",
        abstract: "显示热门标签排行"
    )

    @Option(name: .long, help: "素材文件夹路径")
    var folder: String

    @Option(name: .shortAndLong, help: "显示条数")
    var limit: Int = 30

    @Option(name: .long, help: "输出格式: text, json")
    var format: OutputFormat = .text

    func run() throws {
        let folderPath = (folder as NSString).standardizingPath
        let folderDB = try DatabaseManager.openFolderDatabase(at: folderPath)

        let popular = try folderDB.read { db in
            try TagManager.popularTags(db, limit: limit)
        }

        switch format {
        case .json:
            struct TagStat: Codable {
                let tag: String
                let count: Int
            }
            let stats = popular.map { TagStat(tag: $0.tag, count: $0.count) }
            try JSONOutput.print(stats)
        case .text:
            if popular.isEmpty {
                print("无标签数据")
                return
            }
            print("热门标签 (前 \(popular.count) 个):\n")
            for (i, p) in popular.enumerated() {
                print("  [\(i + 1)] \(p.tag) (\(p.count) 次)")
            }
        }
    }
}
