import Foundation

// MARK: - VisionAnalyzerError

/// 视觉分析相关错误
public enum VisionAnalyzerError: LocalizedError {
    /// API Key 未找到（文件/环境变量/CLI 均无）
    case apiKeyNotFound
    /// 图片文件不存在或无法读取
    case imageEncodingFailed(path: String)
    /// 网络请求失败
    case networkError(detail: String)
    /// Gemini API 返回错误
    case apiError(statusCode: Int, message: String)
    /// 触发速率限制 (429)
    case rateLimitExceeded
    /// 响应格式不合法
    case invalidResponse(detail: String)

    public var errorDescription: String? {
        switch self {
        case .apiKeyNotFound:
            return "Gemini API Key 未找到。请将 Key 写入 ~/.config/findit/gemini-api-key.txt 或设置 GEMINI_API_KEY 环境变量"
        case .imageEncodingFailed(let path):
            return "图片编码失败: \(path)"
        case .networkError(let detail):
            return "网络请求失败: \(detail)"
        case .apiError(let statusCode, let message):
            return "Gemini API 错误 (\(statusCode)): \(message)"
        case .rateLimitExceeded:
            return "已触发 Gemini API 速率限制 (429)，请稍后重试"
        case .invalidResponse(let detail):
            return "响应格式不合法: \(detail)"
        }
    }
}

// MARK: - AnalysisResult

/// Gemini 视觉分析结果
///
/// 对应 Clip 模型的 scene/subjects/actions/objects/mood/shotType/lighting/colors/description 字段。
/// `tags` 从所有字段去重合成。
public struct AnalysisResult: Equatable, Codable {
    public let scene: String?
    public let subjects: [String]
    public let actions: [String]
    public let objects: [String]
    public let mood: String?
    public let shotType: String?
    public let lighting: String?
    public let colors: String?
    public let description: String?
    public let tags: [String]

    enum CodingKeys: String, CodingKey {
        case scene, subjects, actions, objects, mood
        case shotType = "shot_type"
        case lighting, colors, description
        case tags
    }

    public init(
        scene: String?,
        subjects: [String],
        actions: [String],
        objects: [String],
        mood: String?,
        shotType: String?,
        lighting: String?,
        colors: String?,
        description: String?
    ) {
        self.scene = scene
        self.subjects = subjects
        self.actions = actions
        self.objects = objects
        self.mood = mood
        self.shotType = shotType
        self.lighting = lighting
        self.colors = colors
        self.description = description
        self.tags = AnalysisResult.composeTags(
            scene: scene,
            subjects: subjects,
            actions: actions,
            objects: objects,
            mood: mood,
            shotType: shotType,
            lighting: lighting,
            colors: colors
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scene = try container.decodeIfPresent(String.self, forKey: .scene)
        subjects = (try? container.decode([String].self, forKey: .subjects)) ?? []
        actions = (try? container.decode([String].self, forKey: .actions)) ?? []
        objects = (try? container.decode([String].self, forKey: .objects)) ?? []
        mood = try container.decodeIfPresent(String.self, forKey: .mood)
        shotType = try container.decodeIfPresent(String.self, forKey: .shotType)
        lighting = try container.decodeIfPresent(String.self, forKey: .lighting)
        colors = try container.decodeIfPresent(String.self, forKey: .colors)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        // tags: 优先从 JSON 读取，否则自动合成
        if let decodedTags = try? container.decode([String].self, forKey: .tags), !decodedTags.isEmpty {
            tags = decodedTags
        } else {
            tags = AnalysisResult.composeTags(
                scene: scene, subjects: subjects, actions: actions, objects: objects,
                mood: mood, shotType: shotType, lighting: lighting, colors: colors
            )
        }
    }

    /// 从各字段去重合成 tags 数组
    ///
    /// 收集 scene、subjects、actions、objects、mood、shotType、lighting、colors，
    /// 过滤空白，去重，保持插入顺序。
    static func composeTags(
        scene: String?,
        subjects: [String],
        actions: [String],
        objects: [String],
        mood: String?,
        shotType: String?,
        lighting: String?,
        colors: String?
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        func add(_ value: String?) {
            guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !v.isEmpty, !seen.contains(v) else { return }
            seen.insert(v)
            result.append(v)
        }

        add(scene)
        subjects.forEach { add($0) }
        actions.forEach { add($0) }
        objects.forEach { add($0) }
        add(mood)
        add(shotType)
        add(lighting)
        add(colors)

        return result
    }
}

// MARK: - AnalysisResult + VisionField

extension AnalysisResult {

    /// 按 VisionField 获取字段的字符串值
    ///
    /// 数组字段用逗号拼接为单个字符串。
    public func stringValue(for field: VisionField) -> String? {
        switch field {
        case .scene:       return scene
        case .subjects:    return subjects.isEmpty ? nil : subjects.joined(separator: ", ")
        case .actions:     return actions.isEmpty ? nil : actions.joined(separator: ", ")
        case .objects:     return objects.isEmpty ? nil : objects.joined(separator: ", ")
        case .mood:        return mood
        case .shotType:    return shotType
        case .lighting:    return lighting
        case .colors:      return colors
        case .description: return description
        }
    }

    /// 按 VisionField 获取字段的数组值
    ///
    /// 字符串字段包为单元素数组（nil → 空数组）。
    public func arrayValue(for field: VisionField) -> [String] {
        switch field {
        case .scene:       return scene.map { [$0] } ?? []
        case .subjects:    return subjects
        case .actions:     return actions
        case .objects:     return objects
        case .mood:        return mood.map { [$0] } ?? []
        case .shotType:    return shotType.map { [$0] } ?? []
        case .lighting:    return lighting.map { [$0] } ?? []
        case .colors:      return colors.map { [$0] } ?? []
        case .description: return description.map { [$0] } ?? []
        }
    }

    /// 从 Clip 记录重建 AnalysisResult
    ///
    /// Clip 中数组字段存储为 JSON 字符串（如 `["man","woman"]`），
    /// 此方法解析 JSON 并还原为 AnalysisResult。
    /// 用于 Pipeline 步骤 4 中与 Gemini/VLM 结果合并。
    public static func fromClip(_ clip: Clip) -> AnalysisResult {
        func parseArray(_ json: String?) -> [String] {
            guard let json = json,
                  let data = json.data(using: .utf8),
                  let array = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return array
        }

        return AnalysisResult(
            scene: clip.scene,
            subjects: parseArray(clip.subjects),
            actions: parseArray(clip.actions),
            objects: parseArray(clip.objects),
            mood: clip.mood,
            shotType: clip.shotType,
            lighting: clip.lighting,
            colors: clip.colors,
            description: clip.clipDescription
        )
    }

    /// 数据驱动的 composeTags
    ///
    /// 从指定字段列表中收集值，去重后返回标签数组。
    /// 默认只处理 `includeInTags == true` 的字段（排除 description）。
    public static func composeTags(
        from result: AnalysisResult,
        fields: [VisionField] = VisionField.allActive.filter(\.includeInTags)
    ) -> [String] {
        var seen = Set<String>()
        var tags: [String] = []

        func add(_ value: String?) {
            guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !v.isEmpty, !seen.contains(v) else { return }
            seen.insert(v)
            tags.append(v)
        }

        for field in fields {
            if field.isArray {
                for item in result.arrayValue(for: field) {
                    add(item)
                }
            } else {
                add(result.stringValue(for: field))
            }
        }

        return tags
    }
}

// MARK: - VisionAnalyzer

/// Gemini Flash 视觉分析器
///
/// 将关键帧图片发送到 Gemini 2.5 Flash，获取结构化 JSON 描述。
/// 所有方法为 static，遵循项目 enum + static 模式。
public enum VisionAnalyzer {

    /// 视觉分析配置
    public struct Config {
        /// Gemini 模型名称
        public var model: String
        /// 每请求最大图片数
        public var maxImagesPerRequest: Int
        /// HTTP 请求超时（秒）
        public var requestTimeoutSeconds: Double
        /// 最大重试次数（针对 429/503）
        public var maxRetries: Int

        public static let `default` = Config(
            model: "gemini-2.5-flash",
            maxImagesPerRequest: 10,
            requestTimeoutSeconds: 60.0,
            maxRetries: 3
        )

        public init(
            model: String = "gemini-2.5-flash",
            maxImagesPerRequest: Int = 10,
            requestTimeoutSeconds: Double = 60.0,
            maxRetries: Int = 3
        ) {
            self.model = model
            self.maxImagesPerRequest = maxImagesPerRequest
            self.requestTimeoutSeconds = requestTimeoutSeconds
            self.maxRetries = maxRetries
        }
    }

    // MARK: - API Key 默认路径

    /// 默认 API Key 文件路径
    public static let defaultAPIKeyPath = "~/.config/findit/gemini-api-key.txt"

    /// API Key 环境变量名
    public static let apiKeyEnvVar = "GEMINI_API_KEY"

    // MARK: - API Key 管理

    /// 解析 API Key（优先级：override > 文件 > 环境变量）
    ///
    /// - Parameter override: CLI 传入的 Key（最高优先级）
    /// - Returns: 有效的 API Key
    public static func resolveAPIKey(override: String? = nil) throws -> String {
        // 1. CLI override
        if let key = override, validateAPIKey(key) {
            return key
        }

        // 2. 配置文件
        let expandedPath = (defaultAPIKeyPath as NSString).expandingTildeInPath
        if let key = readAPIKeyFromFile(expandedPath), validateAPIKey(key) {
            return key
        }

        // 3. 环境变量
        if let key = ProcessInfo.processInfo.environment[apiKeyEnvVar],
           validateAPIKey(key) {
            return key
        }

        throw VisionAnalyzerError.apiKeyNotFound
    }

    /// 从文件读取 API Key
    ///
    /// - Parameter path: 文件绝对路径
    /// - Returns: trim 后的 Key，文件不存在或为空返回 nil
    static func readAPIKeyFromFile(_ path: String) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 验证 API Key 格式（基本检查）
    ///
    /// Gemini API Key 通常以 "AIza" 开头，长度约 39 字符。
    /// 这里只做最基本的非空 + 最短长度检查。
    static func validateAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 10
    }

    /// 确保 API Key 配置目录存在
    ///
    /// - Returns: 展开后的目录路径
    @discardableResult
    public static func ensureConfigDirectory() throws -> String {
        let expandedPath = (defaultAPIKeyPath as NSString).expandingTildeInPath
        let dir = (expandedPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        return dir
    }

    // MARK: - 图片编码

    /// 将图片文件编码为 base64 字符串
    ///
    /// - Parameter imagePath: JPEG 图片文件路径
    /// - Returns: base64 编码字符串
    static func encodeImageToBase64(imagePath: String) throws -> String {
        guard FileManager.default.fileExists(atPath: imagePath) else {
            throw VisionAnalyzerError.imageEncodingFailed(path: imagePath)
        }
        guard let data = FileManager.default.contents(atPath: imagePath) else {
            throw VisionAnalyzerError.imageEncodingFailed(path: imagePath)
        }
        return data.base64EncodedString()
    }

    // MARK: - Prompt

    /// 生成 Gemini 分析提示词（来自 PRODUCT_SPEC 3.2.5）
    static func formatPrompt() -> String {
        """
        你是一个视频素材分析助手。分析以下视频片段的关键帧（按时间顺序排列）。
        返回 JSON 格式的描述。
        """
    }

    // MARK: - Response Schema

    /// 构建 Gemini response_schema（结构化输出）
    ///
    /// 委托 VisionField.buildResponseSchema() 实现数据驱动。
    static func buildResponseSchema() -> [String: Any] {
        VisionField.buildResponseSchema()
    }

    // MARK: - 请求构建

    /// 构建 Gemini API 请求体
    ///
    /// - Parameters:
    ///   - imageBase64List: base64 编码的图片数组
    ///   - config: 视觉分析配置
    /// - Returns: JSON 序列化后的 Data
    static func buildRequestBody(
        imageBase64List: [String],
        config: Config = .default
    ) throws -> Data {
        var parts: [[String: Any]] = []

        // 图片 parts
        for base64 in imageBase64List {
            parts.append([
                "inline_data": [
                    "mime_type": "image/jpeg",
                    "data": base64,
                ]
            ])
        }

        // 文本 prompt
        parts.append(["text": formatPrompt()])

        let body: [String: Any] = [
            "contents": [
                ["parts": parts]
            ],
            "generationConfig": [
                "response_mime_type": "application/json",
                "response_schema": buildResponseSchema(),
            ],
        ]

        return try JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - 响应解析

    /// 解析 Gemini API 成功响应
    ///
    /// 响应格式:
    /// ```json
    /// { "candidates": [{ "content": { "parts": [{ "text": "{...}" }] } }] }
    /// ```
    static func parseResponse(_ responseData: Data) throws -> AnalysisResult {
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let textPart = parts.first,
              let text = textPart["text"] as? String else {
            throw VisionAnalyzerError.invalidResponse(detail: "无法提取 candidates[0].content.parts[0].text")
        }

        guard let textData = text.data(using: .utf8) else {
            throw VisionAnalyzerError.invalidResponse(detail: "text 字段非有效 UTF-8")
        }

        do {
            return try JSONDecoder().decode(AnalysisResult.self, from: textData)
        } catch {
            throw VisionAnalyzerError.invalidResponse(detail: "JSON 解码失败: \(error.localizedDescription)")
        }
    }

    /// 解析 Gemini API 错误响应
    ///
    /// 错误格式:
    /// ```json
    /// { "error": { "code": 429, "message": "...", "status": "RESOURCE_EXHAUSTED" } }
    /// ```
    static func parseErrorResponse(_ responseData: Data) -> (code: Int, message: String)? {
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let code = error["code"] as? Int else {
            return nil
        }
        let message = error["message"] as? String ?? "未知错误"
        return (code, message)
    }

    // MARK: - HTTP 请求

    /// 构建 URLRequest
    static func buildURLRequest(
        body: Data,
        apiKey: String,
        config: Config
    ) -> URLRequest {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(config.model):generateContent"
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = config.requestTimeoutSeconds
        request.httpBody = body
        return request
    }

    /// 判断 HTTP 状态码是否应重试
    static func shouldRetry(statusCode: Int) -> Bool {
        statusCode == 429 || statusCode == 503 || statusCode == 500
    }

    /// 发送 HTTP 请求（含重试逻辑）
    ///
    /// - Parameters:
    ///   - body: 请求体
    ///   - apiKey: API Key
    ///   - config: 配置
    ///   - attempt: 当前重试次数（1-based）
    /// - Returns: 响应数据
    static func sendRequest(
        body: Data,
        apiKey: String,
        config: Config,
        attempt: Int = 1
    ) async throws -> Data {
        let request = buildURLRequest(body: body, apiKey: apiKey, config: config)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if attempt < config.maxRetries {
                let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
                return try await sendRequest(body: body, apiKey: apiKey, config: config, attempt: attempt + 1)
            }
            throw VisionAnalyzerError.networkError(detail: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VisionAnalyzerError.networkError(detail: "非 HTTP 响应")
        }

        if httpResponse.statusCode == 200 {
            return data
        }

        // 可重试的错误
        if shouldRetry(statusCode: httpResponse.statusCode) && attempt < config.maxRetries {
            let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
            try await Task.sleep(nanoseconds: delay)
            return try await sendRequest(body: body, apiKey: apiKey, config: config, attempt: attempt + 1)
        }

        // 不可重试或已耗尽重试
        if httpResponse.statusCode == 429 {
            throw VisionAnalyzerError.rateLimitExceeded
        }

        let errorInfo = parseErrorResponse(data)
        throw VisionAnalyzerError.apiError(
            statusCode: httpResponse.statusCode,
            message: errorInfo?.message ?? "HTTP \(httpResponse.statusCode)"
        )
    }

    // MARK: - 主入口

    /// 分析单个场景的关键帧
    ///
    /// 将多张关键帧图片编码为 base64，发送到 Gemini API，解析结构化 JSON 结果。
    ///
    /// - Parameters:
    ///   - imagePaths: 关键帧图片路径数组
    ///   - apiKey: Gemini API Key
    ///   - config: 分析配置
    /// - Returns: 分析结果
    public static func analyzeScene(
        imagePaths: [String],
        apiKey: String,
        config: Config = .default
    ) async throws -> AnalysisResult {
        // 编码图片
        let limitedPaths = Array(imagePaths.prefix(config.maxImagesPerRequest))
        var base64List: [String] = []
        for path in limitedPaths {
            let base64 = try encodeImageToBase64(imagePath: path)
            base64List.append(base64)
        }

        // 构建请求
        let body = try buildRequestBody(imageBase64List: base64List, config: config)

        // 发送请求
        let responseData = try await sendRequest(body: body, apiKey: apiKey, config: config)

        // 解析响应
        return try parseResponse(responseData)
    }
}
