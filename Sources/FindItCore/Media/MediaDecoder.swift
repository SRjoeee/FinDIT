import Foundation

/// 媒体解码器协议
///
/// 定义了媒体文件的基本解码操作：探测、关键帧提取、音频提取。
/// 每个实现对应一个后端（FFmpeg、AVFoundation、BRAW SDK 等）。
///
/// `CompositeMediaService` 通过 `probe()` 的 `score` 选择最优解码器。
public protocol MediaDecoder: Sendable {

    /// 声明解码能力（支持的格式、优先级）
    var capability: MediaCapability { get }

    /// 探测文件，返回支持评分和元数据
    ///
    /// - Parameter filePath: 文件路径
    /// - Returns: 探测结果，score=0 表示不支持
    func probe(filePath: String) async throws -> ProbeResult

    /// 提取关键帧图像
    ///
    /// - Parameters:
    ///   - filePath: 视频文件路径
    ///   - times: 要提取的时间点（秒）
    ///   - outputDir: 输出目录
    ///   - maxDimension: 短边最大像素
    /// - Returns: 输出的 JPEG 文件路径列表
    func extractKeyframes(
        filePath: String,
        times: [Double],
        outputDir: String,
        maxDimension: Int
    ) async throws -> [String]

    /// 提取音频
    ///
    /// - Parameters:
    ///   - filePath: 视频文件路径
    ///   - outputPath: 输出音频文件路径
    ///   - sampleRate: 采样率 (Hz)
    /// - Returns: 输出文件路径
    func extractAudio(
        filePath: String,
        outputPath: String,
        sampleRate: Int
    ) async throws -> String
}
