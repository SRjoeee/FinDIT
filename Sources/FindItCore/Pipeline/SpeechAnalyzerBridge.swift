import Foundation
import AVFAudio
import Speech
import CoreMedia

/// Apple SpeechAnalyzer 桥接
///
/// 封装 macOS 26+ 的 SpeechAnalyzer API，提供与 WhisperKit 兼容的输出格式。
/// 使用 Apple Neural Engine 加速，比 WhisperKit turbo 快约 2.2 倍。
///
/// 支持 41 种语言（含中/日/英/韩），模型由系统管理（首次使用时自动下载）。
@available(macOS 26.0, *)
public enum SpeechAnalyzerBridge {

    /// 支持的 WhisperKit 语言代码 → Locale 映射
    static let languageToLocale: [String: String] = [
        "zh": "zh_CN",
        "ja": "ja_JP",
        "en": "en_US",
        "ko": "ko_KR",
        "fr": "fr_FR",
        "de": "de_DE",
        "es": "es_ES",
        "it": "it_IT",
        "pt": "pt_BR",
        "ru": "ru_RU",
        "ar": "ar_SA",
        "nl": "nl_NL",
        "sv": "sv_SE",
        "da": "da_DK",
        "fi": "fi_FI",
        "nb": "nb_NO",
        "tr": "tr_TR",
        "th": "th_TH",
        "vi": "vi_VN",
        "ms": "ms_MY",
        "he": "he_IL",
    ]

    /// 将 WhisperKit 语言代码转换为 Locale
    ///
    /// - Parameter language: ISO 639-1 语言代码（如 "ja", "zh", "en"），nil 默认英语
    /// - Returns: 对应的 Locale
    public static func localeForLanguage(_ language: String?) -> Locale {
        guard let lang = language?.lowercased() else {
            return Locale(identifier: "en_US")
        }
        let identifier = languageToLocale[lang] ?? "en_US"
        return Locale(identifier: identifier)
    }

    /// 检查 SpeechAnalyzer 是否可用于指定语言
    ///
    /// - Parameter language: 语言代码（nil = 检查设备是否支持）
    /// - Returns: 是否可用
    public static func isAvailable(language: String? = nil) async -> Bool {
        let locale = localeForLanguage(language)
        let supported = await SpeechTranscriber.supportedLocales
        return supported.contains { $0.identifier == locale.identifier }
    }

    /// 转录音频文件
    ///
    /// 使用 Apple SpeechAnalyzer 进行离线转录，返回带时间戳的转录片段。
    /// 首次使用时自动下载语言模型。
    ///
    /// - Parameters:
    ///   - audioPath: WAV 音频文件路径
    ///   - language: 语言代码（ISO 639-1），nil 默认英语
    ///   - onProgress: 进度回调
    /// - Returns: 转录片段数组
    public static func transcribe(
        audioPath: String,
        language: String? = nil,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> [TranscriptSegment] {
        guard FileManager.default.fileExists(atPath: audioPath) else {
            throw STTError.audioFileNotFound(path: audioPath)
        }

        let locale = localeForLanguage(language)
        let progress = onProgress ?? { _ in }

        // 创建带时间戳的转录器
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        // 确保模型已下载
        let installed = await SpeechTranscriber.installedLocales
        if !installed.contains(where: { $0.identifier == locale.identifier }) {
            progress("下载语音模型: \(locale.identifier)...")
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) {
                try await request.downloadAndInstall()
            }
            progress("语音模型下载完成")
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))

        // 异步收集转录结果
        async let collectedText: AttributedString = {
            var fullText = AttributedString("")
            for try await result in transcriber.results {
                if result.isFinal {
                    fullText.append(result.text)
                }
            }
            return fullText
        }()

        // 送入音频
        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let attributedText = try await collectedText
        return extractSegments(from: attributedText)
    }

    /// 从 AttributedString 提取带时间戳的转录片段
    ///
    /// 遍历 AttributedString 的 runs，提取 audioTimeRange 属性中的时间信息。
    static func extractSegments(from attributedText: AttributedString) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var index = 1

        for run in attributedText.runs {
            let text = String(attributedText[run.range].characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if let timeRange = run.audioTimeRange {
                let startSeconds = CMTimeGetSeconds(timeRange.start)
                let durationSeconds = CMTimeGetSeconds(timeRange.duration)
                let endSeconds = startSeconds + durationSeconds

                guard startSeconds.isFinite && endSeconds.isFinite
                      && endSeconds > startSeconds else { continue }

                segments.append(TranscriptSegment(
                    index: index,
                    startTime: startSeconds,
                    endTime: endSeconds,
                    text: text
                ))
                index += 1
            }
        }

        return segments
    }
}
