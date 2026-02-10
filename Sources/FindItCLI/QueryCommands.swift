import ArgumentParser
import Foundation
import FindItCore
import GRDB

// MARK: - JSON Output Models

/// 文件夹信息
struct FolderInfo: Codable {
    let folderPath: String
    let videoCount: Int
    let clipCount: Int
}

/// 视频信息
struct VideoInfo: Codable {
    let videoId: Int64
    let fileName: String
    let filePath: String
    let duration: Double?
    let fileSize: Int64?
    let fileHash: String?
    let indexStatus: String
    let indexError: String?
    let clipCount: Int
    let createdAt: String?
    let indexedAt: String?
    let orphanedAt: String?
    let srtPath: String?
}

/// Clip 完整详情
struct ClipDetail: Codable {
    let clipId: Int64
    let videoId: Int64
    let startTime: Double
    let endTime: Double
    let duration: Double
    let scene: String?
    let subjects: String?
    let actions: String?
    let objects: String?
    let mood: String?
    let shotType: String?
    let lighting: String?
    let colors: String?
    let description: String?
    let tags: [String]
    let transcript: String?
    let userTags: [String]
    let rating: Int
    let colorLabel: String?
    let thumbnailPath: String?
    let hasEmbedding: Bool
    let embeddingModel: String?
    let createdAt: String
}

/// 视频详情（含 clip 列表）
struct VideoDetailOutput: Codable {
    let video: VideoInfo
    let clips: [ClipSummaryOutput]
}

/// Clip 摘要（视频详情中使用）
struct ClipSummaryOutput: Codable {
    let clipId: Int64
    let startTime: Double
    let endTime: Double
    let scene: String?
    let description: String?
    let tags: [String]
    let rating: Int
    let colorLabel: String?
}

/// 文件夹统计信息
struct FolderStatsOutput: Codable {
    let folderPath: String
    let totalVideos: Int
    let statusDistribution: [String: Int]
    let totalClips: Int
    let clipsWithEmbedding: Int
    let clipsWithTranscript: Int
    let clipsWithDescription: Int
    let totalDuration: Double
    let totalFileSize: Int64
}

// MARK: - folders

/// 列出所有已索引的素材文件夹
///
/// 从全局搜索索引读取已同步的文件夹列表及统计信息。
/// 仅显示已通过 `sync` 或 `index` 同步到全局库的数据。
struct FoldersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "folders",
        abstract: "列出所有已索引的素材文件夹及统计"
    )

    @Option(name: .long, help: "输出格式: text, json")
    var format: OutputFormat = .text

    func run() throws {
        let globalDB = try DatabaseManager.openGlobalDatabase()

        let folders: [FolderInfo] = try globalDB.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT v.source_folder,
                       COUNT(DISTINCT v.video_id) as video_count,
                       COUNT(c.clip_id) as clip_count
                FROM videos v
                LEFT JOIN clips c ON c.video_id = v.video_id
                GROUP BY v.source_folder
                ORDER BY v.source_folder
                """)
            return rows.map { row in
                FolderInfo(
                    folderPath: row["source_folder"],
                    videoCount: row["video_count"],
                    clipCount: row["clip_count"]
                )
            }
        }

        switch format {
        case .json:
            try JSONOutput.print(folders)
        case .text:
            if folders.isEmpty {
                print("全局索引中无已同步的文件夹")
                print("提示: 使用 findit-cli index --folder <path> 索引视频后再试")
                return
            }
            print("已索引的素材文件夹 (\(folders.count) 个):\n")
            for (i, f) in folders.enumerated() {
                print("[\(i + 1)] \(f.folderPath)")
                print("    视频: \(f.videoCount)  片段: \(f.clipCount)")
            }
        }
    }
}

// MARK: - videos

/// 列出文件夹中的视频及索引状态
///
/// 从文件夹级数据库读取所有视频记录，支持按状态过滤。
struct VideosCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "videos",
        abstract: "列出文件夹中的视频及索引状态"
    )

    @Option(name: .long, help: "素材文件夹路径")
    var folder: String

    @Option(name: .long, help: "按状态过滤: pending, completed, failed, orphaned")
    var status: String?

    @Option(name: .long, help: "输出格式: text, json")
    var format: OutputFormat = .text

    func run() throws {
        let folderPath = (folder as NSString).standardizingPath
        let folderDB = try DatabaseManager.openFolderDatabase(at: folderPath)

        let videos: [VideoInfo] = try folderDB.read { db in
            let allVideos: [Video]
            if let status = status {
                allVideos = try Video.fetchByStatus(db, status: status)
            } else {
                allVideos = try Video.order(Column("video_id")).fetchAll(db)
            }

            return try allVideos.map { video in
                let clipCount = try Int.fetchOne(db, sql:
                    "SELECT COUNT(*) FROM clips WHERE video_id = ?",
                    arguments: [video.videoId]) ?? 0
                return VideoInfo(
                    videoId: video.videoId ?? 0,
                    fileName: video.fileName,
                    filePath: video.filePath,
                    duration: video.duration,
                    fileSize: video.fileSize,
                    fileHash: video.fileHash,
                    indexStatus: video.indexStatus,
                    indexError: video.indexError,
                    clipCount: clipCount,
                    createdAt: video.createdAt,
                    indexedAt: video.indexedAt,
                    orphanedAt: video.orphanedAt,
                    srtPath: video.srtPath
                )
            }
        }

        switch format {
        case .json:
            try JSONOutput.print(videos)
        case .text:
            let statusDesc = status.map { " (状态: \($0))" } ?? ""
            if videos.isEmpty {
                print("无视频记录\(statusDesc)")
                return
            }
            print("\(folderPath) 中的视频\(statusDesc) (\(videos.count) 个):\n")
            for v in videos {
                let durStr = v.duration.map { CLIHelpers.formatTime($0) } ?? "?"
                let sizeStr = v.fileSize.map { CLIHelpers.formatFileSize($0) } ?? "?"
                let statusIcon = Self.statusIcon(v.indexStatus)
                print("\(statusIcon) [\(v.videoId)] \(v.fileName)")
                print("    时长: \(durStr)  大小: \(sizeStr)  片段: \(v.clipCount)  状态: \(v.indexStatus)")
                if let err = v.indexError {
                    print("    错误: \(err)")
                }
            }
        }
    }

    static func statusIcon(_ status: String) -> String {
        switch status {
        case "completed": return "✓"
        case "pending":   return "○"
        case "failed":    return "✗"
        case "orphaned":  return "⊘"
        default:          return "?"
        }
    }
}

// MARK: - clip

/// 显示片段的完整详细信息
///
/// 输出 clip 的所有 20+ 字段，包括视觉分析结果、标签、转录、
/// 评分、颜色标签、嵌入状态等。用于调试和数据验证。
struct ClipCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clip",
        abstract: "显示片段的完整详细信息"
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
            print("错误: 未找到 clip_id=\(clipId) (文件夹: \(folderPath))")
            throw ExitCode.failure
        }

        let detail = ClipDetail(
            clipId: clip.clipId ?? 0,
            videoId: clip.videoId ?? 0,
            startTime: clip.startTime,
            endTime: clip.endTime,
            duration: clip.endTime - clip.startTime,
            scene: clip.scene,
            subjects: clip.subjects,
            actions: clip.actions,
            objects: clip.objects,
            mood: clip.mood,
            shotType: clip.shotType,
            lighting: clip.lighting,
            colors: clip.colors,
            description: clip.clipDescription,
            tags: clip.tagsArray,
            transcript: clip.transcript,
            userTags: clip.userTagsArray,
            rating: clip.rating,
            colorLabel: clip.colorLabel,
            thumbnailPath: clip.thumbnailPath,
            hasEmbedding: clip.embedding != nil,
            embeddingModel: clip.embeddingModel,
            createdAt: clip.createdAt
        )

        switch format {
        case .json:
            try JSONOutput.print(detail)
        case .text:
            let timeRange = CLIHelpers.formatTime(detail.startTime) + " → " + CLIHelpers.formatTime(detail.endTime)
            print("Clip #\(detail.clipId) (video_id=\(detail.videoId))")
            print("时间: \(timeRange) (\(String(format: "%.1f", detail.duration))s)")
            print()

            // Vision 分析字段
            if let v = detail.scene       { print("场景:     \(v)") }
            if let v = detail.description { print("描述:     \(v)") }
            if let v = detail.subjects    { print("主体:     \(v)") }
            if let v = detail.actions     { print("动作:     \(v)") }
            if let v = detail.objects     { print("物体:     \(v)") }
            if let v = detail.mood        { print("情绪:     \(v)") }
            if let v = detail.shotType    { print("镜头:     \(v)") }
            if let v = detail.lighting    { print("光线:     \(v)") }
            if let v = detail.colors      { print("色彩:     \(v)") }

            // 标签
            if !detail.tags.isEmpty {
                print("标签:     \(detail.tags.joined(separator: ", "))")
            }
            if !detail.userTags.isEmpty {
                print("用户标签: \(detail.userTags.joined(separator: ", "))")
            }

            // 转录
            if let t = detail.transcript {
                print("转录:     \(t)")
            }

            // 评分与颜色
            if detail.rating > 0 {
                let stars = String(repeating: "★", count: detail.rating)
                    + String(repeating: "☆", count: 5 - detail.rating)
                print("评分:     \(stars)")
            }
            if let c = detail.colorLabel {
                print("颜色标签: \(c)")
            }

            // 嵌入
            print("嵌入:     \(detail.hasEmbedding ? "✓ (\(detail.embeddingModel ?? "?"))" : "无")")

            // 缩略图
            if let t = detail.thumbnailPath {
                print("缩略图:   \(t)")
            }
        }
    }
}

// MARK: - video

/// 显示视频详情及其所有片段
///
/// 可自动从视频路径检测文件夹库，也可通过 `--folder` 显式指定。
/// 输出视频元数据和所有关联 clip 的摘要列表。
struct VideoDetailCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "video",
        abstract: "显示视频详情及其所有片段"
    )

    @Argument(help: "视频文件路径")
    var path: String

    @Option(name: .long, help: "素材文件夹路径 (省略则自动检测)")
    var folder: String?

    @Option(name: .long, help: "输出格式: text, json")
    var format: OutputFormat = .text

    func run() throws {
        let videoPath = (path as NSString).standardizingPath

        // 确定文件夹路径
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

        guard let video = try folderDB.read({ db in
            try Video.fetchByPath(db, path: videoPath)
        }) else {
            print("错误: 未找到视频记录: \(videoPath)")
            throw ExitCode.failure
        }

        guard let videoId = video.videoId else {
            print("错误: 视频记录缺少 ID")
            throw ExitCode.failure
        }

        let clips = try folderDB.read { db in
            try Clip.fetchAll(forVideo: videoId, in: db)
        }

        let videoInfo = VideoInfo(
            videoId: videoId,
            fileName: video.fileName,
            filePath: video.filePath,
            duration: video.duration,
            fileSize: video.fileSize,
            fileHash: video.fileHash,
            indexStatus: video.indexStatus,
            indexError: video.indexError,
            clipCount: clips.count,
            createdAt: video.createdAt,
            indexedAt: video.indexedAt,
            orphanedAt: video.orphanedAt,
            srtPath: video.srtPath
        )

        let clipSummaries = clips.map { clip in
            ClipSummaryOutput(
                clipId: clip.clipId ?? 0,
                startTime: clip.startTime,
                endTime: clip.endTime,
                scene: clip.scene,
                description: clip.clipDescription,
                tags: clip.tagsArray,
                rating: clip.rating,
                colorLabel: clip.colorLabel
            )
        }

        let output = VideoDetailOutput(video: videoInfo, clips: clipSummaries)

        switch format {
        case .json:
            try JSONOutput.print(output)
        case .text:
            let statusIcon = VideosCommand.statusIcon(video.indexStatus)
            print("\(video.fileName) [\(statusIcon) \(video.indexStatus)]")
            print("路径:   \(video.filePath)")
            if let d = video.duration { print("时长:   \(CLIHelpers.formatTime(d))") }
            if let s = video.fileSize { print("大小:   \(CLIHelpers.formatFileSize(s))") }
            if let h = video.fileHash { print("Hash:   \(h)") }
            if let t = video.indexedAt { print("索引于: \(t)") }
            if let e = video.indexError { print("错误:   \(e)") }
            if let s = video.srtPath { print("SRT:    \(s)") }

            if clips.isEmpty {
                print("\n无片段数据")
            } else {
                print("\n片段 (\(clips.count) 个):")
                for clip in clips {
                    let id = clip.clipId ?? 0
                    let time = CLIHelpers.formatTime(clip.startTime) + " → " + CLIHelpers.formatTime(clip.endTime)
                    let scene = clip.scene ?? "未命名"
                    print("  [\(id)] \(time) | \(scene)")
                    if let desc = clip.clipDescription {
                        let preview = desc.prefix(60)
                        print("         \(preview)\(desc.count > 60 ? "..." : "")")
                    }
                }
            }
        }
    }
}

// MARK: - stats

/// 显示文件夹的索引统计信息
///
/// 输出视频状态分布、片段覆盖率（嵌入/转录/描述）、总时长和大小。
/// 用于评估索引完成度和数据质量。
struct StatsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "显示文件夹的索引统计信息"
    )

    @Option(name: .long, help: "素材文件夹路径")
    var folder: String

    @Option(name: .long, help: "输出格式: text, json")
    var format: OutputFormat = .text

    func run() throws {
        let folderPath = (folder as NSString).standardizingPath
        let folderDB = try DatabaseManager.openFolderDatabase(at: folderPath)

        let stats: FolderStatsOutput = try folderDB.read { db in
            // 视频状态分布
            let statusRows = try Row.fetchAll(db, sql: """
                SELECT index_status, COUNT(*) as cnt
                FROM videos GROUP BY index_status
                """)
            var statusDist: [String: Int] = [:]
            var totalVideos = 0
            for row in statusRows {
                let status: String = row["index_status"]
                let count: Int = row["cnt"]
                statusDist[status] = count
                totalVideos += count
            }

            // Clip 统计
            let totalClips = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM clips") ?? 0
            let withEmbedding = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM clips WHERE embedding IS NOT NULL") ?? 0
            let withTranscript = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM clips WHERE transcript IS NOT NULL AND transcript != ''") ?? 0
            let withDescription = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM clips WHERE description IS NOT NULL AND description != ''") ?? 0

            // 总时长和大小（排除 orphaned）
            let totalDuration = try Double.fetchOne(db, sql:
                "SELECT COALESCE(SUM(duration), 0) FROM videos WHERE index_status != 'orphaned'") ?? 0
            let totalSize = try Int64.fetchOne(db, sql:
                "SELECT COALESCE(SUM(file_size), 0) FROM videos WHERE index_status != 'orphaned'") ?? 0

            return FolderStatsOutput(
                folderPath: folderPath,
                totalVideos: totalVideos,
                statusDistribution: statusDist,
                totalClips: totalClips,
                clipsWithEmbedding: withEmbedding,
                clipsWithTranscript: withTranscript,
                clipsWithDescription: withDescription,
                totalDuration: totalDuration,
                totalFileSize: totalSize
            )
        }

        switch format {
        case .json:
            try JSONOutput.print(stats)
        case .text:
            print("文件夹统计: \(stats.folderPath)\n")

            // 视频
            print("视频: \(stats.totalVideos) 个")
            for (status, count) in stats.statusDistribution.sorted(by: { $0.key < $1.key }) {
                let icon = VideosCommand.statusIcon(status)
                print("  \(icon) \(status): \(count)")
            }

            // 片段
            print("\n片段: \(stats.totalClips) 个")
            if stats.totalClips > 0 {
                let total = Double(stats.totalClips)
                let embPct = String(format: "%.0f%%", Double(stats.clipsWithEmbedding) / total * 100)
                let transPct = String(format: "%.0f%%", Double(stats.clipsWithTranscript) / total * 100)
                let descPct = String(format: "%.0f%%", Double(stats.clipsWithDescription) / total * 100)
                print("  有嵌入: \(stats.clipsWithEmbedding) (\(embPct))")
                print("  有转录: \(stats.clipsWithTranscript) (\(transPct))")
                print("  有描述: \(stats.clipsWithDescription) (\(descPct))")
            }

            // 总量
            print("\n总时长: \(CLIHelpers.formatTime(stats.totalDuration))")
            print("总大小: \(CLIHelpers.formatFileSize(stats.totalFileSize))")
        }
    }
}
