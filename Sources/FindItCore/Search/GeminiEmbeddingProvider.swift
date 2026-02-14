import Foundation

// MARK: - GeminiEmbedding

/// 文本嵌入引擎
///
/// 调用 API（Gemini / OpenRouter）计算文本向量嵌入。
/// 默认使用 gemini-embedding-001 模型，通过 outputDimensionality 控制输出维度（默认 768）。
///
/// 所有方法为 static，遵循项目 enum + static 模式。
/// 复用 `APIKeyManager` 的 Key 管理逻辑。
public enum GeminiEmbedding {

    /// API 配置
    public struct Config: Sendable {
        /// 嵌入模型名称
        public var model: String
        /// 输出向量维度（gemini-embedding-001 原生 3072，可降维到 768）
        public var outputDimensionality: Int
        /// HTTP 请求超时（秒）
        public var requestTimeoutSeconds: Double
        /// 最大重试次数
        public var maxRetries: Int
        /// 单次批量请求最大文本数
        public var maxBatchSize: Int
        /// API 提供者
        public var provider: APIProvider
        /// API base URL
        public var baseURL: String

        public static let `default` = Config(
            model: "gemini-embedding-001",
            outputDimensionality: 768,
            requestTimeoutSeconds: 30.0,
            maxRetries: 3,
            maxBatchSize: 100,
            provider: .gemini,
            baseURL: APIProvider.gemini.defaultBaseURL
        )

        public init(
            model: String = "gemini-embedding-001",
            outputDimensionality: Int = 768,
            requestTimeoutSeconds: Double = 30.0,
            maxRetries: Int = 3,
            maxBatchSize: Int = 100,
            provider: APIProvider = .gemini,
            baseURL: String = APIProvider.gemini.defaultBaseURL
        ) {
            self.model = model
            self.outputDimensionality = outputDimensionality
            self.requestTimeoutSeconds = requestTimeoutSeconds
            self.maxRetries = maxRetries
            self.maxBatchSize = maxBatchSize
            self.provider = provider
            self.baseURL = baseURL
        }
    }

    /// 默认输出向量维度（通过 Config.outputDimensionality 可调）
    public static let defaultDimensions = 768

    // MARK: - 请求构建

    /// 构建嵌入请求体（单文本，按 provider 分支）
    static func buildEmbedRequestBody(
        text: String,
        config: Config = .default
    ) throws -> Data {
        switch config.provider {
        case .gemini, .findItCloud:
            return try buildGeminiEmbedBody(text: text, config: config)
        case .openRouter:
            return try buildOpenRouterEmbedBody(texts: [text], config: config)
        }
    }

    /// 构建批量嵌入请求体（按 provider 分支）
    static func buildBatchRequestBody(
        texts: [String],
        config: Config = .default
    ) throws -> Data {
        switch config.provider {
        case .gemini, .findItCloud:
            return try buildGeminiBatchBody(texts: texts, config: config)
        case .openRouter:
            return try buildOpenRouterEmbedBody(texts: texts, config: config)
        }
    }

    // MARK: - Gemini 格式

    private static func buildGeminiEmbedBody(text: String, config: Config) throws -> Data {
        var body: [String: Any] = [
            "model": "models/\(config.model)",
            "content": [
                "parts": [["text": text]]
            ]
        ]
        body["outputDimensionality"] = config.outputDimensionality
        return try JSONSerialization.data(withJSONObject: body)
    }

    private static func buildGeminiBatchBody(texts: [String], config: Config) throws -> Data {
        let requests = texts.map { text in
            [
                "model": "models/\(config.model)",
                "content": [
                    "parts": [["text": text]]
                ],
                "outputDimensionality": config.outputDimensionality
            ] as [String: Any]
        }
        let body: [String: Any] = ["requests": requests]
        return try JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - OpenRouter (OpenAI 兼容) 格式

    private static func buildOpenRouterEmbedBody(texts: [String], config: Config) throws -> Data {
        let input: Any = texts.count == 1 ? texts[0] : texts
        var body: [String: Any] = [
            "model": config.model,
            "input": input,
        ]
        body["dimensions"] = config.outputDimensionality
        return try JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - 响应解析

    /// 解析单文本嵌入响应（按 provider 分支）
    static func parseEmbedResponse(_ data: Data, provider: APIProvider = .gemini) throws -> [Float] {
        switch provider {
        case .gemini, .findItCloud:
            return try parseGeminiEmbedResponse(data)
        case .openRouter:
            let results = try parseOpenRouterEmbedResponse(data)
            guard let first = results.first else {
                throw EmbeddingError.embeddingFailed(detail: "OpenRouter 返回空 embedding")
            }
            return first
        }
    }

    /// 解析批量嵌入响应（按 provider 分支）
    static func parseBatchResponse(_ data: Data, provider: APIProvider = .gemini) throws -> [[Float]] {
        switch provider {
        case .gemini, .findItCloud:
            return try parseGeminiBatchResponse(data)
        case .openRouter:
            return try parseOpenRouterEmbedResponse(data)
        }
    }

    // MARK: - Gemini 响应解析

    /// Gemini embedContent 响应: `{ "embedding": { "values": [...] } }`
    private static func parseGeminiEmbedResponse(_ data: Data) throws -> [Float] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let embedding = json["embedding"] as? [String: Any],
              let values = embedding["values"] as? [Any] else {
            throw EmbeddingError.embeddingFailed(detail: "无法解析 embedding.values")
        }
        return parseFloatArray(values)
    }

    /// Gemini batchEmbedContents 响应: `{ "embeddings": [{ "values": [...] }, ...] }`
    private static func parseGeminiBatchResponse(_ data: Data) throws -> [[Float]] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let embeddings = json["embeddings"] as? [[String: Any]] else {
            throw EmbeddingError.embeddingFailed(detail: "无法解析 embeddings 数组")
        }
        return try embeddings.map { emb in
            guard let values = emb["values"] as? [Any] else {
                throw EmbeddingError.embeddingFailed(detail: "embedding 缺少 values 字段")
            }
            return parseFloatArray(values)
        }
    }

    // MARK: - OpenRouter 响应解析

    /// OpenRouter (OpenAI) 响应: `{ "data": [{ "embedding": [...] }, ...] }`
    private static func parseOpenRouterEmbedResponse(_ data: Data) throws -> [[Float]] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            throw EmbeddingError.embeddingFailed(detail: "无法解析 data 数组")
        }
        return try dataArray.map { item in
            guard let embedding = item["embedding"] as? [Any] else {
                throw EmbeddingError.embeddingFailed(detail: "data 元素缺少 embedding 字段")
            }
            return parseFloatArray(embedding)
        }
    }

    /// 将 JSON 数值数组转为 [Float]
    private static func parseFloatArray(_ values: [Any]) -> [Float] {
        values.compactMap { value -> Float? in
            if let num = value as? Double {
                return Float(num)
            }
            if let num = value as? NSNumber {
                return num.floatValue
            }
            return nil
        }
    }

    /// 解析 API 错误响应（Gemini 和 OpenRouter 格式兼容）
    static func parseErrorResponse(_ data: Data) -> (code: Int, message: String)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else {
            return nil
        }
        let code: Int
        if let intCode = error["code"] as? Int {
            code = intCode
        } else if let strCode = error["code"] as? String, let parsed = Int(strCode) {
            code = parsed
        } else {
            return nil
        }
        let message = error["message"] as? String ?? "未知错误"
        return (code, message)
    }

    // MARK: - HTTP 请求

    /// 判断 HTTP 状态码是否应重试
    static func shouldRetry(statusCode: Int) -> Bool {
        statusCode == 429 || statusCode == 503 || statusCode == 500
    }

    /// 构建 URLRequest（按 provider 构建 URL 和 auth）
    static func buildURLRequest(
        body: Data,
        apiKey: String,
        endpoint: String,
        config: Config
    ) throws -> URLRequest {
        let urlString: String
        switch config.provider {
        case .gemini, .findItCloud:
            urlString = "\(config.baseURL)/models/\(config.model):\(endpoint)"
        case .openRouter:
            urlString = "\(config.baseURL)/embeddings"
        }
        guard let url = URL(string: urlString) else {
            throw EmbeddingError.embeddingFailed(detail: "无效的模型名: \(config.model)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            config.provider.authHeaderValue(apiKey: apiKey),
            forHTTPHeaderField: config.provider.authHeaderName
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if config.provider == .openRouter {
            request.setValue("FindIt", forHTTPHeaderField: "X-Title")
        }
        request.timeoutInterval = config.requestTimeoutSeconds
        request.httpBody = body
        return request
    }

    /// 发送 HTTP 请求（含重试逻辑）
    static func sendRequest(
        body: Data,
        apiKey: String,
        endpoint: String,
        config: Config,
        attempt: Int = 1
    ) async throws -> Data {
        let request = try buildURLRequest(body: body, apiKey: apiKey, endpoint: endpoint, config: config)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if attempt < config.maxRetries {
                let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
                return try await sendRequest(body: body, apiKey: apiKey, endpoint: endpoint, config: config, attempt: attempt + 1)
            }
            throw EmbeddingError.networkError(detail: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmbeddingError.networkError(detail: "非 HTTP 响应")
        }

        if httpResponse.statusCode == 200 {
            return data
        }

        if shouldRetry(statusCode: httpResponse.statusCode) && attempt < config.maxRetries {
            let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
            try await Task.sleep(nanoseconds: delay)
            return try await sendRequest(body: body, apiKey: apiKey, endpoint: endpoint, config: config, attempt: attempt + 1)
        }

        let errorInfo = parseErrorResponse(data)
        throw EmbeddingError.apiError(
            statusCode: httpResponse.statusCode,
            message: errorInfo?.message ?? "HTTP \(httpResponse.statusCode)"
        )
    }

    // MARK: - 公开接口

    /// 计算单文本的嵌入向量
    ///
    /// - Parameters:
    ///   - text: 待嵌入文本
    ///   - apiKey: API Key
    ///   - config: API 配置（含 provider 和 baseURL）
    /// - Returns: 嵌入向量（维度由 Config.outputDimensionality 决定，默认 768）
    public static func embed(
        text: String,
        apiKey: String,
        config: Config = .default
    ) async throws -> [Float] {
        let body = try buildEmbedRequestBody(text: text, config: config)
        let responseData = try await sendRequest(
            body: body, apiKey: apiKey,
            endpoint: "embedContent", config: config
        )
        return try parseEmbedResponse(responseData, provider: config.provider)
    }

    /// 批量计算嵌入向量
    ///
    /// Gemini 使用 batchEmbedContents API，OpenRouter 使用 input 数组。
    /// 超过限制时自动分批处理。
    ///
    /// - Parameters:
    ///   - texts: 待嵌入文本数组
    ///   - apiKey: API Key
    ///   - config: API 配置（含 provider 和 baseURL）
    /// - Returns: 嵌入向量数组（与输入顺序对应）
    public static func embedBatch(
        texts: [String],
        apiKey: String,
        config: Config = .default
    ) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        var allResults: [[Float]] = []

        // 分批处理
        var startIndex = 0
        while startIndex < texts.count {
            let endIndex = min(startIndex + config.maxBatchSize, texts.count)
            let batch = Array(texts[startIndex..<endIndex])

            let body = try buildBatchRequestBody(texts: batch, config: config)
            let responseData = try await sendRequest(
                body: body, apiKey: apiKey,
                endpoint: "batchEmbedContents", config: config
            )
            let batchResults = try parseBatchResponse(responseData, provider: config.provider)
            allResults.append(contentsOf: batchResults)

            startIndex = endIndex
        }

        return allResults
    }
}

// MARK: - GeminiEmbeddingProvider

/// 嵌入提供者（EmbeddingProvider 协议封装）
///
/// 将 GeminiEmbedding static 方法封装为 EmbeddingProvider 实例，
/// 便于与其他 provider 统一调用。
public final class GeminiEmbeddingProvider: EmbeddingProvider, Sendable {
    private let apiKey: String
    private let config: GeminiEmbedding.Config

    public let name = "gemini"
    public let dimensions: Int

    /// 创建嵌入提供者
    ///
    /// - Parameters:
    ///   - apiKey: API Key
    ///   - config: API 配置（含 provider 和 baseURL）
    public init(apiKey: String, config: GeminiEmbedding.Config = .default) {
        self.apiKey = apiKey
        self.config = config
        self.dimensions = config.outputDimensionality
    }

    public func isAvailable() -> Bool {
        APIKeyManager.validateAPIKey(apiKey)
    }

    public func embed(text: String) async throws -> [Float] {
        try await GeminiEmbedding.embed(text: text, apiKey: apiKey, config: config)
    }

    public func embedBatch(texts: [String]) async throws -> [[Float]] {
        try await GeminiEmbedding.embedBatch(texts: texts, apiKey: apiKey, config: config)
    }
}
