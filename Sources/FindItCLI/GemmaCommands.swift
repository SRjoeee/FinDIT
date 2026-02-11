import ArgumentParser
import Foundation
import FindItCore

/// EmbeddingGemma CLI 命令
///
/// 用于验证 EmbeddingGemma-300M 文本嵌入引擎的功能和性能。
struct GemmaCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gemma",
        abstract: "EmbeddingGemma 文本嵌入工具（编码 + 相似度验证）",
        subcommands: [
            GemmaStatusCommand.self,
            GemmaEncodeCommand.self,
            GemmaSimilarityCommand.self,
        ]
    )
}

// MARK: - gemma status

struct GemmaStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "检查 EmbeddingGemma 模型状态"
    )

    func run() {
        print("EmbeddingGemma-300M 模型状态")
        print("目录: \(EmbeddingGemmaModelManager.modelDirectory)")
        print()

        let status = EmbeddingGemmaModelManager.modelStatus()
        for info in status {
            let icon = info.exists ? "✓" : "✗"
            let size = info.sizeBytes.map {
                String(format: "%.1f MB", Double($0) / 1_000_000)
            } ?? "-"
            print("  \(icon) \(info.file) (\(size))")
        }

        print()
        if EmbeddingGemmaModelManager.allModelsAvailable() {
            print("所有模型文件就绪")
        } else {
            let missing = EmbeddingGemmaModelManager.missingModels()
            print("缺失 \(missing.count) 个模型文件:")
            for m in missing {
                print("  - \(m.rawValue)")
            }
            print()
            print("请将模型文件复制到: \(EmbeddingGemmaModelManager.modelDirectory)")
        }
    }
}

// MARK: - gemma encode

struct GemmaEncodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "encode",
        abstract: "编码文本为 EmbeddingGemma 向量"
    )

    @Argument(help: "输入文本")
    var text: String

    func run() async throws {
        let encoder = EmbeddingGemmaEncoder()
        guard encoder.isAvailable() else {
            print("错误: EmbeddingGemma 模型不可用")
            print("请将模型文件复制到: \(EmbeddingGemmaModelManager.modelDirectory)")
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

// MARK: - gemma similarity

struct GemmaSimilarityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "similarity",
        abstract: "计算两段文本的 EmbeddingGemma 余弦相似度"
    )

    @Argument(help: "文本 A")
    var textA: String

    @Argument(help: "文本 B")
    var textB: String

    func run() async throws {
        let encoder = EmbeddingGemmaEncoder()
        guard encoder.isAvailable() else {
            print("错误: EmbeddingGemma 模型不可用")
            print("请将模型文件复制到: \(EmbeddingGemmaModelManager.modelDirectory)")
            throw ExitCode.failure
        }

        print("文本 A: \"\(textA)\"")
        print("文本 B: \"\(textB)\"")
        print()

        let startA = CFAbsoluteTimeGetCurrent()
        let embA = try await encoder.encode(text: textA)
        let elapsedA = (CFAbsoluteTimeGetCurrent() - startA) * 1000

        let startB = CFAbsoluteTimeGetCurrent()
        let embB = try await encoder.encode(text: textB)
        let elapsedB = (CFAbsoluteTimeGetCurrent() - startB) * 1000

        let similarity = EmbeddingUtils.cosineSimilarity(embA, embB)

        print("余弦相似度: \(String(format: "%.4f", similarity))")
        print("编码耗时: A=\(String(format: "%.0f", elapsedA))ms, B=\(String(format: "%.0f", elapsedB))ms")
    }
}
