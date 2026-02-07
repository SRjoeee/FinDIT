import Foundation
import NaturalLanguage

// MARK: - NLEmbeddingUtil

/// Apple NLEmbedding 离线嵌入工具
///
/// 使用系统内置的 NaturalLanguage 框架计算文本向量嵌入。
/// 完全离线运行，无需 API Key 或网络连接。
///
/// 特点:
/// - 512 维向量输出
/// - 需要对应语言的嵌入模型（系统预装英文、中文等主要语言）
/// - 通过 `NLEmbedding.wordEmbedding(for:)` 加载模型
public enum NLEmbeddingUtil {

    /// 检测文本的主要语言
    ///
    /// 使用 NLLanguageRecognizer 自动检测语言。
    /// 返回置信度最高的语言，无法确定时返回 nil。
    ///
    /// - Parameter text: 待检测文本
    /// - Returns: 检测到的语言
    public static func detectLanguage(text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }

    /// 检查指定语言的 NLEmbedding 是否可用
    ///
    /// - Parameter language: 目标语言
    /// - Returns: 是否有可用的词嵌入模型
    public static func isAvailable(for language: NLLanguage) -> Bool {
        NLEmbedding.wordEmbedding(for: language) != nil
    }

    /// 获取支持的语言列表（已安装模型的语言）
    public static func availableLanguages() -> [NLLanguage] {
        // 常见语言列表
        let candidates: [NLLanguage] = [
            .english, .simplifiedChinese, .traditionalChinese,
            .japanese, .korean, .french, .german, .spanish,
            .italian, .portuguese, .russian, .arabic
        ]
        return candidates.filter { isAvailable(for: $0) }
    }

    /// 计算文本的嵌入向量
    ///
    /// NLEmbedding 是词级别嵌入。对整句文本，我们取所有词向量的平均值。
    /// 这是一种简单但有效的句嵌入近似方法。
    ///
    /// - Parameters:
    ///   - text: 待嵌入文本
    ///   - language: 文本语言（nil 时自动检测）
    /// - Returns: 嵌入向量，模型不可用或文本无有效词时返回 nil
    public static func embed(text: String, language: NLLanguage? = nil) -> [Float]? {
        // 确定语言
        let lang: NLLanguage
        if let specified = language {
            lang = specified
        } else if let detected = detectLanguage(text: text) {
            lang = detected
        } else {
            return nil
        }

        // 加载嵌入模型
        guard let embedding = NLEmbedding.wordEmbedding(for: lang) else {
            return nil
        }

        let dimension = embedding.dimension

        // 分词
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var vectors: [[Double]] = []

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range])
            if let vec = embedding.vector(for: word) {
                vectors.append(vec)
            }
            return true
        }

        guard !vectors.isEmpty else { return nil }

        // 计算平均向量
        var avgVector = [Double](repeating: 0.0, count: dimension)
        for vec in vectors {
            for i in 0..<min(vec.count, dimension) {
                avgVector[i] += vec[i]
            }
        }
        let count = Double(vectors.count)
        return avgVector.map { Float($0 / count) }
    }
}

// MARK: - NLEmbeddingProvider

/// Apple NLEmbedding 离线嵌入提供者
///
/// 封装 NLEmbeddingUtil 为 EmbeddingProvider 协议。
/// 完全离线，作为 Gemini API 不可用时的回退方案。
public final class NLEmbeddingProvider: EmbeddingProvider, Sendable {
    public let name = "nl-embedding"
    public let dimensions = 512

    /// 默认语言（nil 时自动检测）
    private let defaultLanguage: NLLanguage?

    /// 创建 NLEmbedding 提供者
    ///
    /// - Parameter language: 默认语言，nil 时每次调用自动检测
    public init(language: NLLanguage? = nil) {
        self.defaultLanguage = language
    }

    public func isAvailable() -> Bool {
        // 至少英文模型应该可用
        NLEmbeddingUtil.isAvailable(for: .english)
    }

    public func embed(text: String) async throws -> [Float] {
        guard let vector = NLEmbeddingUtil.embed(text: text, language: defaultLanguage) else {
            throw EmbeddingError.embeddingFailed(
                detail: "NLEmbedding 无法生成向量（可能语言模型不可用或文本无有效词）"
            )
        }
        return vector
    }
}
