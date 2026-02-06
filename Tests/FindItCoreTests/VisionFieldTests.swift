import XCTest
@testable import FindItCore

final class VisionFieldTests: XCTestCase {

    // MARK: - 基础属性

    func testAllCasesCount() {
        XCTAssertEqual(VisionField.allCases.count, 9)
    }

    func testColumnNames() {
        XCTAssertEqual(VisionField.scene.columnName, "scene")
        XCTAssertEqual(VisionField.shotType.columnName, "shot_type")
        XCTAssertEqual(VisionField.description.columnName, "description")
    }

    func testIsArray() {
        XCTAssertTrue(VisionField.subjects.isArray)
        XCTAssertTrue(VisionField.actions.isArray)
        XCTAssertTrue(VisionField.objects.isArray)
        XCTAssertFalse(VisionField.scene.isArray)
        XCTAssertFalse(VisionField.mood.isArray)
        XCTAssertFalse(VisionField.description.isArray)
    }

    func testIncludeInTags() {
        XCTAssertTrue(VisionField.scene.includeInTags)
        XCTAssertTrue(VisionField.subjects.includeInTags)
        XCTAssertTrue(VisionField.colors.includeInTags)
        XCTAssertFalse(VisionField.description.includeInTags, "description 不应参与 tags 合成")
    }

    func testEmbeddingGroupOrdering() {
        XCTAssertTrue(VisionField.EmbeddingGroup.primary < .detail)
        XCTAssertTrue(VisionField.EmbeddingGroup.detail < .meta)
    }

    func testEmbeddingGroupAssignment() {
        XCTAssertEqual(VisionField.scene.embeddingGroup, .primary)
        XCTAssertEqual(VisionField.description.embeddingGroup, .primary)
        XCTAssertEqual(VisionField.subjects.embeddingGroup, .detail)
        XCTAssertEqual(VisionField.actions.embeddingGroup, .detail)
        XCTAssertEqual(VisionField.objects.embeddingGroup, .detail)
        XCTAssertEqual(VisionField.mood.embeddingGroup, .meta)
        XCTAssertEqual(VisionField.shotType.embeddingGroup, .meta)
        XCTAssertEqual(VisionField.lighting.embeddingGroup, .meta)
        XCTAssertEqual(VisionField.colors.embeddingGroup, .meta)
    }

    // MARK: - 静态工具方法

    func testBuildResponseSchemaFieldCount() {
        let schema = VisionField.buildResponseSchema()
        guard let properties = schema["properties"] as? [String: Any] else {
            XCTFail("schema 应包含 properties")
            return
        }
        XCTAssertEqual(properties.count, 9)

        guard let required = schema["required"] as? [String] else {
            XCTFail("schema 应包含 required")
            return
        }
        XCTAssertEqual(required.count, 9)
        XCTAssertTrue(required.contains("shot_type"))
        XCTAssertTrue(required.contains("description"))
    }

    func testBuildResponseSchemaSubset() {
        let schema = VisionField.buildResponseSchema(fields: [.scene, .description])
        guard let properties = schema["properties"] as? [String: Any] else {
            XCTFail("schema 应包含 properties")
            return
        }
        XCTAssertEqual(properties.count, 2)
    }

    func testBuildVLMPromptContainsAllFields() {
        let prompt = VisionField.buildVLMPrompt()
        for field in VisionField.allCases {
            XCTAssertTrue(
                prompt.contains("- \(field.columnName):"),
                "VLM prompt 应包含 \(field.columnName)"
            )
        }
        XCTAssertTrue(prompt.contains("Return ONLY valid JSON"))
    }

    func testSqlSetClause() {
        let clause = VisionField.sqlSetClause()
        XCTAssertTrue(clause.contains("scene = ?"))
        XCTAssertTrue(clause.contains("shot_type = ?"))
        XCTAssertTrue(clause.contains("description = ?"))
        // 验证是逗号分隔
        let parts = clause.components(separatedBy: ", ")
        XCTAssertEqual(parts.count, 9)
    }

    func testSqlColumnNames() {
        let names = VisionField.sqlColumnNames()
        XCTAssertEqual(names.count, 9)
        XCTAssertEqual(names[0], "scene")
        XCTAssertTrue(names.contains("shot_type"))
        XCTAssertEqual(names.last, "description")
    }

    // MARK: - AnalysisResult + VisionField

    func testStringValueForField() {
        let result = AnalysisResult(
            scene: "indoor",
            subjects: ["man", "woman"],
            actions: ["talking"],
            objects: [],
            mood: "calm",
            shotType: "medium shot",
            lighting: "natural",
            colors: "warm tones",
            description: "A couple talking indoors"
        )

        XCTAssertEqual(result.stringValue(for: .scene), "indoor")
        XCTAssertEqual(result.stringValue(for: .subjects), "man, woman")
        XCTAssertEqual(result.stringValue(for: .actions), "talking")
        XCTAssertNil(result.stringValue(for: .objects), "空数组应返回 nil")
        XCTAssertEqual(result.stringValue(for: .description), "A couple talking indoors")
    }

    func testArrayValueForField() {
        let result = AnalysisResult(
            scene: "outdoor",
            subjects: ["child"],
            actions: [],
            objects: ["ball"],
            mood: nil,
            shotType: nil,
            lighting: nil,
            colors: nil,
            description: nil
        )

        XCTAssertEqual(result.arrayValue(for: .scene), ["outdoor"])
        XCTAssertEqual(result.arrayValue(for: .subjects), ["child"])
        XCTAssertTrue(result.arrayValue(for: .actions).isEmpty)
        XCTAssertEqual(result.arrayValue(for: .objects), ["ball"])
        XCTAssertTrue(result.arrayValue(for: .mood).isEmpty, "nil 应返回空数组")
    }

    func testComposeTagsFromResult() {
        let result = AnalysisResult(
            scene: "beach",
            subjects: ["woman"],
            actions: ["walking"],
            objects: ["umbrella"],
            mood: "calm",
            shotType: "wide shot",
            lighting: "golden hour",
            colors: "warm tones",
            description: "A woman walking on a beach"
        )

        // 旧 API
        let oldTags = result.tags

        // 新 API
        let newTags = AnalysisResult.composeTags(from: result)

        // 两者应一致
        XCTAssertEqual(oldTags, newTags, "新旧 composeTags API 结果应一致")
    }

    func testComposeTagsExcludesDescription() {
        let result = AnalysisResult(
            scene: nil,
            subjects: [],
            actions: [],
            objects: [],
            mood: nil,
            shotType: nil,
            lighting: nil,
            colors: nil,
            description: "This should not appear in tags"
        )

        let tags = AnalysisResult.composeTags(from: result)
        XCTAssertTrue(tags.isEmpty, "description 不应参与 tags 合成")
    }

    // MARK: - Clip + VisionField

    func testClipVisionValue() {
        let clip = Clip(
            startTime: 0, endTime: 10,
            scene: "indoor",
            subjects: "[\"man\"]",
            actions: nil,
            objects: nil,
            mood: "tense",
            shotType: "close-up",
            lighting: "dark",
            colors: "blue",
            clipDescription: "A tense scene"
        )

        XCTAssertEqual(clip.visionValue(for: .scene), "indoor")
        XCTAssertEqual(clip.visionValue(for: .subjects), "[\"man\"]")
        XCTAssertNil(clip.visionValue(for: .actions))
        XCTAssertEqual(clip.visionValue(for: .description), "A tense scene")
        XCTAssertEqual(clip.visionValue(for: .shotType), "close-up")
    }

    // MARK: - displayLabel

    func testDisplayLabels() {
        XCTAssertEqual(VisionField.scene.displayLabel, "场景")
        XCTAssertEqual(VisionField.subjects.displayLabel, "主体")
        XCTAssertEqual(VisionField.description.displayLabel, "描述")
    }
}
