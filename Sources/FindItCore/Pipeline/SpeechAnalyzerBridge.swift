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

    /// 将语言代码转换为 Locale
    ///
    /// 支持 ISO 639-1 (如 "zh") 和 NLLanguage rawValue (如 "zh-Hans")。
    /// - Parameter language: 语言代码，nil 默认英语
    /// - Returns: 对应的 Locale
    public static func localeForLanguage(_ language: String?) -> Locale {
        guard let lang = language?.lowercased() else {
            return Locale(identifier: "en_US")
        }
        if let identifier = languageToLocale[lang] {
            return Locale(identifier: identifier)
        }
        // NLLanguage rawValue 含区域后缀 (如 "zh-hans")，尝试基础语言码
        let base = String(lang.prefix(while: { $0 != "-" }))
        let identifier = languageToLocale[base] ?? "en_US"
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
        onProgress: (@Sendable (String) -> Void)? = nil
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
        let rawSegments = extractSegments(from: attributedText)
        return mergeFragmentedSegments(rawSegments)
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

    // MARK: - Segment 合并

    /// 句末标点符号集合（中日英通用）
    private static let sentenceEndingPunctuation: Set<Character> = [
        "。", "！", "？", ".", "!", "?", "…", "\n",
    ]

    /// 合并碎片化的 segments（日语等逐字输出的后处理）
    ///
    /// Apple SpeechAnalyzer 对 CJK 语言返回逐字级 runs，
    /// 每个汉字/假名各成一个 segment（如 259 个 segment 对 2 分钟日语音频）。
    /// 本方法将相邻碎片合并为句子级 segments，使 SRT 可用。
    ///
    /// 合并策略:
    /// 1. 拼接相邻 segments 文本，直到遇到句末标点
    /// 2. 相邻 segments 间隔 > maxGap 秒 → 强制断句（说话人停顿）
    /// 3. 已合并段时长超过 maxDuration → 强制断句（防止超长段）
    /// 4. 累积字符数超过 maxChars → 强制断句（CJK 无标点时的 fallback）
    /// 5. 合并后重新编号 (1-based)
    ///
    /// 对英语无害: 英语 segments 本身是句子级，无逐字碎片，几乎不触发合并。
    ///
    /// - Parameters:
    ///   - segments: 原始碎片 segments
    ///   - maxGap: 允许合并的最大时间间隔（秒），默认 1.0
    ///   - maxDuration: 单个合并 segment 的最大时长（秒），默认 15.0
    ///   - maxChars: 单个合并 segment 的最大非空白字符数，默认 40（CJK ≈ 1 行字幕）
    /// - Returns: 合并后的 segments
    public static func mergeFragmentedSegments(
        _ segments: [TranscriptSegment],
        maxGap: Double = 1.0,
        maxDuration: Double = 15.0,
        maxChars: Int = 40
    ) -> [TranscriptSegment] {
        guard !segments.isEmpty else { return [] }

        var merged: [TranscriptSegment] = []
        var index = 1

        // 当前正在积累的合并段
        var currentStart = segments[0].startTime
        var currentEnd = segments[0].endTime
        var currentText = segments[0].text

        for i in 1..<segments.count {
            let seg = segments[i]
            let gap = seg.startTime - currentEnd
            let duration = seg.endTime - currentStart

            // 判断是否应该断句
            let charCount = currentText.unicodeScalars
                .filter { !$0.properties.isWhitespace }.count
            let shouldSplit =
                gap > maxGap                                   // 时间间隔过大
                || duration > maxDuration                      // 累积时长过长
                || endsWithSentencePunctuation(currentText)    // 上一段以句末标点结尾
                || charCount > maxChars                        // CJK 无标点时的字符数上限

            if shouldSplit {
                // 输出当前累积段
                merged.append(TranscriptSegment(
                    index: index,
                    startTime: currentStart,
                    endTime: currentEnd,
                    text: currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
                index += 1
                // 重置
                currentStart = seg.startTime
                currentEnd = seg.endTime
                currentText = seg.text
            } else {
                // 继续拼接
                currentEnd = seg.endTime
                currentText += seg.text
            }
        }

        // 输出最后一段
        let finalText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty {
            merged.append(TranscriptSegment(
                index: index,
                startTime: currentStart,
                endTime: currentEnd,
                text: finalText
            ))
        }

        return merged
    }

    /// 检查文本是否以句末标点结尾
    private static func endsWithSentencePunctuation(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return sentenceEndingPunctuation.contains(last)
    }
}
