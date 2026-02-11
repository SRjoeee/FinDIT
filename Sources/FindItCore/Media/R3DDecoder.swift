import Foundation
import os

/// RED R3D 解码器
///
/// 通过外部 CLI 工具 `r3d-tool` 解码 .r3d 文件。
/// `r3d-tool` 链接 RED SDK (R3DSDK v9.x)，需要用户自行编译安装。
///
/// 当 `r3d-tool` 不存在时，`probe()` 返回 score=0，
/// `CompositeMediaService` 会自动降级到下一个解码器。
///
/// Priority: 140（高于 AVFoundation 和 FFmpeg，低于 BRAW）
public final class R3DDecoder: MediaDecoder, @unchecked Sendable {

    private static let logger = Logger(subsystem: "com.findit.core", category: "R3DDecoder")

    public let capability = MediaCapability(
        fileExtensions: ["r3d"],
        utTypes: ["com.red.r3d"],
        name: "REDR3D",
        priority: 140
    )

    /// r3d-tool 可执行文件路径
    private let toolPath: String

    /// FFmpeg 配置（用于音频重采样）
    private let ffmpegConfig: FFmpegConfig

    public init(
        toolPath: String = "~/.local/bin/r3d-tool",
        ffmpegConfig: FFmpegConfig = .default
    ) {
        self.toolPath = NSString(string: toolPath).expandingTildeInPath
        self.ffmpegConfig = ffmpegConfig
    }

    // MARK: - MediaDecoder

    public func probe(filePath: String) async throws -> ProbeResult {
        let ext = (filePath as NSString).pathExtension.lowercased()
        guard ext == "r3d" else { return .unsupported() }
        guard FileManager.default.fileExists(atPath: toolPath) else {
            Self.logger.debug("r3d-tool not found at \(self.toolPath)")
            return .unsupported()
        }
        guard FileManager.default.fileExists(atPath: filePath) else {
            return .unsupported()
        }

        let output = try await runTool(arguments: ["probe", filePath], timeout: 15)

        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Self.logger.warning("Failed to parse r3d-tool probe output")
            return .unsupported()
        }

        let width = json["width"] as? Int ?? 0
        let height = json["height"] as? Int ?? 0
        let fps = json["fps"] as? Double ?? 0
        let duration = json["duration"] as? Double
        let codec = json["codec"] as? String ?? "redcode"

        return ProbeResult(
            score: 90,
            mediaType: .video,
            containerFormat: "r3d",
            codec: codec,
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
                underlying: R3DError.invalidOutput("extract-frames returned invalid JSON")
            )
        }

        return paths.compactMap { $0 as? String }
    }

    public func extractAudio(
        filePath: String,
        outputPath: String,
        sampleRate: Int
    ) async throws -> String {
        // Step 1: Extract native audio (48kHz, possibly multi-channel) via r3d-tool
        let nativeWav: String
        if sampleRate == 48000 {
            nativeWav = outputPath
        } else {
            nativeWav = (outputPath as NSString)
                .deletingPathExtension + "_native48k.wav"
        }

        // r3d-tool extract-audio outputs no JSON, just writes WAV and exits
        _ = try await runTool(
            arguments: ["extract-audio", filePath, nativeWav],
            timeout: 120
        )

        // Verify output exists
        guard FileManager.default.fileExists(atPath: nativeWav) else {
            throw MediaError.decodeFailed(
                path: filePath,
                underlying: R3DError.decodeFailed("extract-audio produced no output")
            )
        }

        // Step 2: Resample via FFmpeg if needed
        if sampleRate != 48000 {
            defer {
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

    /// 执行 r3d-tool 子命令，转换错误为 R3DError
    private func runTool(arguments: [String], timeout: Double) async throws -> String {
        do {
            return try await CLIToolRunner.run(
                toolPath: toolPath, arguments: arguments, timeout: timeout
            )
        } catch let error as CLIToolRunnerError {
            switch error {
            case .toolNotFound(let path):
                throw R3DError.toolNotFound(path)
            case .nonZeroExit(_, let stderr):
                throw R3DError.decodeFailed(stderr)
            }
        }
    }
}

// MARK: - Error

/// R3D 解码错误
public enum R3DError: Error, LocalizedError {
    case toolNotFound(String)
    case decodeFailed(String)
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let path):
            return "r3d-tool not found: \(path)"
        case .decodeFailed(let msg):
            return "R3D decode failed: \(msg)"
        case .invalidOutput(let msg):
            return "R3D invalid output: \(msg)"
        }
    }
}
