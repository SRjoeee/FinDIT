import Foundation

/// 媒体服务协议
///
/// 上层统一接口，由 `CompositeMediaService` 实现。
/// 调用者（PipelineManager、IndexingScheduler）通过此协议操作，
/// 无需关心底层使用哪个解码器。
public protocol MediaService: Sendable {

    /// 探测文件，返回最优解码器的探测结果
    func probe(filePath: String) async throws -> ProbeResult

    /// 提取关键帧图像
    func extractKeyframes(
        filePath: String,
        times: [Double],
        outputDir: String,
        maxDimension: Int
    ) async throws -> [String]

    /// 提取音频
    func extractAudio(
        filePath: String,
        outputPath: String,
        sampleRate: Int
    ) async throws -> String

    /// 查询对指定文件的支持级别
    func supportLevel(for filePath: String) async -> FormatSupportLevel
}
