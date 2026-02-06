import XCTest
import CoreImage
@testable import FindItCore

final class LocalVisionAnalyzerTests: XCTestCase {

    // MARK: - classifyShotType

    func testClassifyShotTypeExtremeCloseUp() {
        XCTAssertEqual(LocalVisionAnalyzer.classifyShotType(faceAreaRatio: 0.5), "extreme close-up")
        XCTAssertEqual(LocalVisionAnalyzer.classifyShotType(faceAreaRatio: 0.40), "extreme close-up")
    }

    func testClassifyShotTypeCloseUp() {
        XCTAssertEqual(LocalVisionAnalyzer.classifyShotType(faceAreaRatio: 0.2), "close-up")
        XCTAssertEqual(LocalVisionAnalyzer.classifyShotType(faceAreaRatio: 0.15), "close-up")
    }

    func testClassifyShotTypeMediumCloseUp() {
        XCTAssertEqual(LocalVisionAnalyzer.classifyShotType(faceAreaRatio: 0.08), "medium close-up")
        XCTAssertEqual(LocalVisionAnalyzer.classifyShotType(faceAreaRatio: 0.05), "medium close-up")
    }

    func testClassifyShotTypeMediumShot() {
        XCTAssertEqual(LocalVisionAnalyzer.classifyShotType(faceAreaRatio: 0.03), "medium shot")
        XCTAssertEqual(LocalVisionAnalyzer.classifyShotType(faceAreaRatio: 0.015), "medium shot")
    }

    func testClassifyShotTypeWideShot() {
        XCTAssertEqual(LocalVisionAnalyzer.classifyShotType(faceAreaRatio: 0.01), "wide shot")
        XCTAssertEqual(LocalVisionAnalyzer.classifyShotType(faceAreaRatio: 0.0), "wide shot")
    }

    // MARK: - classifyLighting

    func testClassifyLightingVeryDark() {
        XCTAssertEqual(LocalVisionAnalyzer.classifyLighting(luminance: 0.05), "very dark")
        XCTAssertEqual(LocalVisionAnalyzer.classifyLighting(luminance: 0.14), "very dark")
    }

    func testClassifyLightingDark() {
        XCTAssertEqual(LocalVisionAnalyzer.classifyLighting(luminance: 0.15), "dark")
        XCTAssertEqual(LocalVisionAnalyzer.classifyLighting(luminance: 0.25), "dark")
    }

    func testClassifyLightingNormal() {
        XCTAssertEqual(LocalVisionAnalyzer.classifyLighting(luminance: 0.3), "normal")
        XCTAssertEqual(LocalVisionAnalyzer.classifyLighting(luminance: 0.5), "normal")
    }

    func testClassifyLightingBright() {
        XCTAssertEqual(LocalVisionAnalyzer.classifyLighting(luminance: 0.7), "bright")
        XCTAssertEqual(LocalVisionAnalyzer.classifyLighting(luminance: 0.8), "bright")
    }

    func testClassifyLightingVeryBright() {
        XCTAssertEqual(LocalVisionAnalyzer.classifyLighting(luminance: 0.85), "very bright")
        XCTAssertEqual(LocalVisionAnalyzer.classifyLighting(luminance: 0.95), "very bright")
    }

    // MARK: - inferSubjects

    func testInferSubjectsNoPeople() {
        XCTAssertEqual(LocalVisionAnalyzer.inferSubjects(faceCount: 0, humanCount: 0), [])
    }

    func testInferSubjectsOnePerson() {
        XCTAssertEqual(LocalVisionAnalyzer.inferSubjects(faceCount: 1, humanCount: 0), ["person"])
        XCTAssertEqual(LocalVisionAnalyzer.inferSubjects(faceCount: 0, humanCount: 1), ["person"])
        XCTAssertEqual(LocalVisionAnalyzer.inferSubjects(faceCount: 1, humanCount: 1), ["person"])
    }

    func testInferSubjectsMultiplePeople() {
        XCTAssertEqual(LocalVisionAnalyzer.inferSubjects(faceCount: 3, humanCount: 2), ["3 people"])
        XCTAssertEqual(LocalVisionAnalyzer.inferSubjects(faceCount: 0, humanCount: 5), ["5 people"])
    }

    // MARK: - mostFrequent

    func testMostFrequentEmpty() {
        XCTAssertNil(LocalVisionAnalyzer.mostFrequent([]))
    }

    func testMostFrequentSingle() {
        XCTAssertEqual(LocalVisionAnalyzer.mostFrequent(["a"]), "a")
    }

    func testMostFrequentMultiple() {
        XCTAssertEqual(LocalVisionAnalyzer.mostFrequent(["a", "b", "a", "c", "a"]), "a")
        XCTAssertEqual(LocalVisionAnalyzer.mostFrequent(["x", "y", "y"]), "y")
    }

    // MARK: - formatLabel

    func testFormatLabel() {
        XCTAssertEqual(LocalVisionAnalyzer.formatLabel("sunset_sunrise"), "sunset sunrise")
        XCTAssertEqual(LocalVisionAnalyzer.formatLabel("beach"), "beach")
        XCTAssertEqual(LocalVisionAnalyzer.formatLabel("indoor_office"), "indoor office")
    }

    // MARK: - nearestColorName

    func testNearestColorNameRed() {
        XCTAssertEqual(LocalVisionAnalyzer.nearestColorName(r: 255, g: 0, b: 0), "red")
    }

    func testNearestColorNameGreen() {
        XCTAssertEqual(LocalVisionAnalyzer.nearestColorName(r: 0, g: 200, b: 0), "green")
    }

    func testNearestColorNameBlue() {
        XCTAssertEqual(LocalVisionAnalyzer.nearestColorName(r: 0, g: 0, b: 255), "blue")
    }

    func testNearestColorNameWhite() {
        XCTAssertEqual(LocalVisionAnalyzer.nearestColorName(r: 250, g: 250, b: 250), "white")
    }

    func testNearestColorNameBlack() {
        XCTAssertEqual(LocalVisionAnalyzer.nearestColorName(r: 10, g: 10, b: 10), "black")
    }

    func testNearestColorNameGray() {
        XCTAssertEqual(LocalVisionAnalyzer.nearestColorName(r: 128, g: 128, b: 128), "gray")
    }

    func testNearestColorNameOrange() {
        XCTAssertEqual(LocalVisionAnalyzer.nearestColorName(r: 255, g: 165, b: 0), "orange")
    }

    func testNearestColorNameYellow() {
        XCTAssertEqual(LocalVisionAnalyzer.nearestColorName(r: 255, g: 255, b: 0), "yellow")
    }

    // MARK: - mergeResults

    func testMergeResultsRemoteOverridesLocal() {
        let local = AnalysisResult(
            scene: "beach", subjects: ["person"], actions: [], objects: ["sand"],
            mood: nil, shotType: "wide shot", lighting: "bright", colors: "blue",
            description: nil
        )
        let remote = AnalysisResult(
            scene: "海滩日落", subjects: ["一名女性"], actions: ["行走"],
            objects: ["沙滩", "海浪"], mood: "宁静", shotType: nil,
            lighting: nil, colors: nil, description: "一位女性沿着海滩行走"
        )

        let merged = LocalVisionAnalyzer.mergeResults(local: local, remote: remote)
        XCTAssertEqual(merged.scene, "海滩日落", "Gemini 非空字段应覆盖本地")
        XCTAssertEqual(merged.subjects, ["一名女性"])
        XCTAssertEqual(merged.actions, ["行走"])
        XCTAssertEqual(merged.mood, "宁静")
        XCTAssertEqual(merged.shotType, "wide shot", "Gemini 为空应保留本地")
        XCTAssertEqual(merged.lighting, "bright", "Gemini 为空应保留本地")
        XCTAssertEqual(merged.colors, "blue", "Gemini 为空应保留本地")
        XCTAssertEqual(merged.description, "一位女性沿着海滩行走")
    }

    func testMergeResultsLocalOnlyWhenRemoteEmpty() {
        let local = AnalysisResult(
            scene: "indoor", subjects: ["2 people"], actions: [], objects: ["desk", "chair"],
            mood: nil, shotType: "medium shot", lighting: "normal", colors: "gray white",
            description: nil
        )
        let remote = AnalysisResult(
            scene: nil, subjects: [], actions: [], objects: [],
            mood: nil, shotType: nil, lighting: nil, colors: nil, description: nil
        )

        let merged = LocalVisionAnalyzer.mergeResults(local: local, remote: remote)
        XCTAssertEqual(merged.scene, "indoor")
        XCTAssertEqual(merged.subjects, ["2 people"])
        XCTAssertEqual(merged.objects, ["desk", "chair"])
        XCTAssertEqual(merged.shotType, "medium shot")
    }

    // MARK: - Integration: analyze with generated image

    func testAnalyzeWithBlueImage() throws {
        let imagePath = makeTempImagePath("test_blue.jpg")
        try createTestImage(path: imagePath, width: 512, height: 512,
                            red: 0.2, green: 0.4, blue: 0.9)
        defer { try? FileManager.default.removeItem(atPath: imagePath) }

        let result = try LocalVisionAnalyzer.analyze(imagePath: imagePath)

        // 基本结果验证
        XCTAssertNotNil(result.lighting, "应检测到光线")
        XCTAssertNotNil(result.colors, "应检测到颜色")
        XCTAssertNil(result.description, "description 需 Gemini 填充")
        XCTAssertNil(result.mood, "mood 需 Gemini 填充")
        XCTAssertTrue(result.actions.isEmpty, "actions 需 Gemini 填充")
        // 纯色图像不应检测到人
        XCTAssertTrue(result.subjects.isEmpty, "纯色图像不含人物")
    }

    func testAnalyzeWithDarkImage() throws {
        let imagePath = makeTempImagePath("test_dark.jpg")
        try createTestImage(path: imagePath, width: 256, height: 256,
                            red: 0.05, green: 0.05, blue: 0.05)
        defer { try? FileManager.default.removeItem(atPath: imagePath) }

        let result = try LocalVisionAnalyzer.analyze(imagePath: imagePath)

        XCTAssertNotNil(result.lighting)
        let dark = result.lighting == "very dark" || result.lighting == "dark"
        XCTAssertTrue(dark, "暗色图像应检测为 dark/very dark, got: \(result.lighting ?? "nil")")
    }

    func testAnalyzeWithBrightImage() throws {
        let imagePath = makeTempImagePath("test_bright.jpg")
        try createTestImage(path: imagePath, width: 256, height: 256,
                            red: 0.95, green: 0.95, blue: 0.9)
        defer { try? FileManager.default.removeItem(atPath: imagePath) }

        let result = try LocalVisionAnalyzer.analyze(imagePath: imagePath)

        XCTAssertNotNil(result.lighting)
        let bright = result.lighting == "bright" || result.lighting == "very bright"
        XCTAssertTrue(bright, "亮色图像应检测为 bright/very bright, got: \(result.lighting ?? "nil")")
    }

    func testAnalyzeClipEmpty() throws {
        let result = try LocalVisionAnalyzer.analyzeClip(imagePaths: [])
        XCTAssertNil(result.scene)
        XCTAssertTrue(result.subjects.isEmpty)
        XCTAssertTrue(result.objects.isEmpty)
    }

    func testAnalyzeClipMultipleFrames() throws {
        let path1 = makeTempImagePath("test_clip1.jpg")
        let path2 = makeTempImagePath("test_clip2.jpg")
        try createTestImage(path: path1, width: 256, height: 256, red: 0.9, green: 0.1, blue: 0.1)
        try createTestImage(path: path2, width: 256, height: 256, red: 0.1, green: 0.1, blue: 0.9)
        defer {
            try? FileManager.default.removeItem(atPath: path1)
            try? FileManager.default.removeItem(atPath: path2)
        }

        let result = try LocalVisionAnalyzer.analyzeClip(imagePaths: [path1, path2])
        // 应该得到合并结果
        XCTAssertNotNil(result.lighting)
        XCTAssertNotNil(result.colors)
    }

    func testAnalyzeInvalidPath() {
        XCTAssertThrowsError(try LocalVisionAnalyzer.analyze(imagePath: "/nonexistent/image.jpg")) { error in
            XCTAssertTrue(error is LocalVisionAnalyzer.AnalysisError)
        }
    }

    // MARK: - Helper

    private func makeTempImagePath(_ name: String) -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
    }

    private func createTestImage(
        path: String,
        width: Int,
        height: Int,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat
    ) throws {
        let ciImage = CIImage(color: CIColor(red: red, green: green, blue: blue))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))

        let context = CIContext()
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        try context.writeJPEGRepresentation(
            of: ciImage,
            to: URL(fileURLWithPath: path),
            colorSpace: colorSpace
        )
    }
}
