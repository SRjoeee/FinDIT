import XCTest
@testable import FindItCore

/// LocalVLMAnalyzer 纯函数测试
///
/// 测试 JSON 解析、模型检查等不需要加载模型的功能。
/// 实际推理测试需要下载 ~3 GB 模型，在 E2E 测试中覆盖。
final class LocalVLMAnalyzerTests: XCTestCase {

    // MARK: - parseResponse

    func testParseResponseValidJSON() {
        // 注意: AnalysisResult CodingKeys 使用 snake_case (shot_type)
        let json = """
        {
            "scene": "outdoor",
            "description": "A sunny beach scene",
            "subjects": ["man", "woman"],
            "actions": ["walking", "talking"],
            "objects": ["umbrella", "surfboard"],
            "mood": "cheerful",
            "shot_type": "wide shot",
            "lighting": "natural",
            "colors": "warm tones"
        }
        """
        let result = LocalVLMAnalyzer.parseResponse(json)
        XCTAssertEqual(result.scene, "outdoor")
        XCTAssertEqual(result.description, "A sunny beach scene")
        XCTAssertEqual(result.subjects, ["man", "woman"])
        XCTAssertEqual(result.actions, ["walking", "talking"])
        XCTAssertEqual(result.objects, ["umbrella", "surfboard"])
        XCTAssertEqual(result.mood, "cheerful")
        XCTAssertEqual(result.shotType, "wide shot")
        XCTAssertEqual(result.lighting, "natural")
        XCTAssertEqual(result.colors, "warm tones")
    }

    func testParseResponseWithMarkdownCodeBlock() {
        let json = """
        ```json
        {
            "scene": "indoor",
            "description": "An office meeting",
            "subjects": ["person"],
            "actions": ["sitting"],
            "objects": ["laptop"],
            "mood": "focused",
            "shot_type": "medium shot",
            "lighting": "bright",
            "colors": "neutral"
        }
        ```
        """
        let result = LocalVLMAnalyzer.parseResponse(json)
        XCTAssertEqual(result.scene, "indoor")
        XCTAssertEqual(result.mood, "focused")
    }

    func testParseResponsePartialFields() {
        let json = """
        {
            "scene": "city",
            "description": "A bustling street",
            "mood": "energetic"
        }
        """
        let result = LocalVLMAnalyzer.parseResponse(json)
        XCTAssertEqual(result.scene, "city")
        XCTAssertEqual(result.description, "A bustling street")
        XCTAssertEqual(result.mood, "energetic")
        // 缺失字段应为默认值
        XCTAssertTrue(result.subjects.isEmpty)
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertTrue(result.objects.isEmpty)
    }

    func testParseResponseInvalidJSON() {
        let result = LocalVLMAnalyzer.parseResponse("not valid json at all")
        XCTAssertNil(result.scene)
        XCTAssertNil(result.description)
    }

    func testParseResponseEmpty() {
        let result = LocalVLMAnalyzer.parseResponse("")
        XCTAssertNil(result.scene)
    }

    func testParseResponseWithSurroundingText() {
        let json = """
        Here is the analysis:
        {"scene": "forest", "description": "Dense forest", "subjects": [], "actions": [], "objects": ["trees"], "mood": "peaceful", "shot_type": "wide shot", "lighting": "natural", "colors": "green"}
        That's my analysis.
        """
        let result = LocalVLMAnalyzer.parseResponse(json)
        XCTAssertEqual(result.scene, "forest")
        XCTAssertEqual(result.objects, ["trees"])
    }

    // MARK: - emptyResult

    func testEmptyResult() {
        let result = LocalVLMAnalyzer.emptyResult()
        XCTAssertNil(result.scene)
        XCTAssertNil(result.description)
        XCTAssertNil(result.mood)
        XCTAssertNil(result.shotType)
        XCTAssertNil(result.lighting)
        XCTAssertNil(result.colors)
        XCTAssertTrue(result.subjects.isEmpty)
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertTrue(result.objects.isEmpty)
    }

    // MARK: - isModelDownloaded

    func testIsModelDownloadedReturnsBool() {
        // 只验证不崩溃，返回值取决于是否真的下载了模型
        let _ = LocalVLMAnalyzer.isModelDownloaded()
    }

    // MARK: - defaultModelId

    func testDefaultModelId() {
        XCTAssertEqual(
            LocalVLMAnalyzer.defaultModelId,
            "mlx-community/Qwen2.5-VL-3B-Instruct-4bit"
        )
    }

    // MARK: - analysisPrompt

    func testAnalysisPromptContainsRequiredFields() {
        let prompt = LocalVLMAnalyzer.analysisPrompt
        XCTAssertTrue(prompt.contains("scene"))
        XCTAssertTrue(prompt.contains("description"))
        XCTAssertTrue(prompt.contains("subjects"))
        XCTAssertTrue(prompt.contains("actions"))
        XCTAssertTrue(prompt.contains("objects"))
        XCTAssertTrue(prompt.contains("mood"))
        XCTAssertTrue(prompt.contains("shot_type"))
        XCTAssertTrue(prompt.contains("lighting"))
        XCTAssertTrue(prompt.contains("colors"))
        XCTAssertTrue(prompt.contains("JSON"))
    }

    // MARK: - Chinese output

    func testParseResponseChineseContent() {
        let json = """
        {
            "scene": "室内",
            "description": "一个温馨的家庭聚会场景",
            "subjects": ["男人", "女人", "孩子"],
            "actions": ["交谈", "吃饭"],
            "objects": ["餐桌", "椅子"],
            "mood": "温暖",
            "shot_type": "中景",
            "lighting": "暖色灯光",
            "colors": "暖色调"
        }
        """
        let result = LocalVLMAnalyzer.parseResponse(json)
        XCTAssertEqual(result.scene, "室内")
        XCTAssertEqual(result.subjects, ["男人", "女人", "孩子"])
        XCTAssertEqual(result.mood, "温暖")
    }
}
