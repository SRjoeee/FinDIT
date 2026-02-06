import ArgumentParser
import Foundation
import FindItCore
import GRDB

@main
struct FindItCLI: AsyncParsableCommand {
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
            FFmpegCheckCommand.self,
            ExtractAudioCommand.self,
            DetectScenesCommand.self,
            ExtractKeyframesCommand.self,
            TranscribeCommand.self,
            AnalyzeCommand.self,
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

// MARK: - ffmpeg-check

struct FFmpegCheckCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ffmpeg-check",
        abstract: "验证 FFmpeg 可用性和版本"
    )

    @Option(name: .long, help: "FFmpeg 路径 (默认 ~/.local/bin/ffmpeg)")
    var ffmpegPath: String?

    func run() throws {
        let config = ffmpegPath.map { FFmpegConfig(ffmpegPath: $0) } ?? .default
        try FFmpegBridge.validateExecutable(config: config)
        let version = try FFmpegBridge.version(config: config)
        print("✓ \(version)")
        print("  路径: \(config.ffmpegPath)")
    }
}

// MARK: - extract-audio

struct ExtractAudioCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extract-audio",
        abstract: "从视频提取 16kHz mono WAV 音频"
    )

    @Option(name: .long, help: "视频文件路径")
    var input: String

    @Option(name: .long, help: "输出 WAV 路径 (默认: 同目录同名.wav)")
    var output: String?

    func run() throws {
        let inputPath = (input as NSString).standardizingPath
        let outputPath = output ?? {
            let url = URL(fileURLWithPath: inputPath)
            return url.deletingPathExtension().appendingPathExtension("wav").path
        }()

        print("提取音频: \(inputPath)")
        let result = try AudioExtractor.extractAudio(inputPath: inputPath, outputPath: outputPath)

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: result)[.size] as? Int64) ?? 0
        let sizeMB = String(format: "%.1f", Double(fileSize) / 1_000_000)
        print("✓ 输出: \(result) (\(sizeMB) MB)")
    }
}

// MARK: - detect-scenes

struct DetectScenesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "detect-scenes",
        abstract: "检测视频场景切换点"
    )

    @Option(name: .long, help: "视频文件路径")
    var input: String

    @Option(name: .long, help: "场景检测阈值 (0-1, 默认 0.3)")
    var threshold: Double = 0.3

    func run() throws {
        let inputPath = (input as NSString).standardizingPath
        print("场景检测: \(inputPath) (阈值: \(threshold))")

        let config = SceneDetector.Config(threshold: threshold)
        let segments = try SceneDetector.detectScenes(inputPath: inputPath, config: config)

        if segments.isEmpty {
            print("未检测到场景")
            return
        }

        print("检测到 \(segments.count) 个场景:\n")
        for (i, seg) in segments.enumerated() {
            let start = formatTimecode(seg.startTime)
            let end = formatTimecode(seg.endTime)
            print("  [\(i + 1)] \(start) → \(end) (\(String(format: "%.1f", seg.duration))s)")
        }

        let totalDuration = segments.last!.endTime
        print("\n总时长: \(formatTimecode(totalDuration))")
    }

    private func formatTimecode(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%d:%02d.%02d", m, s, ms)
    }
}

// MARK: - extract-keyframes

struct ExtractKeyframesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extract-keyframes",
        abstract: "提取场景关键帧缩略图"
    )

    @Option(name: .long, help: "视频文件路径")
    var input: String

    @Option(name: .long, help: "输出目录 (默认: 同目录下 <视频名>_frames/)")
    var outputDir: String?

    @Option(name: .long, help: "场景检测阈值")
    var threshold: Double = 0.3

    func run() throws {
        let inputPath = (input as NSString).standardizingPath

        let outDir = outputDir ?? {
            let url = URL(fileURLWithPath: inputPath)
            let name = url.deletingPathExtension().lastPathComponent
            return url.deletingLastPathComponent().appendingPathComponent("\(name)_frames").path
        }()

        // 1. 场景检测
        print("场景检测中...")
        let sceneConfig = SceneDetector.Config(threshold: threshold)
        let segments = try SceneDetector.detectScenes(inputPath: inputPath, config: sceneConfig)
        print("  检测到 \(segments.count) 个场景")

        // 2. 关键帧提取
        print("提取关键帧...")
        let frames = try KeyframeExtractor.extractKeyframes(
            inputPath: inputPath,
            segments: segments,
            outputDirectory: outDir
        )

        print("✓ 提取 \(frames.count) 个关键帧到: \(outDir)")
        for frame in frames {
            let ts = String(format: "%.2f", frame.timestamp)
            print("  场景\(frame.sceneIndex): \(ts)s → \(URL(fileURLWithPath: frame.filePath).lastPathComponent)")
        }
    }
}

// MARK: - transcribe

struct TranscribeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "转录视频音频为 SRT 字幕文件"
    )

    @Option(name: .long, help: "视频文件路径")
    var input: String

    @Option(name: .long, help: "WAV 音频路径 (默认: 自动从视频提取)")
    var audio: String?

    @Option(name: .long, help: "WhisperKit 模型名 (默认: large-v3)")
    var model: String = "large-v3"

    @Option(name: .long, help: "语言代码，如 zh/en (默认: 自动检测)")
    var language: String?

    func run() async throws {
        let inputPath = (input as NSString).standardizingPath

        // 1. 提取或使用提供的音频
        let audioPath: String
        if let providedAudio = audio {
            audioPath = (providedAudio as NSString).standardizingPath
        } else {
            let url = URL(fileURLWithPath: inputPath)
            let wavPath = url.deletingPathExtension().appendingPathExtension("wav").path
            print("提取音频: \(inputPath)")
            try AudioExtractor.extractAudio(inputPath: inputPath, outputPath: wavPath)
            audioPath = wavPath
            print("✓ 音频提取完成")
        }

        // 2. 初始化 WhisperKit
        let config = STTProcessor.Config(modelName: model, language: language)
        print("初始化 WhisperKit (模型: \(config.modelName))...")
        let whisperKit = try await STTProcessor.initializeWhisperKit(config: config)
        print("✓ 模型加载完成")

        // 3. 转录并保存 SRT
        print("转录中...")
        let (segments, srtPath) = try await STTProcessor.transcribeAndSaveSRT(
            audioPath: audioPath,
            videoPath: inputPath,
            whisperKit: whisperKit,
            config: config
        )

        print("✓ 转录完成: \(segments.count) 个片段")
        print("  SRT 文件: \(srtPath)")

        // 4. 预览前几个片段
        let preview = segments.prefix(5)
        print()
        for seg in preview {
            let start = STTProcessor.formatSRTTimestamp(seg.startTime)
            let end = STTProcessor.formatSRTTimestamp(seg.endTime)
            print("  [\(seg.index)] \(start) --> \(end)")
            print("    \(seg.text)")
        }
        if segments.count > 5 {
            print("  ... 共 \(segments.count) 个片段")
        }
    }
}

// MARK: - analyze

struct AnalyzeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "使用 Gemini Flash 分析视频场景关键帧"
    )

    @Option(name: .long, help: "视频文件路径（用于显示信息）")
    var input: String

    @Option(name: .long, help: "关键帧目录路径（包含 scene_XXX_frame_YY.jpg）")
    var framesDir: String

    @Option(name: .long, help: "Gemini API Key（覆盖配置文件）")
    var apiKey: String?

    @Option(name: .long, help: "Gemini 模型名称 (默认: gemini-2.5-flash)")
    var model: String = "gemini-2.5-flash"

    func run() async throws {
        // 1. 解析 API Key
        let resolvedKey: String
        do {
            resolvedKey = try VisionAnalyzer.resolveAPIKey(override: apiKey)
        } catch {
            print("错误: \(error.localizedDescription)")
            print()
            print("设置 API Key 的方法:")
            print("  1. mkdir -p ~/.config/findit")
            print("  2. 将 Key 写入 ~/.config/findit/gemini-api-key.txt")
            print("  或使用 --api-key <key> 参数")
            throw ExitCode.failure
        }

        // 2. 扫描关键帧目录，按场景分组
        let framesDirPath = (framesDir as NSString).standardizingPath
        let sceneGroups = try groupFramesByScene(directory: framesDirPath)

        if sceneGroups.isEmpty {
            print("错误: 在 \(framesDirPath) 中未找到 scene_XXX_frame_YY.jpg 格式的关键帧")
            throw ExitCode.failure
        }

        let config = VisionAnalyzer.Config(model: model)
        print("分析 \(sceneGroups.count) 个场景 (模型: \(config.model))")
        print("视频: \(input)")
        print()

        // 3. 逐场景分析
        var results: [(sceneIndex: Int, result: AnalysisResult)] = []

        for (i, (sceneIndex, framePaths)) in sceneGroups.enumerated() {
            print("  场景 \(sceneIndex): \(framePaths.count) 帧...", terminator: "")

            do {
                let result = try await VisionAnalyzer.analyzeScene(
                    imagePaths: framePaths,
                    apiKey: resolvedKey,
                    config: config
                )
                results.append((sceneIndex, result))
                print(" ✓")
            } catch {
                print(" ✗ \(error.localizedDescription)")
            }

            // 速率控制: 7 秒间隔 (10 RPM 限制)
            if i < sceneGroups.count - 1 {
                try await Task.sleep(nanoseconds: 7_000_000_000)
            }
        }

        // 4. 输出结果
        print()
        print("✓ 分析完成: \(results.count)/\(sceneGroups.count) 个场景")
        print()

        for (sceneIndex, result) in results {
            print("── 场景 \(sceneIndex) ──")
            if let scene = result.scene { print("  场景: \(scene)") }
            if !result.subjects.isEmpty { print("  主体: \(result.subjects.joined(separator: ", "))") }
            if !result.actions.isEmpty { print("  动作: \(result.actions.joined(separator: ", "))") }
            if !result.objects.isEmpty { print("  物体: \(result.objects.joined(separator: ", "))") }
            if let mood = result.mood { print("  氛围: \(mood)") }
            if let shotType = result.shotType { print("  镜头: \(shotType)") }
            if let lighting = result.lighting { print("  光线: \(lighting)") }
            if let colors = result.colors { print("  色调: \(colors)") }
            if let desc = result.description { print("  描述: \(desc)") }
            print("  标签: \(result.tags.joined(separator: ", "))")
            print()
        }
    }

    /// 扫描目录，按 scene_XXX_frame_YY.jpg 命名分组
    ///
    /// - Returns: 按场景索引排序的 (sceneIndex, [framePath]) 数组
    private func groupFramesByScene(directory: String) throws -> [(Int, [String])] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory) else {
            throw VisionAnalyzerError.imageEncodingFailed(path: directory)
        }

        let files = try fm.contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".jpeg") }
            .sorted()

        // 解析 scene_XXX_frame_YY.jpg 格式
        var groups: [Int: [String]] = [:]
        for file in files {
            let name = (file as NSString).deletingPathExtension
            let parts = name.components(separatedBy: "_")
            // 期望: ["scene", "XXX", "frame", "YY"]
            guard parts.count >= 4,
                  parts[0] == "scene",
                  let sceneIndex = Int(parts[1]) else {
                continue
            }
            let fullPath = (directory as NSString).appendingPathComponent(file)
            groups[sceneIndex, default: []].append(fullPath)
        }

        return groups.sorted { $0.key < $1.key }
    }
}
