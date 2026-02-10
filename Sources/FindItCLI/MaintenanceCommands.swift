import ArgumentParser
import Foundation
import FindItCore
import GRDB

// MARK: - orphan

/// Orphaned 记录管理（orphan list / orphan cleanup）
struct OrphanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orphan",
        abstract: "管理 orphaned（文件消失）的视频记录",
        subcommands: [
            OrphanListCommand.self,
            OrphanCleanupCommand.self,
        ]
    )
}

/// 列出 orphaned 视频记录
struct OrphanListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "列出所有 orphaned 视频记录"
    )

    @Option(name: .long, help: "素材文件夹路径")
    var folder: String

    @Option(name: .long, help: "输出格式: text, json")
    var format: OutputFormat = .text

    func run() throws {
        let folderPath = (folder as NSString).standardizingPath
        let folderDB = try DatabaseManager.openFolderDatabase(at: folderPath)

        let orphans: [(video: Video, clipCount: Int)] = try folderDB.read { db in
            let videos = try Video.fetchByStatus(db, status: "orphaned")
            return try videos.map { video in
                let count = try Int.fetchOne(db, sql:
                    "SELECT COUNT(*) FROM clips WHERE video_id = ?",
                    arguments: [video.videoId]) ?? 0
                return (video, count)
            }
        }

        switch format {
        case .json:
            struct OrphanInfo: Codable {
                let videoId: Int64
                let fileName: String
                let filePath: String
                let orphanedAt: String?
                let clipCount: Int
                let fileHash: String?
            }
            let entries = orphans.map {
                OrphanInfo(
                    videoId: $0.video.videoId ?? 0,
                    fileName: $0.video.fileName,
                    filePath: $0.video.filePath,
                    orphanedAt: $0.video.orphanedAt,
                    clipCount: $0.clipCount,
                    fileHash: $0.video.fileHash
                )
            }
            try JSONOutput.print(entries)
        case .text:
            if orphans.isEmpty {
                print("无 orphaned 记录")
                return
            }
            print("Orphaned 视频 (\(orphans.count) 个):\n")
            for o in orphans {
                let id = o.video.videoId ?? 0
                let date = o.video.orphanedAt ?? "?"
                print("⊘ [\(id)] \(o.video.fileName)")
                print("    路径:    \(o.video.filePath)")
                print("    消失于:  \(date)")
                print("    片段数:  \(o.clipCount)")
                if let hash = o.video.fileHash {
                    print("    Hash:    \(hash)")
                }
            }
        }
    }
}

/// 清理过期 orphaned 记录
struct OrphanCleanupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "硬删除过期的 orphaned 记录（含缩略图和 SRT）"
    )

    @Option(name: .long, help: "素材文件夹路径")
    var folder: String

    @Option(name: .long, help: "保留天数 (默认 30)")
    var retentionDays: Int = 30

    func run() throws {
        let folderPath = (folder as NSString).standardizingPath
        let folderDB = try DatabaseManager.openFolderDatabase(at: folderPath)

        let result = try OrphanRecovery.cleanupExpired(
            retentionDays: retentionDays,
            folderPath: folderPath,
            folderDB: folderDB
        )

        if result.removedCount == 0 {
            print("无过期记录需要清理 (保留期: \(retentionDays) 天)")
        } else {
            print("✓ 已清理 \(result.removedCount) 条过期 orphaned 记录")
        }
    }
}

// MARK: - remove-video

/// 硬删除视频记录及关联数据
///
/// 从文件夹库和全局库中彻底删除视频记录、clips、缩略图和 SRT 文件。
/// 不会删除视频文件本身。
struct RemoveVideoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove-video",
        abstract: "硬删除视频记录及所有关联数据（不删视频文件）"
    )

    @Argument(help: "视频文件路径")
    var path: String

    @Option(name: .long, help: "素材文件夹路径 (省略则自动检测)")
    var folder: String?

    func run() throws {
        let videoPath = (path as NSString).standardizingPath

        let folderPath: String
        if let f = folder {
            folderPath = (f as NSString).standardizingPath
        } else if let detected = CLIHelpers.detectFolderPath(from: videoPath) {
            folderPath = detected
        } else {
            print("错误: 无法自动检测文件夹库，请使用 --folder 指定")
            throw ExitCode.failure
        }

        let folderDB = try DatabaseManager.openFolderDatabase(at: folderPath)
        let globalDB = try DatabaseManager.openGlobalDatabase()

        let removed = try VideoManager.removeVideo(
            videoPath: videoPath,
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        if removed {
            let fileName = (videoPath as NSString).lastPathComponent
            print("✓ 已删除 \(fileName) 的所有索引数据")
            print("  (视频文件未删除)")
        } else {
            print("错误: 未找到视频记录: \(videoPath)")
            throw ExitCode.failure
        }
    }
}

// MARK: - rebase

/// 检测并修复文件夹库中的路径不匹配
///
/// 当素材文件夹被移动到新路径后，数据库中的绝对路径会过期。
/// 此命令检测不匹配并执行前缀替换。
struct RebaseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rebase",
        abstract: "检测并修复文件夹库中的路径不匹配"
    )

    @Option(name: .long, help: "素材文件夹路径 (当前实际路径)")
    var folder: String

    @Flag(name: .long, help: "仅检测，不执行修复")
    var dryRun: Bool = false

    @Option(name: .long, help: "输出格式: text, json")
    var format: OutputFormat = .text

    func run() throws {
        let folderPath = (folder as NSString).standardizingPath
        let folderDB = try DatabaseManager.openFolderDatabase(at: folderPath)

        let mismatch = try PathRebaser.detectMismatch(folderDB: folderDB, newPath: folderPath)

        if dryRun || format == .json {
            switch format {
            case .json:
                struct RebaseStatus: Codable {
                    let needsRebase: Bool
                    let oldPath: String?
                    let newPath: String
                    let dryRun: Bool
                }
                try JSONOutput.print(RebaseStatus(
                    needsRebase: mismatch != nil,
                    oldPath: mismatch,
                    newPath: folderPath,
                    dryRun: dryRun
                ))
                if !dryRun, mismatch != nil {
                    // JSON 模式下非 dry-run 仍需执行
                    let result = try PathRebaser.rebase(
                        folderDB: folderDB,
                        oldPath: mismatch!,
                        newPath: folderPath
                    )
                    struct RebaseOutput: Codable {
                        let oldPath: String
                        let newPath: String
                        let rebasedVideos: Int
                        let rebasedClips: Int
                    }
                    try JSONOutput.print(RebaseOutput(
                        oldPath: result.oldPath,
                        newPath: result.newPath,
                        rebasedVideos: result.rebasedVideos,
                        rebasedClips: result.rebasedClips
                    ))
                }
            case .text:
                // dry-run text
                if let old = mismatch {
                    print("检测到路径不匹配:")
                    print("  旧路径: \(old)")
                    print("  新路径: \(folderPath)")
                    print("\n使用 findit-cli rebase --folder \(folderPath) 执行修复")
                } else {
                    print("路径一致，无需重定向")
                }
            }
            return
        }

        // 执行 rebase
        guard mismatch != nil else {
            print("路径一致，无需重定向")
            return
        }

        let result = try PathRebaser.rebaseIfNeeded(folderDB: folderDB, newPath: folderPath)

        if result.didRebase {
            print("✓ 路径重定向完成:")
            print("  \(result.oldPath) → \(result.newPath)")
            print("  更新了 \(result.rebasedVideos) 个视频、\(result.rebasedClips) 个片段的路径")
        }
    }
}
