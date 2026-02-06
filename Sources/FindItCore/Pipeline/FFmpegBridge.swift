import Foundation

/// FFmpeg 相关错误
public enum FFmpegError: LocalizedError {
    /// FFmpeg 可执行文件未找到
    case executableNotFound(path: String)
    /// 输入文件不存在或不可访问
    case inputFileNotFound(path: String)
    /// FFmpeg 进程以非零状态码退出
    case processExitedWithError(exitCode: Int32, stderr: String)
    /// FFmpeg 进程执行超时
    case timeout(seconds: TimeInterval)
    /// 输出解析失败
    case outputParsingFailed(detail: String)
    /// 输出文件未生成
    case outputFileNotCreated(path: String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            return "FFmpeg 可执行文件未找到: \(path)"
        case .inputFileNotFound(let path):
            return "输入文件不存在: \(path)"
        case .processExitedWithError(let code, let stderr):
            let truncated = stderr.count > 500 ? String(stderr.suffix(500)) : stderr
            return "FFmpeg 退出码 \(code): \(truncated)"
        case .timeout(let seconds):
            return "FFmpeg 执行超时 (\(Int(seconds))s)"
        case .outputParsingFailed(let detail):
            return "FFmpeg 输出解析失败: \(detail)"
        case .outputFileNotCreated(let path):
            return "FFmpeg 未生成输出文件: \(path)"
        }
    }
}

/// FFmpeg 工具路径配置
public struct FFmpegConfig {
    /// ffmpeg 可执行文件路径
    public var ffmpegPath: String
    /// 默认超时时间（秒）
    public var defaultTimeout: TimeInterval

    /// 默认配置
    public static let `default` = FFmpegConfig(
        ffmpegPath: (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/ffmpeg"),
        defaultTimeout: 300
    )

    public init(ffmpegPath: String, defaultTimeout: TimeInterval = 300) {
        self.ffmpegPath = ffmpegPath
        self.defaultTimeout = defaultTimeout
    }
}

/// FFmpeg 子进程调用封装
///
/// 封装 Foundation.Process，提供 stdout/stderr 捕获、超时控制和错误处理。
/// 所有 FFmpeg 操作（音频提取、场景检测、关键帧提取）均通过此枚举调用。
public enum FFmpegBridge {

    /// 子进程执行结果
    public struct ProcessResult {
        /// 进程退出状态码
        public let exitCode: Int32
        /// 标准输出内容
        public let stdout: String
        /// 标准错误输出内容
        public let stderr: String
    }

    /// 验证 FFmpeg 可执行文件是否存在且可执行
    public static func validateExecutable(config: FFmpegConfig = .default) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: config.ffmpegPath) else {
            throw FFmpegError.executableNotFound(path: config.ffmpegPath)
        }
        guard fm.isExecutableFile(atPath: config.ffmpegPath) else {
            throw FFmpegError.executableNotFound(path: config.ffmpegPath)
        }
    }

    /// 获取 FFmpeg 版本信息（首行）
    public static func version(config: FFmpegConfig = .default) throws -> String {
        let result = try run(arguments: ["-version"], config: config, timeout: 10)
        guard let firstLine = result.stdout.split(separator: "\n").first else {
            throw FFmpegError.outputParsingFailed(detail: "无法解析版本信息")
        }
        return String(firstLine)
    }

    /// 获取视频文件时长（秒）
    ///
    /// 通过 `ffmpeg -i` 解析 stderr 中的 `Duration: HH:MM:SS.ss` 获取。
    /// FFmpeg 对无效输入文件会输出 Duration 后以非零退出，这里允许退出码 1。
    public static func videoDuration(inputPath: String, config: FFmpegConfig = .default) throws -> Double {
        guard FileManager.default.fileExists(atPath: inputPath) else {
            throw FFmpegError.inputFileNotFound(path: inputPath)
        }

        // ffmpeg -i 不指定输出时会返回退出码 1，但 stderr 中有 Duration 信息
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.ffmpegPath)
        process.arguments = ["-i", inputPath]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe() // 丢弃 stdout

        try process.run()

        // 在后台线程读取管道，防止大输出时管道缓冲区满导致死锁
        let group = DispatchGroup()
        var stderrResult = Data()
        group.enter()
        DispatchQueue.global().async {
            stderrResult = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        process.waitUntilExit()
        group.wait()

        let stderr = String(data: stderrResult, encoding: .utf8) ?? ""

        guard let duration = parseDuration(from: stderr) else {
            throw FFmpegError.outputParsingFailed(detail: "未找到 Duration 信息")
        }
        return duration
    }

    /// 执行 FFmpeg 命令
    ///
    /// - Parameters:
    ///   - arguments: 命令行参数（不含 ffmpeg 路径）
    ///   - config: FFmpeg 配置
    ///   - timeout: 超时时间（nil 使用 config.defaultTimeout）
    /// - Returns: ProcessResult
    /// - Throws: FFmpegError
    public static func run(
        arguments: [String],
        config: FFmpegConfig = .default,
        timeout: TimeInterval? = nil
    ) throws -> ProcessResult {
        try validateExecutable(config: config)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.ffmpegPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let effectiveTimeout = timeout ?? config.defaultTimeout

        try process.run()

        // 超时机制
        let timeoutItem = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + effectiveTimeout,
            execute: timeoutItem
        )

        // 在后台线程并发读取 stdout/stderr，防止管道缓冲区 (64KB) 满时
        // 进程阻塞在写管道、而主线程阻塞在 waitUntilExit 导致死锁。
        // 场景检测对长视频的 stderr 可达数 MB。
        let group = DispatchGroup()
        var stdoutResult = Data()
        var stderrResult = Data()

        group.enter()
        DispatchQueue.global().async {
            stdoutResult = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            stderrResult = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        process.waitUntilExit()
        timeoutItem.cancel()
        group.wait()

        let stdout = String(data: stdoutResult, encoding: .utf8) ?? ""
        let stderr = String(data: stderrResult, encoding: .utf8) ?? ""

        // 检查是否因超时被终止
        if process.terminationReason == .uncaughtSignal {
            throw FFmpegError.timeout(seconds: effectiveTimeout)
        }

        guard process.terminationStatus == 0 else {
            throw FFmpegError.processExitedWithError(
                exitCode: process.terminationStatus,
                stderr: stderr
            )
        }

        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    // MARK: - Internal

    /// 从 FFmpeg stderr 解析 Duration 行
    ///
    /// 格式: `Duration: 01:23:45.67, ...`
    static func parseDuration(from stderr: String) -> Double? {
        // 匹配 Duration: HH:MM:SS.ss
        guard let range = stderr.range(of: #"Duration:\s*(\d{2}):(\d{2}):(\d{2})\.(\d{2})"#,
                                        options: .regularExpression) else {
            return nil
        }
        let match = String(stderr[range])
        // 提取数字部分
        let parts = match.replacingOccurrences(of: "Duration:", with: "")
            .trimmingCharacters(in: .whitespaces)
            .split(separator: ":")
        guard parts.count == 3 else { return nil }

        let hours = Double(parts[0]) ?? 0
        // 秒部分含小数: "45.67"
        let minStr = parts[1]
        let secStr = parts[2]
        let minutes = Double(minStr) ?? 0
        let seconds = Double(secStr) ?? 0

        return hours * 3600 + minutes * 60 + seconds
    }
}
