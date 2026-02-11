import ArgumentParser
import Foundation
import FindItCore

/// CLIP 编码器 CLI 命令
///
/// 用于验证 SigLIP2 CLIP 编码器的功能和性能。
struct CLIPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "siglip",
        abstract: "SigLIP2 CLIP 编码器工具（图片/文本编码 + 跨模态搜索验证）",
        subcommands: [
            CLIPStatusCommand.self,
            CLIPEncodeImageCommand.self,
            CLIPEncodeTextCommand.self,
            CLIPMatchCommand.self,
        ]
    )
}

// MARK: - clip status

struct CLIPStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "检查 CLIP 模型状态"
    )

    func run() {
        print("SigLIP2 CLIP 模型状态")
        print("目录: \(CLIPModelManager.modelDirectory)")
        print()

        let status = CLIPModelManager.modelStatus()
        for info in status {
            let icon = info.exists ? "✓" : "✗"
            let size = info.sizeBytes.map { "\(String(format: "%.1f", Double($0) / 1_000_000)) MB" } ?? "-"
            print("  \(icon) \(info.file) (\(size))")
        }

        print()
        if CLIPModelManager.allModelsAvailable() {
            print("所有模型文件就绪")
        } else {
            let missing = CLIPModelManager.missingModels()
            print("缺失 \(missing.count) 个模型文件:")
            for m in missing {
                print("  - \(m.rawValue)")
            }
            print()
            print("请将模型文件复制到: \(CLIPModelManager.modelDirectory)")
        }
    }
}

// MARK: - clip encode-image

struct CLIPEncodeImageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "encode-image",
        abstract: "编码图片为 CLIP 向量"
    )

    @Argument(help: "图片文件路径")
    var imagePath: String

    @Option(name: .long, help: "模型路径（默认使用标准位置）")
    var modelPath: String?

    func run() async throws {
        let path = (imagePath as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: path) else {
            print("错误: 图片不存在: \(path)")
            throw ExitCode.failure
        }

        let encoder = SigLIP2ImageEncoder(modelPath: modelPath)
        guard encoder.isAvailable() else {
            print("错误: CLIP 模型不可用")
            print("模型路径: \(modelPath ?? CLIPModelManager.path(for: .combinedModel))")
            throw ExitCode.failure
        }

        print("编码图片: \(path)")

        let start = CFAbsoluteTimeGetCurrent()
        let embedding = try await encoder.encode(imagePath: path)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })

        print("维度: \(embedding.count)")
        print("L2 范数: \(String(format: "%.4f", norm))")
        print("耗时: \(String(format: "%.0f", elapsed)) ms")
        print("前 10 维: \(embedding.prefix(10).map { String(format: "%.6f", $0) }.joined(separator: ", "))")
    }
}

// MARK: - clip encode-text

struct CLIPEncodeTextCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "encode-text",
        abstract: "编码文本为 CLIP 向量"
    )

    @Argument(help: "查询文本")
    var text: String

    @Option(name: .long, help: "模型路径")
    var modelPath: String?

    @Option(name: .long, help: "Tokenizer 路径")
    var tokenizerPath: String?

    func run() async throws {
        let encoder = SigLIP2TextEncoder(
            modelPath: modelPath,
            tokenizerPath: tokenizerPath
        )
        guard encoder.isAvailable() else {
            print("错误: CLIP 模型或 tokenizer 不可用")
            throw ExitCode.failure
        }

        print("编码文本: \"\(text)\"")

        let start = CFAbsoluteTimeGetCurrent()
        let embedding = try await encoder.encode(text: text)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })

        print("维度: \(embedding.count)")
        print("L2 范数: \(String(format: "%.4f", norm))")
        print("耗时: \(String(format: "%.0f", elapsed)) ms")
        print("前 10 维: \(embedding.prefix(10).map { String(format: "%.6f", $0) }.joined(separator: ", "))")
    }
}

// MARK: - clip match

struct CLIPMatchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "match",
        abstract: "计算文本查询与图片的 CLIP 相似度"
    )

    @Argument(help: "查询文本")
    var query: String

    @Option(name: .shortAndLong, parsing: .upToNextOption, help: "图片路径（可指定多个）")
    var images: [String]

    @Option(name: .long, help: "模型路径")
    var modelPath: String?

    func run() async throws {
        guard !images.isEmpty else {
            print("错误: 请至少指定一张图片 (-i path)")
            throw ExitCode.failure
        }

        let provider = CLIPEmbeddingProvider(
            imageEncoder: SigLIP2ImageEncoder(modelPath: modelPath),
            textEncoder: SigLIP2TextEncoder(modelPath: modelPath)
        )

        let available = await provider.isAvailable
        guard available else {
            print("错误: CLIP 模型不可用")
            throw ExitCode.failure
        }

        print("查询: \"\(query)\"")
        print("图片: \(images.count) 张")
        print()

        // 编码查询文本
        let queryEmb = try await provider.encodeText(query)

        // 编码图片并计算相似度
        var results: [(path: String, similarity: Float)] = []
        for imgPath in images {
            let path = (imgPath as NSString).standardizingPath
            guard FileManager.default.fileExists(atPath: path) else {
                print("  跳过: 文件不存在 \(path)")
                continue
            }

            let imgEmb = try await provider.encodeImage(path: path)
            let sim = EmbeddingUtils.cosineSimilarity(queryEmb, imgEmb)
            results.append((path: path, similarity: sim))
        }

        // 按相似度排序
        results.sort { $0.similarity > $1.similarity }

        print("结果 (按相似度降序):")
        for (i, r) in results.enumerated() {
            let name = (r.path as NSString).lastPathComponent
            print("  [\(i + 1)] \(String(format: "%.4f", r.similarity))  \(name)")
        }
    }

}
