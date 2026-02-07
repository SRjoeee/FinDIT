import Foundation
import MLXLMCommon
import MLXVLM

/// 本地视觉语言模型分析器
///
/// 使用 Qwen3-VL-4B (4-bit MLX) 在本地设备上分析视频帧，
/// 生成与 Gemini `AnalysisResult` 相同的 9 字段结构化输出。
///
/// 特点：
/// - 完全离线，无需 API Key
/// - ~3 GB 模型磁盘占用（首次使用时自动下载）
/// - Apple Silicon Metal GPU 加速
/// - 中文质量 ~8-9/10
/// - 质量接近 Qwen2.5-VL-7B，256K 上下文，改进的空间理解
///
/// 分析质量约为 Gemini 2.5 Flash 的 75-80%，适合离线使用或作为 Gemini 的降级方案。
public enum LocalVLMAnalyzer {

    /// 默认模型 ID
    public static let defaultModelId = "mlx-community/Qwen3-VL-4B-Instruct-4bit"

    /// 模型容器缓存 actor（线程安全，含 single-flight 防重复加载）
    private actor ModelCache {
        var container: ModelContainer?
        private var loadingTask: Task<ModelContainer, Error>?

        func get() -> ModelContainer? { container }
        func set(_ c: ModelContainer) { container = c }
        func clear() { container = nil; loadingTask = nil }

        /// 获取缓存或发起唯一加载任务（single-flight）
        ///
        /// 只支持 `defaultModelId`，确保并发调用不会加载不同模型。
        func getOrLoad() async throws -> ModelContainer {
            if let cached = container { return cached }
            if let task = loadingTask { return try await task.value }

            let task = Task<ModelContainer, Error> {
                try await loadModelContainer(id: LocalVLMAnalyzer.defaultModelId)
            }
            loadingTask = task
            do {
                let result = try await task.value
                container = result
                loadingTask = nil
                return result
            } catch {
                loadingTask = nil
                throw error
            }
        }
    }

    private static let cache = ModelCache()

    /// 检查本地 VLM 是否可用（模型已下载）
    public static func isModelDownloaded() -> Bool {
        let cacheDir = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first
        guard let cacheDir else { return false }
        let modelDir = cacheDir
            .appendingPathComponent("huggingface")
            .appendingPathComponent("models")
            .appendingPathComponent("mlx-community")
            .appendingPathComponent("Qwen3-VL-4B-Instruct-4bit")
        return FileManager.default.fileExists(atPath: modelDir.path)
    }

    /// 加载默认模型（首次调用时下载 ~3 GB）
    ///
    /// 模型容器会被缓存，后续调用直接返回。
    /// 使用 single-flight 模式防止并发调用重复下载/加载模型。
    /// 只支持 `defaultModelId`，不接受自定义模型。
    ///
    /// - Returns: 已加载的 ModelContainer
    public static func loadModel() async throws -> ModelContainer {
        try await cache.getOrLoad()
    }

    /// 分析单张图片
    ///
    /// - Parameters:
    ///   - imagePath: JPEG 图片文件路径
    ///   - container: 已加载的模型容器
    /// - Returns: 结构化分析结果
    public static func analyzeImage(
        imagePath: String,
        container: ModelContainer
    ) async throws -> AnalysisResult {
        guard FileManager.default.fileExists(atPath: imagePath) else {
            throw VisionAnalyzerError.imageEncodingFailed(path: imagePath)
        }

        let imageURL = URL(fileURLWithPath: imagePath)
        let session = ChatSession(container)

        let response = try await session.respond(
            to: analysisPrompt,
            image: .url(imageURL)
        )

        return parseResponse(response)
    }

    /// 分析一组图片（同一个 clip 的多帧）
    ///
    /// 发送多帧给模型，获取综合分析结果。
    ///
    /// - Parameters:
    ///   - imagePaths: JPEG 图片文件路径数组
    ///   - container: 已加载的模型容器
    /// - Returns: 结构化分析结果
    public static func analyzeClip(
        imagePaths: [String],
        container: ModelContainer
    ) async throws -> AnalysisResult {
        guard !imagePaths.isEmpty else {
            return emptyResult()
        }

        // 单张直接分析
        if imagePaths.count == 1 {
            return try await analyzeImage(imagePath: imagePaths[0], container: container)
        }

        // 多帧：发送前 3 张（避免上下文过长）
        let paths = Array(imagePaths.prefix(3))
        let images: [UserInput.Image] = paths.compactMap { path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return .url(URL(fileURLWithPath: path))
        }

        guard !images.isEmpty else {
            return emptyResult()
        }

        let session = ChatSession(container)
        let response = try await session.respond(
            to: analysisPrompt,
            images: images,
            videos: []
        )

        return parseResponse(response)
    }

    /// 释放模型（释放 GPU 内存）
    public static func unloadModel() async {
        await cache.clear()
    }

    // MARK: - Internal

    /// 分析提示词（由 VisionField 数据驱动生成）
    static var analysisPrompt: String {
        VisionField.buildVLMPrompt()
    }

    /// 创建空的 AnalysisResult
    static func emptyResult() -> AnalysisResult {
        AnalysisResult(
            scene: nil, subjects: [], actions: [], objects: [],
            mood: nil, shotType: nil, lighting: nil, colors: nil,
            description: nil
        )
    }

    /// 解析模型 JSON 响应为 AnalysisResult
    static func parseResponse(_ response: String) -> AnalysisResult {
        // 清理 markdown 代码块
        var cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 尝试提取 JSON 对象
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[start...end])
        }

        guard let data = cleaned.data(using: .utf8) else {
            return emptyResult()
        }

        do {
            return try JSONDecoder().decode(AnalysisResult.self, from: data)
        } catch {
            // 解析失败返回空结果
            return emptyResult()
        }
    }
}
