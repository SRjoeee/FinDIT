import ArgumentParser
import Foundation
import FindItCore
import GRDB

@main
struct FindItCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "findit-cli",
        abstract: "FindIt 命令行工具 — 视频素材索引与搜索",
        version: FindIt.version,
        subcommands: [
            InfoCommand.self,
            DbInitCommand.self,
            InsertMockCommand.self,
            SyncCommand.self,
            SearchCommand.self,
        ]
    )
}

// MARK: - info

struct InfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "显示 FindIt 版本和环境信息"
    )

    func run() {
        print("FindIt v\(FindIt.version)")
        print("核心库已就绪")
    }
}

// MARK: - db-init

struct DbInitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "db-init",
        abstract: "初始化数据库（文件夹级 + 全局索引）"
    )

    @Option(name: .long, help: "素材文件夹路径")
    var folder: String

    func run() throws {
        let folderPath = (folder as NSString).standardizingPath

        // 1. 打开/创建文件夹级数据库
        let folderDB = try DatabaseManager.openFolderDatabase(at: folderPath)
        print("✓ 文件夹库已就绪: \(folderPath)/.clip-index/index.sqlite")

        // 2. 注册 WatchedFolder
        try folderDB.write { db in
            let existing = try WatchedFolder.fetchByPath(db, path: folderPath)
            if existing != nil {
                print("  (文件夹已注册，跳过)")
            } else {
                var folder = WatchedFolder(folderPath: folderPath)
                try folder.insert(db)
                print("  已注册监控文件夹 (folder_id=\(folder.folderId!))")
            }
        }

        // 3. 打开/创建全局搜索索引
        _ = try DatabaseManager.openGlobalDatabase()
        print("✓ 全局搜索索引已就绪: ~/Library/Application Support/FindIt/search.sqlite")
    }
}

// MARK: - insert-mock

struct InsertMockCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "insert-mock",
        abstract: "插入模拟测试数据到文件夹库"
    )

    @Option(name: .long, help: "素材文件夹路径")
    var folder: String

    func run() throws {
        let folderPath = (folder as NSString).standardizingPath
        let folderDB = try DatabaseManager.openFolderDatabase(at: folderPath)

        try folderDB.write { db in
            // 确保文件夹已注册
            let watchedFolder: WatchedFolder
            if let existing = try WatchedFolder.fetchByPath(db, path: folderPath) {
                watchedFolder = existing
            } else {
                var newFolder = WatchedFolder(folderPath: folderPath)
                try newFolder.insert(db)
                watchedFolder = newFolder
            }
            let folderId = watchedFolder.folderId!

            // --- Video 1: 海滩日落 ---
            var video1 = Video(
                folderId: folderId,
                filePath: "\(folderPath)/beach_sunset.mp4",
                fileName: "beach_sunset.mp4",
                duration: 180.0,
                fileSize: 52_000_000
            )
            try video1.insert(db)

            var clip1a = Clip(
                videoId: video1.videoId,
                startTime: 0.0, endTime: 5.5,
                scene: "海滩日落",
                clipDescription: "金色夕阳下的沙滩，海浪轻拍岸边"
            )
            clip1a.setTags(["海滩", "日落", "户外", "暖色调", "全景"])
            try clip1a.insert(db)

            var clip1b = Clip(
                videoId: video1.videoId,
                startTime: 5.5, endTime: 12.0,
                scene: "海滩人像",
                clipDescription: "A young woman walking along the shoreline at golden hour",
                transcript: "the waves are so peaceful"
            )
            clip1b.setTags(["海滩", "人像", "黄金时刻", "中景"])
            try clip1b.insert(db)

            var clip1c = Clip(
                videoId: video1.videoId,
                startTime: 12.0, endTime: 18.0,
                scene: "海浪特写",
                clipDescription: "碧蓝海水冲刷白色沙滩的慢动作镜头"
            )
            clip1c.setTags(["海浪", "特写", "慢动作", "自然"])
            try clip1c.insert(db)

            print("  视频 1: beach_sunset.mp4 (3 个片段)")

            // --- Video 2: 城市夜景 ---
            var video2 = Video(
                folderId: folderId,
                filePath: "\(folderPath)/city_night.mp4",
                fileName: "city_night.mp4",
                duration: 240.0,
                fileSize: 78_000_000
            )
            try video2.insert(db)

            var clip2a = Clip(
                videoId: video2.videoId,
                startTime: 0.0, endTime: 8.0,
                scene: "城市夜景",
                clipDescription: "霓虹灯闪烁的都市街道，车流穿梭",
                transcript: "这里是上海最繁华的南京路"
            )
            clip2a.setTags(["城市", "夜景", "霓虹灯", "冷色调", "全景"])
            try clip2a.insert(db)

            var clip2b = Clip(
                videoId: video2.videoId,
                startTime: 8.0, endTime: 15.0,
                scene: "街头美食",
                clipDescription: "小摊贩在夜市中制作煎饼果子，蒸汽升腾"
            )
            clip2b.setTags(["美食", "街头", "夜市", "暖色调", "中景"])
            try clip2b.insert(db)

            print("  视频 2: city_night.mp4 (2 个片段)")

            // --- Video 3: 森林晨雾 ---
            var video3 = Video(
                folderId: folderId,
                filePath: "\(folderPath)/forest_morning.mp4",
                fileName: "forest_morning.mp4",
                duration: 120.0,
                fileSize: 35_000_000
            )
            try video3.insert(db)

            var clip3a = Clip(
                videoId: video3.videoId,
                startTime: 0.0, endTime: 10.0,
                scene: "森林晨雾",
                clipDescription: "清晨薄雾笼罩的森林，阳光穿透树叶"
            )
            clip3a.setTags(["森林", "晨雾", "自然", "绿色", "全景"])
            try clip3a.insert(db)

            var clip3b = Clip(
                videoId: video3.videoId,
                startTime: 10.0, endTime: 18.0,
                scene: "小溪流水",
                clipDescription: "Crystal clear stream flowing over mossy rocks in the forest",
                transcript: "listen to the sound of nature"
            )
            clip3b.setTags(["小溪", "森林", "自然", "流水", "特写"])
            try clip3b.insert(db)

            print("  视频 3: forest_morning.mp4 (2 个片段)")

            // 更新进度
            var updatedFolder = watchedFolder
            try updatedFolder.updateProgress(db, totalFiles: 3, indexedFiles: 3)
        }

        print("✓ 已插入 3 个视频、7 个片段到文件夹库")
    }
}

// MARK: - sync

struct SyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "将文件夹库同步到全局搜索索引"
    )

    @Option(name: .long, help: "素材文件夹路径")
    var folder: String

    func run() throws {
        let folderPath = (folder as NSString).standardizingPath
        let folderDB = try DatabaseManager.openFolderDatabase(at: folderPath)
        let globalDB = try DatabaseManager.openGlobalDatabase()

        let result = try SyncEngine.sync(
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB
        )

        if result.syncedVideos == 0 && result.syncedClips == 0 {
            print("无新数据需要同步")
        } else {
            print("✓ 同步完成: \(result.syncedVideos) 个视频, \(result.syncedClips) 个片段")
        }
    }
}

// MARK: - search

struct SearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "在全局索引中搜索视频片段"
    )

    @Argument(help: "搜索关键词（支持 FTS5 语法）")
    var query: String

    @Option(name: .shortAndLong, help: "最大结果数")
    var limit: Int = 20

    func run() throws {
        let globalDB = try DatabaseManager.openGlobalDatabase()

        let results = try globalDB.read { db in
            try SearchEngine.search(db, query: query, limit: limit)
        }

        if results.isEmpty {
            print("未找到匹配「\(query)」的结果")
            return
        }

        print("找到 \(results.count) 个结果:\n")

        for (i, r) in results.enumerated() {
            let timeRange = formatTime(r.startTime) + " → " + formatTime(r.endTime)
            print("[\(i + 1)] \(r.scene ?? "未命名") (\(timeRange))")
            if let file = r.fileName {
                print("    文件: \(file)")
            }
            if let desc = r.clipDescription {
                print("    描述: \(desc)")
            }
            if let tags = r.tags {
                print("    标签: \(tags)")
            }
            if let transcript = r.transcript {
                print("    转录: \(transcript)")
            }
            print("    相关度: \(String(format: "%.4f", r.rank))")
            print()
        }

        // 记录搜索历史
        try globalDB.write { db in
            try SearchEngine.recordSearch(db, query: query, resultCount: results.count)
        }
    }

    /// 秒数格式化为 mm:ss
    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
