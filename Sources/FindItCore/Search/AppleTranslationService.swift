import Foundation

#if canImport(Translation)
import Translation

/// Apple Translation 翻译服务 (macOS 26+)
///
/// 使用 Apple 的离线神经翻译引擎，支持 ZH↔EN 双向翻译。
/// 首次使用需下载语言模型（约 100MB），后续完全离线。
///
/// 降级策略: 不可用时由 `TranslationDictionary` 接管。
@available(macOS 26.0, *)
public final class AppleTranslationService: TranslationService, @unchecked Sendable {

    public init() {}

    public var isAvailable: Bool {
        // Translation 框架在 macOS 26+ 始终存在
        // 实际翻译可能因语言模型未下载而失败，
        // 但 translate() 会优雅返回 nil
        true
    }

    public func translate(
        _ text: String, from source: String, to target: String
    ) async throws -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let sourceLang = Locale.Language(identifier: source)
        let targetLang = Locale.Language(identifier: target)

        do {
            let session = TranslationSession(
                installedSource: sourceLang,
                target: targetLang
            )
            let response = try await session.translate(trimmed)
            let result = response.targetText
            // 翻译结果与原文相同说明翻译无效
            guard result != trimmed else { return nil }
            return result
        } catch {
            // 翻译失败（模型未下载、语言不支持等），静默返回 nil
            return nil
        }
    }
}
#endif

// MARK: - Factory

extension QueryPipeline {

    /// 创建最佳可用翻译服务
    ///
    /// macOS 26+ → Apple Translation (神经翻译, ~50ms)
    /// macOS 14  → TranslationDictionary (词典查表, <1ms)
    public static func bestAvailableTranslator() -> any TranslationService {
        #if canImport(Translation)
        if #available(macOS 26.0, *) {
            return AppleTranslationService()
        }
        #endif
        return TranslationDictionary.shared
    }
}
