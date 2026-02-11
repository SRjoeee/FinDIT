import Foundation
import os

/// Blackmagic RAW 解码器
///
/// 通过外部 CLI 工具 `braw-tool` 解码 .braw 文件。
/// `braw-tool` 链接 Blackmagic RAW SDK，需要用户自行编译安装。
///
/// 当 `braw-tool` 不存在时，`probe()` 返回 score=0，
/// `CompositeMediaService` 会自动降级到下一个解码器。
///
/// Priority: 150（高于 AVFoundation 和 FFmpeg，BRAW 只能由此解码器处理）
public final class BRAWDecoder: MediaDecoder, @unchecked Sendable {

    private static let logger = Logger(subsystem: "com.findit.core", category: "BRAWDecoder")

    public let capability = MediaCapability(
        fileExtensions: ["braw"],
        utTypes: ["com.blackmagicdesign.braw"],
        name: "BlackmagicRAW",
        priority: 150
    )

    /// braw-tool 可执行文件路径
    private let toolPath: String

    /// FFmpeg 配置（用于音频重采样）
    private let ffmpegConfig: FFmpegConfig

    public init(
        toolPath: String = "~/.local/bin/braw-tool",
        ffmpegConfig: FFmpegConfig = .default
    ) {
        self.toolPath = NSString(string: toolPath).expandingTildeInPath
        self.ffmpegConfig = ffmpegConfig
    }

    // MARK: - MediaDecoder

    public func probe(filePath: String) async throws -> ProbeResult {
        let ext = (filePath as NSString).pathExtension.lowercased()
        guard ext == "braw" else { return .unsupported() }
        guard FileManager.default.fileExists(atPath: toolPath) else {
            Self.logger.debug("braw-tool not found at \(self.toolPath)")
            return .unsupported()
        }
        guard FileManager.default.fileExists(atPath: filePath) else {
            return .unsupported()
        }

        let output = try await runTool(arguments: ["probe", filePath], timeout: 15)

        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Self.logger.warning("Failed to parse braw-tool probe output")
            return .unsupported()
        }

        let width = json["width"] as? Int ?? 0
        let height = json["height"] as? Int ?? 0
        let fps = json["fps"] as? Double ?? 0
        let duration = json["duration"] as? Double

        return ProbeResult(
            score: 90,
            mediaType: .video,
            containerFormat: "braw",
            codec: "braw",
            duration: duration,
            resolution: (width: width, height: height),
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

        try FileManager.default.createDirectory(
            atPath: outputDir, withIntermediateDirectories: true
        )

        // Serialize times as JSON array
        let timesJSON = "[" + times.map { String(format: "%.4f", $0) }.joined(separator: ",") + "]"

        let output = try await runTool(
            arguments: [
                "extract-frames", filePath, timesJSON, outputDir,
                "--max-dim", String(maxDimension)
            ],
            timeout: Double(max(30, times.count * 10))
        )

        // Parse output JSON array of paths
        guard let data = output.data(using: .utf8),
              let paths = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw MediaError.decodeFailed(
                path: filePath,
                underlying: BRAWError.invalidOutput("extract-frames returned invalid JSON")
            )
        }

        return paths.compactMap { $0 as? String }
    }

    public func extractAudio(
        filePath: String,
        outputPath: String,
        sampleRate: Int
    ) async throws -> String {
        // Step 1: Extract native audio (48kHz) via braw-tool
        let nativeWav: String
        if sampleRate == 48000 {
            // No resample needed, write directly to output
            nativeWav = outputPath
        } else {
            // Write to temp, then resample
            nativeWav = (outputPath as NSString)
                .deletingPathExtension + "_native48k.wav"
        }

        let output = try await runTool(
            arguments: ["extract-audio", filePath, nativeWav],
            timeout: 120
        )

        // Check braw-tool output
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["sampleRate"] != nil else {
            throw MediaError.decodeFailed(
                path: filePath,
                underlying: BRAWError.invalidOutput("extract-audio failed")
            )
        }

        // Step 2: Resample via FFmpeg if needed
        if sampleRate != 48000 {
            defer {
                // Clean up temp native WAV
                try? FileManager.default.removeItem(atPath: nativeWav)
            }

            _ = try await FFmpegBridge.runAsync(
                arguments: [
                    "-y", "-i", nativeWav,
                    "-ar", String(sampleRate),
                    "-ac", "1",
                    outputPath
                ],
                config: ffmpegConfig,
                timeout: 60
            )
        }

        return outputPath
    }

    // MARK: - Tool Execution

    /// 执行 braw-tool 子命令，转换错误为 BRAWError
    private func runTool(arguments: [String], timeout: Double) async throws -> String {
        do {
            return try await CLIToolRunner.run(
                toolPath: toolPath, arguments: arguments, timeout: timeout
            )
        } catch let error as CLIToolRunnerError {
            switch error {
            case .toolNotFound(let path):
                throw BRAWError.toolNotFound(path)
            case .nonZeroExit(_, let stderr):
                throw BRAWError.decodeFailed(stderr)
            }
        }
    }
}

// MARK: - Error

/// BRAW 解码错误
public enum BRAWError: Error, LocalizedError {
    case toolNotFound(String)
    case decodeFailed(String)
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let path):
            return "braw-tool not found: \(path)"
        case .decodeFailed(let msg):
            return "BRAW decode failed: \(msg)"
        case .invalidOutput(let msg):
            return "BRAW invalid output: \(msg)"
        }
    }
}
