import ArgumentParser
import Foundation
import FindItCore
import GRDB

/// 选择性升级视觉描述质量
///
/// 查找 `vision_provider` 为 `local_vision` 或 NULL 的已索引视频，
/// 将其 index_layer 回退到 Layer 2 (stt_done)，重跑 Layer 3 使用更强引擎。
struct EnhanceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enhance",
        abstract: "升级视觉描述质量（将本地分析升级为云端/VLM 分析）"
    )

    @Argument(help: "素材文件夹路径")
    var path: String

    @Option(name: .long, help: "目标引擎: gemini (默认)")
    var provider: String = "gemini"

    @Option(name: .long, help: "只升级指定 provider 的 clips (local_vision/local_vlm/null)")
    var from: String = "local_vision"

    @Option(name: .long, help: "Gemini API Key (覆盖配置文件)")
    var apiKey: String?

    @Flag(name: .long, help: "预览模式，只显示可升级的视频")
    var dryRun = false

    @Flag(name: .shortAndLong, help: "跳过确认提示")
    var yes = false

    func run() async throws {
        let folderPath = (path as NSString).standardizingPath
        let fm = FileManager.default

        guard fm.fileExists(atPath: folderPath) else {
            print("错误: 文件夹不存在: \(folderPath)")
            throw ExitCode.failure
        }

        let folderDB = try DatabaseManager.openFolderDatabase(at: folderPath)
        let globalDB = try DatabaseManager.openGlobalDatabase()

        // 1. 查询可升级的视频
        let fromCondition: String
        if from == "null" {
            fromCondition = "vision_provider IS NULL"
        } else {
            fromCondition = "vision_provider = '\(from)' OR vision_provider IS NULL"
        }

        let upgradeableVideos: [(videoId: Int64, filePath: String, clipCount: Int)] =
            try await folderDB.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT v.video_id, v.file_path, COUNT(c.clip_id) as clip_count
                    FROM videos v
                    JOIN clips c ON c.video_id = v.video_id
                    WHERE v.index_status = 'completed'
                      AND (\(fromCondition))
                    GROUP BY v.video_id
                    ORDER BY v.video_id
                    """)
                return rows.compactMap { row -> (Int64, String, Int)? in
                    let videoId: Int64? = row["video_id"]
                    let filePath: String? = row["file_path"]
                    let clipCount: Int? = row["clip_count"]
                    guard let vid = videoId, let fp = filePath, let cc = clipCount else {
                        return nil
                    }
                    return (vid, fp, cc)
                }
            }

        if upgradeableVideos.isEmpty {
            print("无可升级的视频。所有 clips 已使用高级引擎分析。")
            return
        }

        // 2. 显示可升级列表
        let totalClips = upgradeableVideos.reduce(0) { $0 + $1.clipCount }
        print("发现 \(upgradeableVideos.count) 个视频 (\(totalClips) 个片段) 可升级:\n")

        for (i, video) in upgradeableVideos.enumerated() {
            let name = (video.filePath as NSString).lastPathComponent
            print("  [\(i + 1)] \(name) — \(video.clipCount) 个片段")
        }
        print()
        print("目标引擎: \(provider)")

        if dryRun {
            print("\n(--dry-run 模式，未实际执行)")
            return
        }

        // 3. 确认
        if !yes {
            print("\n确认升级? (y/N): ", terminator: "")
            guard readLine()?.lowercased() == "y" else {
                print("已取消。")
                return
            }
        }

        // 4. 验证 API Key
        let providerConfig = ProviderConfig.load()
        let resolvedApiKey: String
        do {
            resolvedApiKey = try APIKeyManager.resolveAPIKey(override: apiKey, provider: providerConfig.provider)
        } catch {
            print("错误: \(error.localizedDescription)")
            print("  设置 API Key: \(providerConfig.provider.keyFilePath)")
            throw ExitCode.failure
        }

        // 5. 初始化依赖
        let rateLimiter = GeminiRateLimiter(config: providerConfig.toRateLimiterConfig())

        let embeddingProvider: (any EmbeddingProvider)? = GeminiEmbeddingProvider(
            apiKey: resolvedApiKey,
            config: providerConfig.toEmbeddingConfig()
        )

        let mediaService = CompositeMediaService.makeDefault()

        let config = LayeredIndexer.Config(
            mediaService: mediaService,
            embeddingProvider: embeddingProvider,
            apiKey: resolvedApiKey,
            rateLimiter: rateLimiter,
            skipLayers: [.metadata, .clipVector, .stt]
        )

        // 6. 回退 index_layer 并重跑
        let startTime = CFAbsoluteTimeGetCurrent()
        var processed = 0
        var failed = 0

        for (i, video) in upgradeableVideos.enumerated() {
            let name = (video.filePath as NSString).lastPathComponent
            print("\n[\(i + 1)/\(upgradeableVideos.count)] \(name)")

            // 检查文件存在
            guard fm.fileExists(atPath: video.filePath) else {
                print("  ⊘ 文件不存在，跳过")
                continue
            }

            // 回退到 Layer 2
            try await folderDB.write { db in
                try db.execute(sql: """
                    UPDATE videos
                    SET index_layer = 2, index_status = 'stt_done', last_processed_clip = NULL
                    WHERE video_id = ?
                    """, arguments: [video.videoId])
            }

            do {
                let result = try await LayeredIndexer.indexVideo(
                    videoPath: video.filePath,
                    folderPath: folderPath,
                    folderDB: folderDB,
                    globalDB: globalDB,
                    config: config,
                    onProgress: { msg in print("  \(msg)") }
                )
                processed += 1
                print("  ✓ 分析 \(result.clipsAnalyzed) 个场景, 嵌入 \(result.clipsEmbedded)")
            } catch {
                failed += 1
                print("  ✗ 失败: \(error.localizedDescription)")
                // 恢复状态避免数据损坏
                try? await folderDB.write { db in
                    try db.execute(sql: """
                        UPDATE videos
                        SET index_layer = 3, index_status = 'completed'
                        WHERE video_id = ?
                        """, arguments: [video.videoId])
                }
            }
        }

        // 7. 汇总
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("\n升级完成! 处理 \(processed) 个视频" +
              (failed > 0 ? ", 失败 \(failed)" : "") +
              ", 耗时 \(Int(elapsed))s")
    }
}
