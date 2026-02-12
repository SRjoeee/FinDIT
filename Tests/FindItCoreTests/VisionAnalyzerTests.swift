import XCTest
@testable import FindItCore

final class VisionAnalyzerTests: XCTestCase {

    // API Key 管理测试已迁移到 APIKeyManagerTests

    // MARK: - composeTags

    func testComposeTagsAllFields() {
        let tags = AnalysisResult.composeTags(
            scene: "室内办公室",
            subjects: ["年轻女性", "笔记本电脑"],
            actions: ["打字", "思考"],
            objects: ["咖啡杯", "记事本"],
            mood: "专注",
            shotType: "中景",
            lighting: "柔和自然光",
            colors: "暖色调"
        )
        XCTAssertEqual(tags, [
            "室内办公室", "年轻女性", "笔记本电脑",
            "打字", "思考", "咖啡杯", "记事本",
            "专注", "中景", "柔和自然光", "暖色调",
        ])
    }

    func testComposeTagsDeduplication() {
        let tags = AnalysisResult.composeTags(
            scene: "海滩",
            subjects: ["海滩", "女性"],
            actions: ["行走"],
            objects: ["女性"],
            mood: nil,
            shotType: nil,
            lighting: nil,
            colors: nil
        )
        // "海滩" 和 "女性" 各出现一次
        XCTAssertEqual(tags, ["海滩", "女性", "行走"])
    }

    func testComposeTagsEmptyFields() {
        let tags = AnalysisResult.composeTags(
            scene: nil,
            subjects: [],
            actions: [],
            objects: [],
            mood: nil,
            shotType: nil,
            lighting: nil,
            colors: nil
        )
        XCTAssertTrue(tags.isEmpty)
    }

    func testComposeTagsTrimsWhitespace() {
        let tags = AnalysisResult.composeTags(
            scene: "  海滩  ",
            subjects: ["  女性 "],
            actions: [],
            objects: [],
            mood: " ",
            shotType: nil,
            lighting: nil,
            colors: nil
        )
        XCTAssertEqual(tags, ["海滩", "女性"])
    }

    // MARK: - AnalysisResult 初始化

    func testAnalysisResultAutoComposeTags() {
        let result = AnalysisResult(
            scene: "户外公园",
            subjects: ["老人"],
            actions: ["散步"],
            objects: ["长椅"],
            mood: "宁静",
            shotType: "全景",
            lighting: "黄昏",
            colors: "暖色",
            description: nil
        )
        XCTAssertEqual(result.tags, [
            "户外公园", "老人", "散步", "长椅", "宁静", "全景", "黄昏", "暖色",
        ])
        XCTAssertNil(result.description)
    }

    // MARK: - Prompt

    func testFormatPromptNotEmpty() {
        let prompt = VisionAnalyzer.formatPrompt()
        XCTAssertFalse(prompt.isEmpty)
        XCTAssertTrue(prompt.contains("视频素材分析"))
        XCTAssertTrue(prompt.contains("JSON"))
    }

    // MARK: - Response Schema

    func testBuildResponseSchemaStructure() {
        let schema = VisionAnalyzer.buildResponseSchema()
        XCTAssertEqual(schema["type"] as? String, "object")

        let properties = schema["properties"] as? [String: Any]
        XCTAssertNotNil(properties)
        XCTAssertNotNil(properties?["scene"])
        XCTAssertNotNil(properties?["subjects"])
        XCTAssertNotNil(properties?["actions"])
        XCTAssertNotNil(properties?["objects"])
        XCTAssertNotNil(properties?["mood"])
        XCTAssertNotNil(properties?["shot_type"])
        XCTAssertNotNil(properties?["lighting"])
        XCTAssertNotNil(properties?["colors"])
        XCTAssertNotNil(properties?["description"])

        let required = schema["required"] as? [String]
        XCTAssertNotNil(required)
        XCTAssertEqual(required?.count, 9)
    }

    // MARK: - 图片编码

    func testEncodeImageToBase64FileNotFound() {
        XCTAssertThrowsError(
            try VisionAnalyzer.encodeImageToBase64(imagePath: "/nonexistent/image.jpg")
        ) { error in
            guard case VisionAnalyzerError.imageEncodingFailed = error else {
                XCTFail("应抛出 imageEncodingFailed，实际: \(error)")
                return
            }
        }
    }

    func testEncodeImageToBase64ValidFile() throws {
        let tmpDir = NSTemporaryDirectory()
        let imagePath = (tmpDir as NSString).appendingPathComponent("test_image.jpg")
        defer { try? FileManager.default.removeItem(atPath: imagePath) }

        // 写入一些测试数据
        let testData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        try testData.write(to: URL(fileURLWithPath: imagePath))

        let base64 = try VisionAnalyzer.encodeImageToBase64(imagePath: imagePath)
        XCTAssertFalse(base64.isEmpty)
        // 验证可以解码回来
        let decoded = Data(base64Encoded: base64)
        XCTAssertEqual(decoded, testData)
    }

    // MARK: - 请求构建

    func testBuildRequestBodyStructure() throws {
        let body = try VisionAnalyzer.buildRequestBody(
            imageBase64List: ["base64img1", "base64img2"]
        )
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertNotNil(json)

        // contents
        let contents = json?["contents"] as? [[String: Any]]
        XCTAssertEqual(contents?.count, 1)

        let parts = contents?.first?["parts"] as? [[String: Any]]
        // 2 images + 1 text = 3 parts
        XCTAssertEqual(parts?.count, 3)

        // 检查第一个 part 是图片
        let firstPart = parts?[0]
        let inlineData = firstPart?["inline_data"] as? [String: Any]
        XCTAssertEqual(inlineData?["mime_type"] as? String, "image/jpeg")
        XCTAssertEqual(inlineData?["data"] as? String, "base64img1")

        // 检查最后一个 part 是文本
        let lastPart = parts?.last
        XCTAssertNotNil(lastPart?["text"] as? String)

        // generationConfig
        let genConfig = json?["generationConfig"] as? [String: Any]
        XCTAssertEqual(genConfig?["response_mime_type"] as? String, "application/json")
        XCTAssertNotNil(genConfig?["response_schema"])
    }

    // MARK: - 响应解析

    func testParseResponseValidJSON() throws {
        let innerJSON = """
        {
            "scene": "户外海滩",
            "subjects": ["年轻女性", "冲浪板"],
            "actions": ["走路", "微笑"],
            "objects": ["遮阳伞", "沙滩椅"],
            "mood": "轻松愉快",
            "shot_type": "中景",
            "lighting": "自然日光",
            "colors": "蓝色、金色",
            "description": "一位年轻女性在阳光明媚的海滩上微笑着走过。"
        }
        """

        let response: [String: Any] = [
            "candidates": [[
                "content": [
                    "parts": [["text": innerJSON]],
                    "role": "model",
                ],
                "finishReason": "STOP",
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        let result = try VisionAnalyzer.parseResponse(data)

        XCTAssertEqual(result.scene, "户外海滩")
        XCTAssertEqual(result.subjects, ["年轻女性", "冲浪板"])
        XCTAssertEqual(result.actions, ["走路", "微笑"])
        XCTAssertEqual(result.objects, ["遮阳伞", "沙滩椅"])
        XCTAssertEqual(result.mood, "轻松愉快")
        XCTAssertEqual(result.shotType, "中景")
        XCTAssertEqual(result.lighting, "自然日光")
        XCTAssertEqual(result.colors, "蓝色、金色")
        XCTAssertEqual(result.description, "一位年轻女性在阳光明媚的海滩上微笑着走过。")
        XCTAssertFalse(result.tags.isEmpty)
        XCTAssertTrue(result.tags.contains("户外海滩"))
    }

    func testParseResponsePartialFields() throws {
        let innerJSON = """
        {
            "scene": "室内",
            "subjects": [],
            "actions": [],
            "objects": [],
            "mood": "安静",
            "shot_type": "全景",
            "lighting": "昏暗",
            "colors": "灰色",
            "description": "空旷的房间。"
        }
        """

        let response: [String: Any] = [
            "candidates": [[
                "content": [
                    "parts": [["text": innerJSON]],
                ],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        let result = try VisionAnalyzer.parseResponse(data)

        XCTAssertEqual(result.scene, "室内")
        XCTAssertTrue(result.subjects.isEmpty)
        XCTAssertEqual(result.mood, "安静")
        XCTAssertEqual(result.tags, ["室内", "安静", "全景", "昏暗", "灰色"])
    }

    func testParseResponseInvalidStructure() {
        let badData = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try VisionAnalyzer.parseResponse(badData)) { error in
            guard case VisionAnalyzerError.invalidResponse = error else {
                XCTFail("应抛出 invalidResponse，实际: \(error)")
                return
            }
        }
    }

    func testParseResponseNoCandidates() throws {
        let response: [String: Any] = ["candidates": []]
        let data = try JSONSerialization.data(withJSONObject: response)
        XCTAssertThrowsError(try VisionAnalyzer.parseResponse(data))
    }

    // MARK: - 错误响应解析

    func testParseErrorResponseValid() throws {
        let errorJSON: [String: Any] = [
            "error": [
                "code": 429,
                "message": "RESOURCE_EXHAUSTED: Quota exceeded",
                "status": "RESOURCE_EXHAUSTED",
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: errorJSON)
        let result = VisionAnalyzer.parseErrorResponse(data)
        XCTAssertEqual(result?.code, 429)
        XCTAssertTrue(result?.message.contains("RESOURCE_EXHAUSTED") ?? false)
    }

    func testParseErrorResponseInvalid() {
        let data = "not json".data(using: .utf8)!
        XCTAssertNil(VisionAnalyzer.parseErrorResponse(data))
    }

    // MARK: - HTTP 请求构建

    func testBuildURLRequestHeaders() throws {
        let body = "test".data(using: .utf8)!
        let request = try VisionAnalyzer.buildURLRequest(
            body: body,
            apiKey: "test-api-key",
            config: .default
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-api-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 60.0)
        XCTAssertTrue(request.url?.absoluteString.contains("gemini-2.5-flash") ?? false)
        XCTAssertTrue(request.url?.absoluteString.contains("generateContent") ?? false)
    }

    func testBuildURLRequestCustomModel() throws {
        let body = "test".data(using: .utf8)!
        let config = VisionAnalyzer.Config(model: "gemini-2.5-flash-lite")
        let request = try VisionAnalyzer.buildURLRequest(
            body: body,
            apiKey: "key",
            config: config
        )
        XCTAssertTrue(request.url?.absoluteString.contains("gemini-2.5-flash-lite") ?? false)
    }

    // MARK: - 重试判断

    func testShouldRetry() {
        XCTAssertTrue(VisionAnalyzer.shouldRetry(statusCode: 429))
        XCTAssertTrue(VisionAnalyzer.shouldRetry(statusCode: 503))
        XCTAssertTrue(VisionAnalyzer.shouldRetry(statusCode: 500))
        XCTAssertFalse(VisionAnalyzer.shouldRetry(statusCode: 400))
        XCTAssertFalse(VisionAnalyzer.shouldRetry(statusCode: 401))
        XCTAssertFalse(VisionAnalyzer.shouldRetry(statusCode: 200))
    }

    // MARK: - Config

    func testDefaultConfig() {
        let config = VisionAnalyzer.Config.default
        XCTAssertEqual(config.model, "gemini-2.5-flash")
        XCTAssertEqual(config.maxImagesPerRequest, 10)
        XCTAssertEqual(config.requestTimeoutSeconds, 60.0)
        XCTAssertEqual(config.maxRetries, 3)
    }

    func testCustomConfig() {
        let config = VisionAnalyzer.Config(
            model: "gemini-2.5-flash-lite",
            maxImagesPerRequest: 5,
            requestTimeoutSeconds: 30.0,
            maxRetries: 1
        )
        XCTAssertEqual(config.model, "gemini-2.5-flash-lite")
        XCTAssertEqual(config.maxImagesPerRequest, 5)
    }

    // MARK: - OpenRouter 请求构建

    func testBuildRequestBodyOpenRouterStructure() throws {
        let config = VisionAnalyzer.Config(
            model: "qwen/qwen-2.5-vl-72b",
            provider: .openRouter,
            baseURL: APIProvider.openRouter.defaultBaseURL
        )
        let body = try VisionAnalyzer.buildRequestBody(
            imageBase64List: ["base64img1"],
            config: config
        )
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertNotNil(json)

        // model 字段
        XCTAssertEqual(json?["model"] as? String, "qwen/qwen-2.5-vl-72b")

        // messages 结构
        let messages = json?["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 1)
        XCTAssertEqual(messages?.first?["role"] as? String, "user")

        let content = messages?.first?["content"] as? [[String: Any]]
        // 1 image + 1 text = 2 parts
        XCTAssertEqual(content?.count, 2)

        // 图片 part 是 image_url 格式
        let imgPart = content?.first
        XCTAssertEqual(imgPart?["type"] as? String, "image_url")

        // response_format 字段
        let responseFormat = json?["response_format"] as? [String: Any]
        XCTAssertEqual(responseFormat?["type"] as? String, "json_schema")
    }

    // MARK: - OpenRouter 响应解析

    func testParseResponseOpenRouter() throws {
        let innerJSON = """
        {
            "scene": "城市街景",
            "subjects": ["行人"],
            "actions": ["行走"],
            "objects": ["路灯"],
            "mood": "繁忙",
            "shot_type": "全景",
            "lighting": "夜间",
            "colors": "暖色调",
            "description": "城市夜晚的街景。"
        }
        """

        let response: [String: Any] = [
            "choices": [[
                "message": [
                    "role": "assistant",
                    "content": innerJSON,
                ],
                "finish_reason": "stop",
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        let result = try VisionAnalyzer.parseResponse(data, provider: .openRouter)

        XCTAssertEqual(result.scene, "城市街景")
        XCTAssertEqual(result.subjects, ["行人"])
        XCTAssertEqual(result.mood, "繁忙")
    }

    func testParseResponseOpenRouterInvalidStructure() {
        let badData = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try VisionAnalyzer.parseResponse(badData, provider: .openRouter))
    }

    func testParseResponseOpenRouterNoChoices() throws {
        let response: [String: Any] = ["choices": []]
        let data = try JSONSerialization.data(withJSONObject: response)
        XCTAssertThrowsError(try VisionAnalyzer.parseResponse(data, provider: .openRouter))
    }

    // MARK: - OpenRouter URL 构建

    func testBuildURLRequestOpenRouter() throws {
        let body = "test".data(using: .utf8)!
        let config = VisionAnalyzer.Config(
            model: "qwen/qwen-2.5-vl-72b",
            provider: .openRouter,
            baseURL: APIProvider.openRouter.defaultBaseURL
        )
        let request = try VisionAnalyzer.buildURLRequest(
            body: body,
            apiKey: "sk-or-test-key12345678",
            config: config
        )

        XCTAssertEqual(request.httpMethod, "POST")
        // auth: Bearer
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-test-key12345678")
        // URL 包含 /chat/completions
        XCTAssertTrue(request.url?.absoluteString.contains("chat/completions") ?? false)
        XCTAssertTrue(request.url?.absoluteString.contains("openrouter.ai") ?? false)
        // X-Title header
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), "FindIt")
        // 不应有 x-goog-api-key
        XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
    }

    // MARK: - Config provider 默认值

    func testConfigDefaultProvider() {
        let config = VisionAnalyzer.Config.default
        XCTAssertEqual(config.provider, .gemini)
        XCTAssertEqual(config.baseURL, APIProvider.gemini.defaultBaseURL)
    }

    // MARK: - 错误响应解析（OpenRouter 格式）

    func testParseErrorResponseOpenRouterStringCode() throws {
        let errorJSON: [String: Any] = [
            "error": [
                "code": "429",
                "message": "Rate limit exceeded",
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: errorJSON)
        let result = VisionAnalyzer.parseErrorResponse(data)
        XCTAssertEqual(result?.code, 429)
        XCTAssertTrue(result?.message.contains("Rate limit") ?? false)
    }
}
