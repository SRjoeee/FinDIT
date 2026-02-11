import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// AVFoundation 解码器
///
/// 对 Apple 原生支持的格式（H.264/H.265/ProRes）使用硬件加速解码，
/// 性能优于 FFmpeg 的纯软件解码。
///
/// 优先级 80（高于 FFmpeg 的 50），对 .mp4/.mov/.m4v 格式优先使用。
/// 对不支持的格式（如 MKV、MXF）probe 返回 score 0，自动 fallback 到 FFmpeg。
///
/// **限制**: 不支持场景检测（无 SceneDetectable），不支持 16kHz mono WAV 音频提取。
public final class AVFoundationDecoder: MediaDecoder, @unchecked Sendable {

    public let capability = MediaCapability(
        fileExtensions: ["mp4", "mov", "m4v"],
        utTypes: ["public.mpeg-4", "com.apple.quicktime-movie"],
        name: "AVFoundation",
        priority: 80
    )

    public init() {}

    // MARK: - MediaDecoder

    public func probe(filePath: String) async throws -> ProbeResult {
        guard FileManager.default.fileExists(atPath: filePath) else {
            return .unsupported()
        }

        let url = URL(fileURLWithPath: filePath)
        let asset = AVURLAsset(url: url)

        // 加载关键属性
        let isPlayable: Bool
        let duration: CMTime
        let tracks: [AVAssetTrack]

        do {
            (isPlayable, duration, tracks) = try await asset.load(
                .isPlayable, .duration, .tracks
            )
        } catch {
            return .unsupported()
        }

        guard isPlayable else {
            return .unsupported()
        }

        // 找到视频轨
        let videoTracks = tracks.filter { $0.mediaType == .video }
        guard !videoTracks.isEmpty else {
            return .unsupported()
        }

        let videoTrack = videoTracks[0]

        // 提取元数据
        let durationSeconds = CMTimeGetSeconds(duration)

        // 获取 codec、分辨率、帧率
        let (codec, resolution, fps) = await extractTrackInfo(videoTrack)

        // 从文件扩展名推断容器格式
        let ext = url.pathExtension.lowercased()

        return ProbeResult(
            score: 90,
            mediaType: .video,
            containerFormat: ext,
            codec: codec,
            duration: durationSeconds > 0 ? durationSeconds : nil,
            resolution: resolution,
            fps: fps
        )
    }

    public func extractKeyframes(
        filePath: String,
        times: [Double],
        outputDir: String,
        maxDimension: Int
    ) async throws -> [String] {
        guard !times.isEmpty else { return [] }

        let url = URL(fileURLWithPath: filePath)
        let asset = AVURLAsset(url: url)

        // 创建输出目录
        try FileManager.default.createDirectory(
            atPath: outputDir,
            withIntermediateDirectories: true
        )

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: CGFloat(maxDimension),
            height: CGFloat(maxDimension)
        )
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        var outputPaths: [String] = []

        // 使用 async images(for:) API (macOS 13+)
        let requestTimes = times.map { CMTime(seconds: $0, preferredTimescale: 600) }
        var index = 0
        for await result in generator.images(for: requestTimes) {
            let outputPath = (outputDir as NSString).appendingPathComponent(
                "frame_\(String(format: "%04d", index)).jpg"
            )

            switch result {
            case .success(_, let image, _):
                try writeCGImageAsJPEG(image, to: outputPath, quality: 0.85)
                outputPaths.append(outputPath)
            case .failure:
                // 跳过失败的帧，继续处理其他帧
                break
            }
            index += 1
        }

        return outputPaths
    }

    public func extractAudio(
        filePath: String,
        outputPath: String,
        sampleRate: Int
    ) async throws -> String {
        throw MediaError.operationNotSupported(
            "AVFoundation 不支持 \(sampleRate)Hz mono WAV 音频提取，请使用 FFmpeg"
        )
    }

    // MARK: - Private Helpers

    /// 从视频轨提取 codec、分辨率、帧率
    private func extractTrackInfo(
        _ track: AVAssetTrack
    ) async -> (codec: String?, resolution: (width: Int, height: Int)?, fps: Double?) {
        // 分辨率
        let naturalSize: CGSize
        let nominalFrameRate: Float
        let formatDescriptions: [CMFormatDescription]
        do {
            (naturalSize, nominalFrameRate, formatDescriptions) = try await track.load(
                .naturalSize, .nominalFrameRate, .formatDescriptions
            )
        } catch {
            return (nil, nil, nil)
        }

        let resolution: (width: Int, height: Int)?
        if naturalSize.width > 0 && naturalSize.height > 0 {
            resolution = (width: Int(naturalSize.width), height: Int(naturalSize.height))
        } else {
            resolution = nil
        }

        // 帧率
        let fps: Double? = nominalFrameRate > 0 ? Double(nominalFrameRate) : nil

        // Codec (从 format description 提取)
        let codec: String?
        if let firstFormat = formatDescriptions.first {
            let mediaSubType = CMFormatDescriptionGetMediaSubType(firstFormat)
            codec = fourCCToString(mediaSubType)
        } else {
            codec = nil
        }

        return (codec, resolution, fps)
    }

    /// FourCC 码转字符串 (如 'avc1' → "avc1")
    private func fourCCToString(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08X", code)
    }

    /// 将 CGImage 写出为 JPEG 文件
    private func writeCGImageAsJPEG(_ image: CGImage, to path: String, quality: Double) throws {
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw MediaError.decodeFailed(
                path: path,
                underlying: NSError(domain: "AVFoundationDecoder", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "无法创建 JPEG 写入目标"])
            )
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw MediaError.decodeFailed(
                path: path,
                underlying: NSError(domain: "AVFoundationDecoder", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "JPEG 写入失败"])
            )
        }
    }
}
