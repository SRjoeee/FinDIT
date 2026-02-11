import Foundation

/// CLI 工具执行器错误
public enum CLIToolRunnerError: Error, LocalizedError {
    case toolNotFound(String)
    case nonZeroExit(status: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let path):
            return "CLI tool not found: \(path)"
        case .nonZeroExit(let status, let stderr):
            return stderr.isEmpty ? "exit code \(status)" : stderr
        }
    }
}

/// 共享的外部 CLI 工具执行器
///
/// 封装 `Foundation.Process` 的管道安全模式（后台线程读 stdout/stderr 避免 64KB 死锁）
/// 和超时控制。供 `BRAWDecoder`、`R3DDecoder` 等 CLI 桥接解码器复用。
public enum CLIToolRunner {

    /// 执行外部 CLI 工具子命令
    ///
    /// - Parameters:
    ///   - toolPath: 可执行文件绝对路径
    ///   - arguments: 命令行参数
    ///   - timeout: 超时秒数
    /// - Returns: stdout 输出文本
    /// - Throws: `CLIToolRunnerError`
    public static func run(
        toolPath: String,
        arguments: [String],
        timeout: Double
    ) async throws -> String {
        guard FileManager.default.fileExists(atPath: toolPath) else {
            throw CLIToolRunnerError.toolNotFound(toolPath)
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: toolPath)
                process.arguments = arguments

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                // Read pipes on background threads to avoid 64KB deadlock
                var stdoutData = Data()
                var stderrData = Data()

                let stdoutGroup = DispatchGroup()
                let stderrGroup = DispatchGroup()

                stdoutGroup.enter()
                DispatchQueue.global().async {
                    stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    stdoutGroup.leave()
                }

                stderrGroup.enter()
                DispatchQueue.global().async {
                    stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    stderrGroup.leave()
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: CLIToolRunnerError.toolNotFound(toolPath))
                    return
                }

                // Timeout
                let timeoutItem = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + timeout, execute: timeoutItem
                )

                process.waitUntilExit()
                timeoutItem.cancel()

                stdoutGroup.wait()
                stderrGroup.wait()

                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                if process.terminationStatus != 0 {
                    let msg = stderr.isEmpty
                        ? "exit code \(process.terminationStatus)"
                        : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(
                        throwing: CLIToolRunnerError.nonZeroExit(
                            status: process.terminationStatus, stderr: msg
                        )
                    )
                } else {
                    continuation.resume(returning: stdout)
                }
            }
        }
    }
}
