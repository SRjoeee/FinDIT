import Foundation

/// 组合媒体服务
///
/// 路由引擎：管理多个 `MediaDecoder`，根据文件格式和 probe 评分
/// 自动选择最优解码器。
///
/// 路由优先级链:
/// 1. AVFoundation (P:80) — H.264/H.265/ProRes 硬件加速
/// 2. FFmpeg (P:50) — 通用 fallback，支持所有格式
///
/// 同时实现 `SceneDetectable`，条件转发给支持场景检测的解码器。
///
/// 使用 `@unchecked Sendable` 因为内部通过 NSLock 保护可变状态。
public final class CompositeMediaService: MediaService, SceneDetectable, @unchecked Sendable {

    // MARK: - Properties

    /// 已注册的解码器（按 priority 降序）
    private var decoders: [any MediaDecoder] = []

    /// 扩展名 → 最优解码器缓存
    private var decoderCache: [String: any MediaDecoder] = [:]

    private let lock = NSLock()

    public init() {}

    // MARK: - Lock-Protected State Access (同步方法，避免 async 上下文中直接调用 NSLock)

    /// 读取缓存的解码器
    private func getCachedDecoder(for ext: String) -> (any MediaDecoder)? {
        lock.lock()
        defer { lock.unlock() }
        return decoderCache[ext]
    }

    /// 获取所有解码器的快照
    private func getDecoders() -> [any MediaDecoder] {
        lock.lock()
        defer { lock.unlock() }
        return decoders
    }

    /// 缓存解码器
    private func cacheDecoder(_ decoder: any MediaDecoder, for ext: String) {
        lock.lock()
        defer { lock.unlock() }
        decoderCache[ext] = decoder
    }

    // MARK: - 注册

    /// 注册解码器
    ///
    /// 自动按 priority 降序排列。相同 priority 按注册顺序。
    public func register(_ decoder: any MediaDecoder) {
        lock.lock()
        defer { lock.unlock() }
        decoders.append(decoder)
        decoders.sort { $0.capability.priority > $1.capability.priority }
        // 清除缓存（新 decoder 可能改变路由结果）
        decoderCache.removeAll()
    }

    // MARK: - MediaService

    public func probe(filePath: String) async throws -> ProbeResult {
        let decoder = try await bestDecoder(for: filePath)
        return try await decoder.probe(filePath: filePath)
    }

    public func extractKeyframes(
        filePath: String,
        times: [Double],
        outputDir: String,
        maxDimension: Int
    ) async throws -> [String] {
        let decoder = try await bestDecoder(for: filePath)
        return try await decoder.extractKeyframes(
            filePath: filePath,
            times: times,
            outputDir: outputDir,
            maxDimension: maxDimension
        )
    }

    public func extractAudio(
        filePath: String,
        outputPath: String,
        sampleRate: Int
    ) async throws -> String {
        // 音频提取需要特殊处理：高优先级 decoder 可能不支持音频提取，
        // 需要 fallback 到支持音频的 decoder
        let decoder = try await bestDecoderForAudio(filePath: filePath, sampleRate: sampleRate)
        return try await decoder.extractAudio(
            filePath: filePath,
            outputPath: outputPath,
            sampleRate: sampleRate
        )
    }

    public func supportLevel(for filePath: String) async -> FormatSupportLevel {
        let ext = fileExtension(from: filePath)
        let candidates = candidateDecoders(for: ext)

        guard !candidates.isEmpty else {
            return .unsupported
        }

        for decoder in candidates {
            do {
                let result = try await decoder.probe(filePath: filePath)
                if result.score > 0 {
                    return .fullDecode
                }
            } catch {
                continue
            }
        }

        return .unsupported
    }

    // MARK: - SceneDetectable

    public func detectScenesOptimized(
        filePath: String,
        audioOutputPath: String?,
        config: SceneDetector.Config
    ) async throws -> SceneDetector.CombinedDetectionResult {
        // 场景检测需要 SceneDetectable 解码器
        let decoder = try await bestDecoder(for: filePath)
        guard let sceneDetector = decoder as? SceneDetectable else {
            // 当前 decoder 不支持场景检测，尝试找到一个支持的
            if let fallback = findSceneDetectableDecoder(for: filePath) {
                return try await fallback.detectScenesOptimized(
                    filePath: filePath,
                    audioOutputPath: audioOutputPath,
                    config: config
                )
            }
            throw MediaError.operationNotSupported("scene detection")
        }
        return try await sceneDetector.detectScenesOptimized(
            filePath: filePath,
            audioOutputPath: audioOutputPath,
            config: config
        )
    }

    // MARK: - 便利工厂

    /// 创建默认配置的 CompositeMediaService
    ///
    /// 注册 AVFoundationDecoder (P:80) + FFmpegDecoder (P:50)
    public static func makeDefault(ffmpegConfig: FFmpegConfig = .default) -> CompositeMediaService {
        let service = CompositeMediaService()
        service.register(AVFoundationDecoder())
        service.register(FFmpegDecoder(config: ffmpegConfig))
        return service
    }

    // MARK: - Decoder Selection

    /// 为指定文件选择最优解码器
    ///
    /// 选择策略:
    /// 1. 查缓存（按扩展名）
    /// 2. 按扩展名过滤候选
    /// 3. 对每个候选执行 probe()，取 score 最高者
    /// 4. 相同 score 取 priority 更高者
    /// 5. 全部 score=0 → 抛出 noDecoderAvailable
    /// 6. 缓存结果
    func bestDecoder(for filePath: String) async throws -> any MediaDecoder {
        let ext = fileExtension(from: filePath)

        // 查缓存（同步方法，不触发 async NSLock 警告）
        if let cached = getCachedDecoder(for: ext) {
            return cached
        }
        let allDecoders = getDecoders()

        guard !allDecoders.isEmpty else {
            throw MediaError.noDecoderAvailable(path: filePath)
        }

        // 按扩展名过滤候选（已按 priority 降序）
        let candidates = allDecoders.filter { decoder in
            decoder.capability.fileExtensions.contains(ext)
        }

        // 如果没有匹配扩展名的 decoder，用全部 decoder 作为候选
        let effectiveCandidates = candidates.isEmpty ? allDecoders : candidates

        // probe 所有候选，取评分最高的
        var bestDecoder: (any MediaDecoder)?
        var bestScore = 0

        for decoder in effectiveCandidates {
            do {
                let result = try await decoder.probe(filePath: filePath)
                if result.score > bestScore {
                    bestScore = result.score
                    bestDecoder = decoder
                } else if result.score == bestScore && result.score > 0 {
                    // 同分时保留 priority 更高的（已排序，先出现的 priority 更高）
                    if bestDecoder == nil {
                        bestDecoder = decoder
                    }
                }
            } catch {
                continue
            }
        }

        guard let selected = bestDecoder else {
            throw MediaError.noDecoderAvailable(path: filePath)
        }

        // 缓存结果（同步方法）
        cacheDecoder(selected, for: ext)

        return selected
    }

    /// 为音频提取找到支持的解码器
    ///
    /// 如果最优 decoder 的 extractAudio 抛出 operationNotSupported，
    /// 尝试下一个支持音频的 decoder。
    private func bestDecoderForAudio(
        filePath: String,
        sampleRate: Int
    ) async throws -> any MediaDecoder {
        let ext = fileExtension(from: filePath)
        let allDecoders = getDecoders()

        let candidates = allDecoders.filter { $0.capability.fileExtensions.contains(ext) }
        let effectiveCandidates = candidates.isEmpty ? allDecoders : candidates

        // 逐个尝试，找到第一个不抛 operationNotSupported 的
        for decoder in effectiveCandidates {
            do {
                let result = try await decoder.probe(filePath: filePath)
                guard result.score > 0 else { continue }

                // 尝试提取（dry run 不可行，直接返回该 decoder）
                // 已知 AVFoundationDecoder 会抛 operationNotSupported
                // FFmpegDecoder 支持音频提取
                // 通过类型检查跳过已知不支持的
                if decoder is AVFoundationDecoder {
                    continue
                }
                return decoder
            } catch {
                continue
            }
        }

        // fallback: 返回 bestDecoder（可能会抛错，但让调用者处理）
        return try await bestDecoder(for: filePath)
    }

    /// 找到一个支持 SceneDetectable 的解码器
    private func findSceneDetectableDecoder(for filePath: String) -> SceneDetectable? {
        let ext = fileExtension(from: filePath)
        let allDecoders = getDecoders()

        let candidates = allDecoders.filter { $0.capability.fileExtensions.contains(ext) }
        let effectiveCandidates = candidates.isEmpty ? allDecoders : candidates

        return effectiveCandidates.first(where: { $0 is SceneDetectable }) as? SceneDetectable
    }

    /// 获取指定扩展名的候选解码器
    private func candidateDecoders(for ext: String) -> [any MediaDecoder] {
        let allDecoders = getDecoders()

        let candidates = allDecoders.filter { $0.capability.fileExtensions.contains(ext) }
        return candidates.isEmpty ? allDecoders : candidates
    }

    /// 提取文件扩展名（小写，不含点号）
    private func fileExtension(from filePath: String) -> String {
        (filePath as NSString).pathExtension.lowercased()
    }
}
