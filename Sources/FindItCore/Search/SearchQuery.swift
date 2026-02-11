import Foundation

// MARK: - SearchQuery

/// 搜索查询类型
///
/// 支持三种查询模式：
/// - `.text`: 纯文本搜索（关键词/自然语言）
/// - `.image`: 以图搜视频（CLIP 图片 → 向量搜索）
/// - `.textWithImage`: 图文混合搜索
public enum SearchQuery: Sendable {
    /// 纯文本搜索
    case text(String)
    /// 以图搜视频（CLIP image embedding 路径）
    case image(Data)
    /// 图文混合搜索（文本 + 图片）
    case textWithImage(String, Data)

    /// 提取文本部分（image 查询返回 nil）
    public var textQuery: String? {
        switch self {
        case .text(let q): return q
        case .image: return nil
        case .textWithImage(let q, _): return q
        }
    }

    /// 提取图片数据部分（text 查询返回 nil）
    public var imageData: Data? {
        switch self {
        case .text: return nil
        case .image(let d): return d
        case .textWithImage(_, let d): return d
        }
    }

    /// 是否包含文本
    public var hasText: Bool {
        textQuery != nil
    }

    /// 是否包含图片
    public var hasImage: Bool {
        imageData != nil
    }
}

// MARK: - ParsedQuery

/// 查询解析结果
///
/// 将原始查询文本拆分为正向和负向部分，
/// 用于搜索引擎的分路处理。
public struct ParsedQuery: Sendable, Equatable {
    /// 正向查询文本（去掉负向词后的查询，用于 FTS5 和 embedding）
    public let positiveText: String
    /// 负向查询词列表（用于降权排除）
    public let negativeTerms: [String]
    /// 是否包含引号短语（精确匹配标志）
    public let hasQuotedPhrase: Bool
    /// 原始查询文本
    public let rawQuery: String

    /// FTS5 查询：将负向词转为 FTS5 NOT 语法
    ///
    /// 例如: positiveText="海滩 日落", negativeTerms=["雨天"]
    /// → "海滩 日落 NOT 雨天"
    public var ftsQuery: String {
        if negativeTerms.isEmpty {
            return positiveText
        }
        let notClauses = negativeTerms.map { "NOT \($0)" }.joined(separator: " ")
        return "\(positiveText) \(notClauses)"
    }

    /// 用于 embedding 的文本（仅正向部分）
    public var embeddingText: String {
        positiveText
    }

    /// 是否为空查询
    public var isEmpty: Bool {
        positiveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && negativeTerms.isEmpty
    }
}

// MARK: - QueryParser

/// 查询解析器
///
/// 解析用户输入的搜索文本，提取：
/// - 正向关键词（搜索目标）
/// - 负向关键词（排除/降权）
/// - 引号短语（精确匹配）
///
/// 支持的负向语法：
/// - `-keyword`: 排除 keyword
/// - `NOT keyword`: 排除 keyword（FTS5 兼容语法）
///
/// 示例:
/// ```
/// "海滩 日落 -雨天"  →  positive: "海滩 日落", negative: ["雨天"]
/// "海滩 NOT 夜晚"    →  positive: "海滩", negative: ["夜晚"]
/// "\"红色跑车\" -卡车" →  positive: "\"红色跑车\"", negative: ["卡车"]
/// ```
public enum QueryParser {

    /// 解析查询文本
    ///
    /// - Parameter query: 原始查询字符串
    /// - Returns: 解析后的查询结构
    public static func parse(_ query: String) -> ParsedQuery {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedQuery(
                positiveText: "",
                negativeTerms: [],
                hasQuotedPhrase: false,
                rawQuery: query
            )
        }

        let hasQuoted = trimmed.contains("\"")

        // 分词，保留引号短语完整
        let tokens = tokenize(trimmed)

        var positiveTokens: [String] = []
        var negativeTerms: [String] = []

        var i = 0
        while i < tokens.count {
            let token = tokens[i]

            // `-keyword` 语法 (但不匹配 `-` 单独出现或引号内容)
            if token.hasPrefix("-") && token.count > 1 && !token.hasPrefix("\"") {
                let term = String(token.dropFirst())
                if !term.isEmpty {
                    negativeTerms.append(term)
                }
            }
            // `NOT keyword` 语法 (大写 NOT)
            else if token == "NOT" && i + 1 < tokens.count {
                let nextToken = tokens[i + 1]
                // NOT 后面的词作为负向词
                if !nextToken.hasPrefix("-") && !nextToken.hasPrefix("\"") {
                    negativeTerms.append(nextToken)
                    i += 1 // 跳过下一个 token
                } else {
                    // NOT 后面跟的是引号或减号，保留 NOT 作为正向词
                    positiveTokens.append(token)
                }
            }
            else {
                positiveTokens.append(token)
            }

            i += 1
        }

        let positiveText = positiveTokens.joined(separator: " ")

        return ParsedQuery(
            positiveText: positiveText,
            negativeTerms: negativeTerms,
            hasQuotedPhrase: hasQuoted,
            rawQuery: trimmed
        )
    }

    // MARK: - Tokenization

    /// 分词：按空格分割，但保留引号短语完整
    ///
    /// 例如: `"红色跑车" 海滩 -雨天` → `["\"红色跑车\"", "海滩", "-雨天"]`
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var iterator = text.makeIterator()

        while let char = iterator.next() {
            if char == "\"" {
                current.append(char)
                if inQuote {
                    // 结束引号
                    tokens.append(current)
                    current = ""
                    inQuote = false
                } else {
                    // 开始引号
                    inQuote = true
                }
            } else if char == " " && !inQuote {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }

        // 尾部残余
        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }
}
