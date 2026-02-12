import ArgumentParser
import Foundation
import FindItCore
import GRDB

/// NLE 导出命令
///
/// 将搜索结果导出为 EDL 或 FCPXML 格式，供 DaVinci Resolve、Premiere Pro、Final Cut Pro 等 NLE 导入。
struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "导出搜索结果为 NLE 格式 (EDL / FCPXML)"
    )

    @Option(name: .long, help: "导出格式: edl, fcpxml")
    var format: ExportFormat

    @Option(name: .shortAndLong, help: "输出文件路径")
    var output: String

    @Option(name: .long, help: "搜索关键词（与 --all 二选一）")
    var query: String?

    @Flag(name: .long, help: "导出所有已索引片段")
    var all: Bool = false

    @Option(name: .long, help: "限制文件夹路径")
    var folder: String?

    @Option(name: .long, help: "最大结果数 (默认 999)")
    var limit: Int = 999

    @Option(name: .long, help: "帧率 (默认 24)")
    var fps: Double = 24

    @Flag(name: .long, help: "使用 drop-frame timecode (29.97fps)")
    var dropFrame: Bool = false

    @Option(name: .long, help: "项目名称")
    var title: String = "FindIt Export"

    @Flag(name: .long, help: "不包含元数据注释")
    var noComments: Bool = false

    func validate() throws {
        if query == nil && !all {
            throw ValidationError("必须指定 --query 或 --all")
        }
        if query != nil && all {
            throw ValidationError("--query 和 --all 不能同时使用")
        }
    }

    func run() async throws {
        let globalDB = try DatabaseManager.openGlobalDatabase()

        // 获取搜索结果
        var results: [SearchEngine.SearchResult]

        if all {
            // 导出所有片段
            results = try await globalDB.read { db in
                try SearchEngine.allClips(db, folder: folder, limit: limit)
            }
        } else if let query = query {
            // 执行搜索
            results = try await globalDB.read { db in
                try SearchEngine.hybridSearch(
                    db, query: query,
                    queryEmbedding: nil,
                    embeddingModel: nil,
                    mode: .fts,
                    limit: limit
                )
            }
        } else {
            results = []
        }

        guard !results.isEmpty else {
            print("无匹配结果，未导出文件。")
            return
        }

        // 导出
        switch format {
        case .edl:
            let options = EDLExporter.Options(
                title: title,
                fps: fps,
                dropFrame: dropFrame,
                includeComments: !noComments
            )
            try EDLExporter.export(clips: results, to: output, options: options)

        case .fcpxml:
            let videoFormats = await FCPXMLExporter.probeVideoFormats(clips: results)
            let options = FCPXMLExporter.Options(
                projectName: title,
                fps: fps,
                includeKeywords: !noComments,
                includeNotes: !noComments
            )
            try FCPXMLExporter.export(clips: results, to: output, options: options, videoFormats: videoFormats)
        }

        print("已导出 \(results.count) 个片段到 \(output)")
        print("格式: \(format.rawValue.uppercased()), 帧率: \(fps)fps")
    }
}

// MARK: - ExportFormat

enum ExportFormat: String, ExpressibleByArgument, CaseIterable {
    case edl
    case fcpxml
}
