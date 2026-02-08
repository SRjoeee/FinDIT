import Foundation
import CxxHash

/// 文件完整性校验工具
///
/// 使用 xxHash3-128 算法计算文件哈希值。xxHash3-128 是 Hedge、Silverstack、Kyno 等
/// 专业 DIT 工具的标准选择，在 Apple Silicon 上可达 ~13 GB/s 吞吐量。
///
/// 128 位碰撞安全对本地文件去重和完整性校验绰绰有余（需 ~2^64 个不同文件
/// 才有可能碰撞）。输出格式与 ASC-MHL 标准兼容。
public enum FileHasher {

    /// 流式读取缓冲区大小: 1 MB
    ///
    /// 平衡吞吐量与内存占用。过小会增加系统调用次数，过大会浪费内存。
    static let bufferSize = 1_048_576

    /// 计算文件的 xxHash3-128 全文件哈希
    ///
    /// 使用流式 API 处理任意大小的文件，内存占用固定为 ~1 MB。
    ///
    /// - Parameter filePath: 文件的绝对路径
    /// - Returns: 32 字符 hex string（128 位，小写）
    /// - Throws: 文件不存在或无法读取时抛出错误
    public static func hash128(filePath: String) throws -> String {
        let url = URL(fileURLWithPath: filePath)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let state = XXH3_createState() else {
            throw FileHasherError.stateCreationFailed
        }
        defer { XXH3_freeState(state) }

        let resetResult = XXH3_128bits_reset(state)
        guard resetResult != XXH_ERROR else {
            throw FileHasherError.resetFailed
        }

        while true {
            let data = handle.readData(ofLength: bufferSize)
            if data.isEmpty { break }
            let updateResult = data.withUnsafeBytes { buffer -> XXH_errorcode in
                XXH3_128bits_update(state, buffer.baseAddress!, buffer.count)
            }
            guard updateResult != XXH_ERROR else {
                throw FileHasherError.updateFailed
            }
        }

        let result = XXH3_128bits_digest(state)
        return String(format: "%016llx%016llx", result.high64, result.low64)
    }

    /// 验证文件完整性
    ///
    /// 重新计算文件哈希并与期望值比较。
    ///
    /// - Parameters:
    ///   - filePath: 文件的绝对路径
    ///   - expectedHash: 之前存储的哈希值（32 字符 hex string）
    /// - Returns: 完整性状态
    public static func verify(filePath: String, expectedHash: String) -> IntegrityStatus {
        guard FileManager.default.fileExists(atPath: filePath) else {
            return .missing
        }
        do {
            let currentHash = try hash128(filePath: filePath)
            return currentHash == expectedHash ? .valid : .modified
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

// MARK: - 错误类型

/// FileHasher 内部错误
public enum FileHasherError: Error, LocalizedError {
    case stateCreationFailed
    case resetFailed
    case updateFailed

    public var errorDescription: String? {
        switch self {
        case .stateCreationFailed: return "xxHash state allocation failed"
        case .resetFailed: return "xxHash state reset failed"
        case .updateFailed: return "xxHash update failed"
        }
    }
}

// MARK: - 完整性状态

/// 文件完整性校验结果
public enum IntegrityStatus: Sendable, Equatable {
    /// 哈希匹配，文件未变
    case valid
    /// 哈希不匹配，文件已修改
    case modified
    /// 文件不存在
    case missing
    /// 校验过程出错
    case error(String)
}
