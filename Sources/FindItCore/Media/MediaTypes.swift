import Foundation

// MARK: - 媒体类型

/// 媒体文件类型
public enum MediaType: String, Codable, Sendable {
    case video
    case photo   // 未来扩展: jpg, png, heic, tiff, webp, raw, dng
    case audio   // 未来扩展: mp3, wav, aac, flac, m4a, aiff
}

// MARK: - 解码器能力声明

/// 解码器的格式支持能力
///
/// 每个 `MediaDecoder` 实现通过此结构声明自己支持的文件格式、UTType
/// 以及优先级。`CompositeMediaService` 根据此信息路由到最优解码器。
public struct MediaCapability: Sendable, Hashable {
    /// 支持的文件扩展名（小写，不含点号）
    public let fileExtensions: Set<String>
    /// 支持的 UTType 标识符
    public let utTypes: Set<String>
    /// 解码器名称（日志/调试用）
    public let name: String
    /// 优先级（数字越大越优先，相同优先级按注册顺序）
    public let priority: Int

    public init(
        fileExtensions: Set<String>,
        utTypes: Set<String> = [],
        name: String,
        priority: Int
    ) {
        self.fileExtensions = fileExtensions
        self.utTypes = utTypes
        self.name = name
        self.priority = priority
    }
}

// MARK: - 探测结果

/// 文件探测结果
///
/// 由 `MediaDecoder.probe()` 返回，包含格式元数据和支持评分。
/// `CompositeMediaService` 根据 `score` 选择最优解码器。
public struct ProbeResult: Sendable {
    /// 支持评分 (0-100)。0 表示不支持，越高表示越适合处理该文件
    public let score: Int
    /// 媒体类型
    public let mediaType: MediaType
    /// 容器格式 (如 "mp4", "mkv", "mov")
    public let containerFormat: String?
    /// 编解码器 (如 "h264", "hevc", "prores")
    public let codec: String?
    /// 时长（秒），照片为 nil
    public let duration: Double?
    /// 分辨率
    public let resolution: (width: Int, height: Int)?
    /// 帧率（仅视频有值）
    public let fps: Double?

    public init(
        score: Int,
        mediaType: MediaType,
        containerFormat: String? = nil,
        codec: String? = nil,
        duration: Double? = nil,
        resolution: (width: Int, height: Int)? = nil,
        fps: Double? = nil
    ) {
        self.score = score
        self.mediaType = mediaType
        self.containerFormat = containerFormat
        self.codec = codec
        self.duration = duration
        self.resolution = resolution
        self.fps = fps
    }

    /// 不支持的结果 (score=0)
    public static func unsupported(mediaType: MediaType = .video) -> ProbeResult {
        ProbeResult(score: 0, mediaType: mediaType)
    }
}

// MARK: - 格式支持级别

/// 解码器对某格式的支持级别
public enum FormatSupportLevel: Sendable {
    /// 完整解码（帧提取 + 音频 + 元数据）
    case fullDecode
    /// 仅元数据（通过 sidecar 或容器头）
    case metadataOnly
    /// 完全不支持
    case unsupported
}

// MARK: - 错误类型

/// 媒体服务错误
public enum MediaError: Error, LocalizedError {
    /// 没有可用的解码器处理该文件
    case noDecoderAvailable(path: String)
    /// 操作不受支持（如 AVFoundation 不支持 16kHz WAV 音频提取）
    case operationNotSupported(String)
    /// 探测失败
    case probeFailed(path: String, underlying: Error)
    /// 解码失败
    case decodeFailed(path: String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .noDecoderAvailable(let path):
            return "没有可用的解码器处理: \(path)"
        case .operationNotSupported(let op):
            return "操作不受支持: \(op)"
        case .probeFailed(let path, let error):
            return "探测失败 \(path): \(error.localizedDescription)"
        case .decodeFailed(let path, let error):
            return "解码失败 \(path): \(error.localizedDescription)"
        }
    }
}
