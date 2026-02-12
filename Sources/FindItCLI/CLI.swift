import ArgumentParser
import Foundation
import FindItCore
import GRDB
import WhisperKit

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
            IndexCommand.self,
            EmbedCommand.self,
            // Query commands
            FoldersCommand.self,
            VideosCommand.self,
            ClipCommand.self,
            VideoDetailCommand.self,
            StatsCommand.self,
            SearchHistoryCommand.self,
            // Tag & Label commands
            TagCommand.self,
            LabelCommand.self,
            // Maintenance commands
            OrphanCommand.self,
            RemoveVideoCommand.self,
            RebaseCommand.self,
            // CLIP commands
            CLIPCommand.self,
            // EmbeddingGemma commands
            GemmaCommand.self,
            // Backfill commands
            CLIPBackfillCommand.self,
            // Export commands
            ExportCommand.self,
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

    @Flag(name: .long, help: "强制全量同步（忽略增量游标，重新同步所有记录）")
    var force = false

    func run() throws {
        let folderPath = (folder as NSString).standardizingPath
        let folderDB = try DatabaseManager.openFolderDatabase(at: folderPath)
        let globalDB = try DatabaseManager.openGlobalDatabase()

        let result = try SyncEngine.sync(
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB,
            force: force
        )

        if result.syncedVideos == 0 && result.syncedClips == 0 {
            print("无新数据需要同步")
        } else {
            print("✓ 同步完成: \(result.syncedVideos) 个视频, \(result.syncedClips) 个片段")
        }
    }
}

// MARK: - search

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "在全局索引中搜索视频片段（支持 FTS5 + 向量混合搜索 + 过滤排序）"
    )

    @Argument(help: "搜索关键词")
    var query: String

    @Option(name: .shortAndLong, help: "最大结果数")
    var limit: Int = 20

    @Option(name: .long, help: "搜索模式: fts, vector, hybrid, auto (默认 auto)")
    var mode: String = "auto"

    @Option(name: .long, help: "Gemini API Key (用于向量搜索的查询嵌入)")
    var apiKey: String?

    // Filter options
    @Option(name: .long, help: "最低评分过滤 (1-5)")
    var filterRating: Int?

    @Option(name: .long, help: "颜色标签过滤，逗号分隔 (red,orange,yellow,green,blue,purple,gray)")
    var filterColor: String?

    @Option(name: .long, help: "镜头类型过滤，逗号分隔")
    var filterShot: String?

    @Option(name: .long, help: "情绪过滤，逗号分隔")
    var filterMood: String?

    // Sort options
    @Option(name: .long, help: "排序字段: relevance, date, duration, rating (默认 relevance)")
    var sort: String = "relevance"

    @Option(name: .long, help: "排序方向: asc, desc (默认 desc)")
    var sortOrder: String = "desc"

    @Option(name: .long, help: "输出格式: text, json")
    var format: OutputFormat = .text

    func run() async throws {
        let globalDB = try DatabaseManager.openGlobalDatabase()

        // 解析搜索模式
        let searchMode: SearchEngine.SearchMode
        switch mode.lowercased() {
        case "fts":     searchMode = .fts
        case "vector":  searchMode = .vector
        case "hybrid":  searchMode = .hybrid
        default:        searchMode = .auto
        }

        // 准备查询向量（如果需要语义搜索）
        var queryEmbedding: [Float]?
        var embeddingModel: String?

        if searchMode != .fts {
            // 尝试 Gemini embedding
            let providerConfig = ProviderConfig.load()
            if let apiKey = try? APIKeyManager.resolveAPIKey(override: apiKey, provider: providerConfig.provider) {
                let provider = GeminiEmbeddingProvider(apiKey: apiKey, config: providerConfig.toEmbeddingConfig())
                if provider.isAvailable() {
                    do {
                        queryEmbedding = try await provider.embed(text: query)
                        embeddingModel = provider.name
                    } catch {
                        if format == .text {
                            print("警告: Gemini 嵌入失败: \(error.localizedDescription)")
                        }
                    }
                }
            }

        }

        let finalQueryEmbedding = queryEmbedding
        let finalEmbeddingModel = embeddingModel
        var results = try await globalDB.read { db in
            try SearchEngine.hybridSearch(
                db,
                query: query,
                queryEmbedding: finalQueryEmbedding,
                embeddingModel: finalEmbeddingModel,
                mode: searchMode,
                limit: limit
            )
        }

        // 应用过滤
        let filter = buildFilter()
        if !filter.isEmpty || filter.sortBy != .relevance {
            results = FilterEngine.applyFilter(results, filter: filter)
        }

        // 输出
        switch format {
        case .json:
            try outputJSON(results, embeddingModel: embeddingModel)
        case .text:
            outputText(results, embeddingModel: embeddingModel)
        }

        // 记录搜索历史
        let resultCount = results.count
        try await globalDB.write { db in
            try SearchEngine.recordSearch(db, query: query, resultCount: resultCount)
        }
    }

    /// 构建过滤条件
    private func buildFilter() -> FilterEngine.SearchFilter {
        var colorLabels: Set<ColorLabel>?
        if let colorStr = filterColor {
            let labels = colorStr.split(separator: ",").compactMap {
                ColorLabel(rawValue: String($0).trimmingCharacters(in: .whitespaces))
            }
            if !labels.isEmpty { colorLabels = Set(labels) }
        }

        var shotTypes: Set<String>?
        if let shotStr = filterShot {
            let types = shotStr.split(separator: ",").map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            if !types.isEmpty { shotTypes = Set(types) }
        }

        var moods: Set<String>?
        if let moodStr = filterMood {
            let moodList = moodStr.split(separator: ",").map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            if !moodList.isEmpty { moods = Set(moodList) }
        }

        let sortField: FilterEngine.SortField
        switch sort.lowercased() {
        case "date":     sortField = .date
        case "duration": sortField = .duration
        case "rating":   sortField = .rating
        default:         sortField = .relevance
        }

        let order: FilterEngine.SortOrder = sortOrder.lowercased() == "asc" ? .ascending : .descending

        return FilterEngine.SearchFilter(
            minRating: filterRating,
            colorLabels: colorLabels,
            shotTypes: shotTypes,
            moods: moods,
            sortBy: sortField,
            sortOrder: order
        )
    }

    /// JSON 输出
    private func outputJSON(_ results: [SearchEngine.SearchResult], embeddingModel: String?) throws {
        struct SearchResultJSON: Codable {
            let clipId: Int64
            let sourceFolder: String
            let sourceClipId: Int64
            let videoId: Int64?
            let filePath: String?
            let fileName: String?
            let startTime: Double
            let endTime: Double
            let scene: String?
            let description: String?
            let tags: String?
            let transcript: String?
            let shotType: String?
            let mood: String?
            let rating: Int
            let colorLabel: String?
            let rank: Double
            let similarity: Double?
            let finalScore: Double?
        }

        struct SearchOutput: Codable {
            let query: String
            let mode: String
            let resultCount: Int
            let results: [SearchResultJSON]
        }

        let modeDesc = embeddingModel != nil ? "hybrid(\(embeddingModel!))" : "fts"
        let jsonResults = results.map { r in
            SearchResultJSON(
                clipId: r.clipId,
                sourceFolder: r.sourceFolder,
                sourceClipId: r.sourceClipId,
                videoId: r.videoId,
                filePath: r.filePath,
                fileName: r.fileName,
                startTime: r.startTime,
                endTime: r.endTime,
                scene: r.scene,
                description: r.clipDescription,
                tags: r.tags,
                transcript: r.transcript,
                shotType: r.shotType,
                mood: r.mood,
                rating: r.rating,
                colorLabel: r.colorLabel,
                rank: r.rank,
                similarity: r.similarity,
                finalScore: r.finalScore
            )
        }
        try JSONOutput.print(SearchOutput(
            query: query,
            mode: modeDesc,
            resultCount: results.count,
            results: jsonResults
        ))
    }

    /// Text 输出
    private func outputText(_ results: [SearchEngine.SearchResult], embeddingModel: String?) {
        if results.isEmpty {
            print("未找到匹配「\(query)」的结果")
            return
        }

        let modeDesc = embeddingModel != nil ? "混合(\(embeddingModel ?? "?"))" : "FTS5"
        print("找到 \(results.count) 个结果 (模式: \(modeDesc)):\n")

        for (i, r) in results.enumerated() {
            let timeRange = CLIHelpers.formatTime(r.startTime) + " → " + CLIHelpers.formatTime(r.endTime)
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
            // 评分/颜色
            if r.rating > 0 || r.colorLabel != nil {
                var labels: [String] = []
                if r.rating > 0 {
                    labels.append("★\(r.rating)")
                }
                if let c = r.colorLabel {
                    labels.append(c)
                }
                print("    标注: \(labels.joined(separator: " | "))")
            }
            // 分数
            var scores: [String] = []
            if r.rank != 0 {
                scores.append("FTS5: \(String(format: "%.4f", r.rank))")
            }
            if let sim = r.similarity {
                scores.append("相似度: \(String(format: "%.4f", sim))")
            }
            if let final_ = r.finalScore {
                scores.append("综合: \(String(format: "%.4f", final_))")
            }
            if !scores.isEmpty {
                print("    分数: \(scores.joined(separator: " | "))")
            }
            print()
        }
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

    @Option(name: .long, help: "WhisperKit 模型名 (默认: turbo)")
    var model: String = "openai_whisper-large-v3-v20240930"

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
        print("初始化 WhisperKit (模型: \(model))...")
        let sttConfig = STTProcessor.Config(modelName: model, language: language)
        let whisperKit = try await STTProcessor.initializeWhisperKit(config: sttConfig)
        print("✓ 模型加载完成")

        // 3. 语言检测（当 --language 未指定时）
        var resolvedLanguage = language
        if resolvedLanguage == nil {
            print("检测语言 (场景感知多段投票)...")
            // 3a. 场景检测获取边界
            let scenes = try SceneDetector.detectScenes(inputPath: inputPath)
            // 3b. 场景感知语言检测
            let langResult = try await STTProcessor.detectLanguage(
                audioPath: audioPath,
                scenes: scenes,
                whisperKit: whisperKit
            )
            resolvedLanguage = langResult.language
            let voteDetails = langResult.votes.map { "\($0.language)(\(String(format: "%.2f", $0.confidence)))" }
            print("✓ 检测到语言: \(langResult.language) (投票: \(voteDetails.joined(separator: ", ")))")
        }

        // 4. 转录并保存 SRT
        let config = STTProcessor.Config(modelName: model, language: resolvedLanguage)
        print("转录中 (语言: \(resolvedLanguage ?? "auto"))...")
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
        let providerConfig = ProviderConfig.load()
        let resolvedKey: String
        do {
            resolvedKey = try APIKeyManager.resolveAPIKey(override: apiKey, provider: providerConfig.provider)
        } catch {
            print("错误: \(error.localizedDescription)")
            print()
            print("设置 API Key 的方法:")
            print("  1. mkdir -p ~/.config/findit")
            print("  2. 将 Key 写入 \(providerConfig.provider.keyFilePath)")
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

        var config = providerConfig.toVisionConfig()
        config.model = model
        print("分析 \(sceneGroups.count) 个场景 (模型: \(config.model))")
        print("视频: \(input)")
        print()

        // 3. 逐场景分析（使用限速器控制 Gemini API 请求频率）
        let rateLimiter = GeminiRateLimiter()
        var results: [(sceneIndex: Int, result: AnalysisResult)] = []

        for (_, (sceneIndex, framePaths)) in sceneGroups.enumerated() {
            // 等待限速器许可（滑动窗口 + 429 退避）
            try await rateLimiter.waitForPermission()

            print("  场景 \(sceneIndex): \(framePaths.count) 帧...", terminator: "")

            do {
                let result = try await VisionAnalyzer.analyzeScene(
                    imagePaths: framePaths,
                    apiKey: resolvedKey,
                    config: config
                )
                results.append((sceneIndex, result))
                await rateLimiter.reportSuccess()
                print(" ✓")
            } catch let error as VisionAnalyzerError {
                if case .rateLimitExceeded = error {
                    await rateLimiter.reportRateLimit()
                }
                print(" ✗ \(error.localizedDescription)")
            } catch {
                print(" ✗ \(error.localizedDescription)")
            }
        }

        // 4. 输出结果
        print()
        print("✓ 分析完成: \(results.count)/\(sceneGroups.count) 个场景")
        print()

        for (sceneIndex, result) in results {
            print("── 场景 \(sceneIndex) ──")
            for field in VisionField.allActive {
                if let value = result.stringValue(for: field), !value.isEmpty {
                    print("  \(field.displayLabel): \(value)")
                }
            }
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

// MARK: - index

struct IndexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "索引视频文件（完整管线: 场景检测 → 关键帧 → STT → 视觉分析 → 入库）"
    )

    @Option(name: .long, help: "素材文件夹路径")
    var folder: String

    @Option(name: .long, help: "视频文件路径 (单文件模式，省略则扫描整个文件夹)")
    var input: String?

    @Option(name: .long, help: "Gemini API Key (覆盖 ~/.config/findit/gemini-api-key.txt)")
    var apiKey: String?

    @Option(name: .long, help: "WhisperKit 模型名称")
    var model: String = "openai_whisper-large-v3-v20240930"

    @Flag(name: .long, help: "跳过语音转录")
    var skipStt: Bool = false

    @Flag(name: .long, help: "跳过视觉分析")
    var skipVision: Bool = false

    @Flag(name: .long, help: "强制重新索引已完成的视频")
    var force: Bool = false

    @Flag(name: .long, help: "并行处理多个视频（基于资源池调度器）")
    var parallel: Bool = false

    @Option(name: .long, help: "性能模式: full_speed, balanced, background (默认 balanced)")
    var mode: String = "balanced"

    func run() async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        let folderPath = (folder as NSString).standardizingPath

        // 1. 打开数据库
        let folderDB = try DatabaseManager.openFolderDatabase(at: folderPath)
        let globalDB = try DatabaseManager.openGlobalDatabase()

        // 确保文件夹已注册
        try await folderDB.write { db in
            if try WatchedFolder.fetchByPath(db, path: folderPath) == nil {
                var wf = WatchedFolder(folderPath: folderPath)
                try wf.insert(db)
            }
        }

        // 2. 确定待处理的视频列表
        let videoPaths: [String]
        if let inputFile = input {
            let path = (inputFile as NSString).standardizingPath
            guard FileManager.default.fileExists(atPath: path) else {
                print("错误: 文件不存在: \(path)")
                throw ExitCode.failure
            }
            videoPaths = [path]
        } else {
            print("扫描文件夹: \(folderPath)")
            videoPaths = try FileScanner.scanVideoFiles(in: folderPath)
            print("发现 \(videoPaths.count) 个视频文件")
        }

        guard !videoPaths.isEmpty else {
            print("无视频文件需要处理")
            return
        }

        // 3. 过滤已完成的视频（除非 --force）
        let filteredPaths: [String]
        if force {
            filteredPaths = videoPaths
        } else {
            var pending: [String] = []
            for path in videoPaths {
                let existing = try await folderDB.read { db in
                    try Video.fetchByPath(db, path: path)
                }
                if existing?.indexStatus != "completed" {
                    pending.append(path)
                }
            }
            filteredPaths = pending
            if filteredPaths.count < videoPaths.count {
                print("跳过 \(videoPaths.count - filteredPaths.count) 个已完成的视频")
            }
        }

        guard !filteredPaths.isEmpty else {
            print("所有视频已索引完成")
            return
        }

        // 4. 初始化 WhisperKit（如需 STT）
        // 注意: 即使 macOS 26+ 有 SpeechAnalyzer 可做转录，
        // WhisperKit 仍需初始化用于语言检测（音频采样级别，比 NLLanguageRecognizer 准确）。
        // 未来 App 中 WhisperKit 只初始化一次，CLI 每次运行的开销不可避免。
        var whisperKit: WhisperKit? = nil
        if !skipStt {
            do {
                print("初始化 WhisperKit (模型: \(model))...")
                let sttConfig = STTProcessor.Config(modelName: model)
                whisperKit = try await STTProcessor.initializeWhisperKit(config: sttConfig)
                print("✓ WhisperKit 就绪")
            } catch {
                print("⚠ WhisperKit 初始化失败: \(error.localizedDescription)")
                if #available(macOS 26.0, *) {
                    let saAvailable = await SpeechAnalyzerBridge.isAvailable()
                    if saAvailable {
                        print("  将使用 Apple SpeechAnalyzer 替代（语言检测精度可能降低）")
                    } else {
                        print("  将跳过语音转录")
                    }
                } else {
                    print("  将跳过语音转录")
                }
            }
        }

        // 5. 解析 API Key（如需 Vision）
        let providerConfig = ProviderConfig.load()
        var resolvedApiKey: String? = nil
        if !skipVision {
            do {
                resolvedApiKey = try APIKeyManager.resolveAPIKey(override: apiKey, provider: providerConfig.provider)
                print("✓ \(providerConfig.provider.displayName) API Key 已就绪")
            } catch {
                print("警告: \(error.localizedDescription)")
                print("  将跳过视觉分析 (可用 --api-key 或 \(providerConfig.provider.keyFilePath))")
            }
        }

        // 6. 创建限速器 + 嵌入 provider
        let rateLimiter: GeminiRateLimiter? = resolvedApiKey != nil
            ? GeminiRateLimiter(config: providerConfig.toRateLimiterConfig())
            : nil

        let embeddingProvider: (any EmbeddingProvider)?
        if let key = resolvedApiKey {
            embeddingProvider = GeminiEmbeddingProvider(apiKey: key, config: providerConfig.toEmbeddingConfig())
        } else {
            embeddingProvider = nil
        }
        if let ep = embeddingProvider {
            print("✓ 嵌入 provider: \(ep.name)")
        }

        // 7. 处理视频

        // 如果 --force，先重置所有已完成视频的状态
        if force {
            for videoPath in filteredPaths {
                let existing = try await folderDB.read { db in
                    try Video.fetchByPath(db, path: videoPath)
                }
                if let video = existing, video.indexStatus == "completed",
                   let vid = video.videoId {
                    try await folderDB.write { db in
                        try db.execute(
                            sql: "UPDATE videos SET index_status = 'pending', index_error = NULL, last_processed_clip = NULL WHERE video_id = ?",
                            arguments: [vid]
                        )
                    }
                }
            }
        }

        var totalClips = 0
        var totalAnalyzed = 0
        var processedCount = 0
        var failedCount = 0
        var sttSkippedNoAudioCount = 0

        print()

        if parallel {
            // 并行模式：使用 IndexingScheduler
            let perfMode = PerformanceMode(rawValue: mode) ?? .balanced
            let scheduler = IndexingScheduler(mode: perfMode)
            let info = await scheduler.concurrencyInfo()
            print("并行模式: \(perfMode.displayName) (最大并发: \(info.max))")
            print()

            // 线程安全计数器（使用 actor）
            let counter = VideoCounter()

            var skipLayers = Set<LayeredIndexer.Layer>()
            if skipStt { skipLayers.insert(.stt) }
            if skipVision { skipLayers.insert(.textDescription) }

            let mediaService = CompositeMediaService.makeDefault()
            let parallelConfig = LayeredIndexer.Config(
                mediaService: mediaService,
                whisperKit: whisperKit,
                embeddingProvider: embeddingProvider,
                apiKey: resolvedApiKey,
                rateLimiter: rateLimiter,
                skipLayers: skipLayers
            )

            _ = await scheduler.processVideosLayered(
                filteredPaths,
                folderPath: folderPath,
                folderDB: folderDB,
                globalDB: globalDB,
                config: parallelConfig,
                onProgress: { progress in
                    print("  [\(progress.fileName)] \(progress.stage)")
                },
                onComplete: { outcome in
                    if outcome.success {
                        Task { await counter.addSuccess(
                            clips: outcome.clipsCreated,
                            analyzed: outcome.clipsAnalyzed,
                            embedded: outcome.clipsEmbedded,
                            sttSkippedNoAudio: outcome.sttSkippedNoAudio
                        )}
                        let name = (outcome.videoPath as NSString).lastPathComponent
                        let suffix = outcome.sttSkippedNoAudio ? " [无音轨，已跳过 STT]" : ""
                        print("  ✓ \(name): \(outcome.clipsCreated) 片段, \(outcome.clipsAnalyzed) 分析, \(outcome.clipsEmbedded) 嵌入\(suffix)")
                    } else if outcome.errorMessage == "cancelled" {
                        let name = (outcome.videoPath as NSString).lastPathComponent
                        print("  ⊘ \(name): 已跳过")
                    } else {
                        Task { await counter.addFailure() }
                        let name = (outcome.videoPath as NSString).lastPathComponent
                        print("  ✗ \(name): \(outcome.errorMessage ?? "未知错误")")
                    }
                }
            )

            totalClips = await counter.clips
            totalAnalyzed = await counter.analyzed
            processedCount = await counter.successes
            failedCount = await counter.failures
            sttSkippedNoAudioCount = await counter.sttSkippedNoAudio

        } else {
            // 串行模式：使用分层索引器（支持 BRAW 等非 FFmpeg 格式）
            var skipLayers = Set<LayeredIndexer.Layer>()
            if skipStt { skipLayers.insert(.stt) }
            if skipVision { skipLayers.insert(.textDescription) }

            let mediaService = CompositeMediaService.makeDefault()
            let layeredConfig = LayeredIndexer.Config(
                mediaService: mediaService,
                whisperKit: whisperKit,
                embeddingProvider: embeddingProvider,
                apiKey: resolvedApiKey,
                rateLimiter: rateLimiter,
                skipLayers: skipLayers
            )

            for (i, videoPath) in filteredPaths.enumerated() {
                let fileName = (videoPath as NSString).lastPathComponent
                print("[\(i + 1)/\(filteredPaths.count)] 处理: \(fileName)")

                do {
                    let result = try await PipelineManager.processVideoLayered(
                        videoPath: videoPath,
                        folderPath: folderPath,
                        folderDB: folderDB,
                        globalDB: globalDB,
                        config: layeredConfig,
                        onProgress: { msg in print("  \(msg)") }
                    )

                    totalClips += result.clipsCreated
                    totalAnalyzed += result.clipsAnalyzed
                    processedCount += 1

                    if let srt = result.srtPath {
                        print("  ✓ SRT: \(srt)")
                    }
                    if let sync = result.syncResult {
                        print("  ✓ 同步: \(sync.syncedVideos) 视频, \(sync.syncedClips) 片段")
                    }

                } catch {
                    print("  ✗ 失败: \(error.localizedDescription)")
                    failedCount += 1
                }
                print()
            }
        }

        // 8. 汇总
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        let timeStr = minutes > 0 ? "\(minutes)分\(seconds)秒" : "\(seconds)秒"

        var summary = "完成! 处理了 \(processedCount) 个视频, \(totalClips) 个片段, 分析了 \(totalAnalyzed) 个场景"
        if failedCount > 0 {
            summary += ", \(failedCount) 个失败"
        }
        if sttSkippedNoAudioCount > 0 {
            summary += ", \(sttSkippedNoAudioCount) 个无音轨（已跳过 STT）"
        }
        summary += ", 耗时 \(timeStr)"
        print(summary)
    }
}

/// 并行模式下的线程安全计数器
private actor VideoCounter {
    var successes: Int = 0
    var failures: Int = 0
    var clips: Int = 0
    var analyzed: Int = 0
    var embedded: Int = 0
    var sttSkippedNoAudio: Int = 0

    func addSuccess(
        clips: Int,
        analyzed: Int,
        embedded: Int = 0,
        sttSkippedNoAudio: Bool = false
    ) {
        successes += 1
        self.clips += clips
        self.analyzed += analyzed
        self.embedded += embedded
        if sttSkippedNoAudio {
            self.sttSkippedNoAudio += 1
        }
    }

    func addFailure() {
        failures += 1
    }
}

// MARK: - embed

struct EmbedCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "embed",
        abstract: "为已索引的视频片段计算向量嵌入"
    )

    @Option(name: .long, help: "素材文件夹路径")
    var folder: String

    @Option(name: .long, help: "嵌入提供者: gemini, nl (默认 gemini)")
    var provider: String = "gemini"

    @Option(name: .long, help: "Gemini API Key")
    var apiKey: String?

    @Flag(name: .long, help: "强制重新计算已有嵌入的片段")
    var force: Bool = false

    func run() async throws {
        let folderPath = (folder as NSString).standardizingPath

        let folderDB = try DatabaseManager.openFolderDatabase(at: folderPath)

        // 选择 provider
        let embProvider: EmbeddingProvider
        if provider.lowercased() == "nl" {
            print("错误: NLEmbedding 已废弃（512d 与 768d 索引不兼容）。请使用 gemini provider。")
            throw ExitCode.failure
        }
        let providerConfig = ProviderConfig.load()
        let key = try APIKeyManager.resolveAPIKey(override: apiKey, provider: providerConfig.provider)
        let p = GeminiEmbeddingProvider(apiKey: key, config: providerConfig.toEmbeddingConfig())
        guard p.isAvailable() else {
            print("错误: API Key 无效")
            throw ExitCode.failure
        }
        embProvider = p
        print("使用 \(providerConfig.embeddingModel) (\(providerConfig.embeddingDimensions) 维)")

        // 查找需要计算嵌入的 clips
        let clips = try await folderDB.read { db -> [Clip] in
            if force {
                return try Clip.fetchAll(db)
            } else {
                return try Clip
                    .filter(Column("embedding") == nil)
                    .order(Column("clip_id"))
                    .fetchAll(db)
            }
        }

        guard !clips.isEmpty else {
            print("无需计算嵌入的片段" + (force ? "" : " (使用 --force 重新计算)"))
            return
        }

        print("待处理: \(clips.count) 个片段\n")

        var embedded = 0
        var failed = 0

        for (i, clip) in clips.enumerated() {
            guard let clipId = clip.clipId else { continue }
            let text = EmbeddingUtils.composeClipText(clip: clip)

            if text.isEmpty {
                print("[\(i + 1)/\(clips.count)] clip \(clipId): 无可嵌入文本, 跳过")
                continue
            }

            do {
                let vector = try await embProvider.embed(text: text)
                let data = EmbeddingUtils.serializeEmbedding(vector)
                try await folderDB.write { db in
                    try db.execute(
                        sql: "UPDATE clips SET embedding = ?, embedding_model = ? WHERE clip_id = ?",
                        arguments: [data, embProvider.name, clipId]
                    )
                }
                embedded += 1
                let preview = text.prefix(40)
                print("[\(i + 1)/\(clips.count)] clip \(clipId): ✓ (\(vector.count) 维) \"\(preview)...\"")
            } catch {
                failed += 1
                print("[\(i + 1)/\(clips.count)] clip \(clipId): ✗ \(error.localizedDescription)")
            }
        }

        print("\n完成! 嵌入 \(embedded) 个片段, 失败 \(failed) 个")

        // 同步到全局库（force: true 因为 embedding 更新不改变 rowid）
        let globalDB = try DatabaseManager.openGlobalDatabase()
        let syncResult = try SyncEngine.sync(
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB,
            force: true
        )
        print("同步到全局索引: \(syncResult.syncedClips) 个片段")
    }
}

// MARK: - clip-backfill

struct CLIPBackfillCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clip-backfill",
        abstract: "为已有片段补充 CLIP 向量（不重建场景/片段）"
    )

    @Option(name: .long, help: "素材文件夹路径")
    var folder: String

    func run() async throws {
        let folderPath = (folder as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: folderPath) else {
            print("错误: 文件夹不存在: \(folderPath)")
            throw ExitCode.failure
        }

        let folderDB = try DatabaseManager.openFolderDatabase(at: folderPath)
        let globalDB = try DatabaseManager.openGlobalDatabase()

        // 初始化 CLIP provider
        let clipProvider = CLIPEmbeddingProvider()
        guard await clipProvider.isImageEncoderAvailable else {
            print("错误: SigLIP2 image encoder 不可用（检查模型文件）")
            throw ExitCode.failure
        }
        print("✓ SigLIP2 image encoder 已就绪")

        let startTime = CFAbsoluteTimeGetCurrent()

        let result = try await LayeredIndexer.backfillCLIP(
            folderPath: folderPath,
            folderDB: folderDB,
            globalDB: globalDB,
            clipProvider: clipProvider,
            onProgress: { current, total, videoName in
                if current % 50 == 0 || current == total - 1 {
                    print("  [\(current + 1)/\(total)] \(videoName)")
                }
            }
        )

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print()
        print("CLIP 补填完成 (\(String(format: "%.1f", elapsed))s)")
        print("  总计: \(result.totalClips) 个片段")
        print("  编码: \(result.encoded)")
        print("  跳过: \(result.skipped) (缩略图缺失)")
        print("  失败: \(result.failed)")

        if result.encoded > 0 {
            print("  已同步到全局索引")
        }
    }
}
