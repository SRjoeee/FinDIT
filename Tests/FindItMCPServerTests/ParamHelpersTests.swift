import XCTest
import MCP
@testable import FindItMCPServer

final class ParamHelpersTests: XCTestCase {

    // MARK: - requireString

    func testRequireStringSuccess() throws {
        let params = CallTool.Parameters(name: "test", arguments: [
            "query": .string("海滩日落"),
        ])
        let result = try ParamHelpers.requireString(params, key: "query")
        XCTAssertEqual(result, "海滩日落")
    }

    func testRequireStringMissingKey() {
        let params = CallTool.Parameters(name: "test", arguments: [:])
        XCTAssertThrowsError(try ParamHelpers.requireString(params, key: "query")) { error in
            XCTAssertTrue("\(error)".contains("Missing required parameter"))
        }
    }

    func testRequireStringNilArguments() {
        let params = CallTool.Parameters(name: "test", arguments: nil)
        XCTAssertThrowsError(try ParamHelpers.requireString(params, key: "query"))
    }

    func testRequireStringWrongType() {
        let params = CallTool.Parameters(name: "test", arguments: [
            "query": .int(42),
        ])
        XCTAssertThrowsError(try ParamHelpers.requireString(params, key: "query"))
    }

    // MARK: - optionalString

    func testOptionalStringPresent() {
        let params = CallTool.Parameters(name: "test", arguments: [
            "mode": .string("fts"),
        ])
        XCTAssertEqual(ParamHelpers.optionalString(params, key: "mode"), "fts")
    }

    func testOptionalStringMissing() {
        let params = CallTool.Parameters(name: "test", arguments: [:])
        XCTAssertNil(ParamHelpers.optionalString(params, key: "mode"))
    }

    func testOptionalStringNilArguments() {
        let params = CallTool.Parameters(name: "test", arguments: nil)
        XCTAssertNil(ParamHelpers.optionalString(params, key: "mode"))
    }

    // MARK: - requireInt

    func testRequireIntSuccess() throws {
        let params = CallTool.Parameters(name: "test", arguments: [
            "clip_id": .int(42),
        ])
        let result = try ParamHelpers.requireInt(params, key: "clip_id")
        XCTAssertEqual(result, 42)
    }

    func testRequireIntFromDouble() throws {
        let params = CallTool.Parameters(name: "test", arguments: [
            "clip_id": .double(5.0),
        ])
        let result = try ParamHelpers.requireInt(params, key: "clip_id")
        XCTAssertEqual(result, 5)
    }

    func testRequireIntMissing() {
        let params = CallTool.Parameters(name: "test", arguments: [:])
        XCTAssertThrowsError(try ParamHelpers.requireInt(params, key: "clip_id"))
    }

    func testRequireIntNilArguments() {
        let params = CallTool.Parameters(name: "test", arguments: nil)
        XCTAssertThrowsError(try ParamHelpers.requireInt(params, key: "clip_id"))
    }

    // MARK: - optionalInt

    func testOptionalIntPresent() {
        let params = CallTool.Parameters(name: "test", arguments: [
            "limit": .int(10),
        ])
        XCTAssertEqual(ParamHelpers.optionalInt(params, key: "limit"), 10)
    }

    func testOptionalIntMissing() {
        let params = CallTool.Parameters(name: "test", arguments: [:])
        XCTAssertNil(ParamHelpers.optionalInt(params, key: "limit"))
    }

    func testOptionalIntNilArguments() {
        let params = CallTool.Parameters(name: "test", arguments: nil)
        XCTAssertNil(ParamHelpers.optionalInt(params, key: "limit"))
    }

    // MARK: - optionalStringArray

    func testOptionalStringArrayPresent() {
        let params = CallTool.Parameters(name: "test", arguments: [
            "tags": .array([.string("海滩"), .string("日落")]),
        ])
        let result = ParamHelpers.optionalStringArray(params, key: "tags")
        XCTAssertEqual(result, ["海滩", "日落"])
    }

    func testOptionalStringArrayMissing() {
        let params = CallTool.Parameters(name: "test", arguments: [:])
        XCTAssertNil(ParamHelpers.optionalStringArray(params, key: "tags"))
    }

    func testOptionalStringArrayFiltersNonStrings() {
        let params = CallTool.Parameters(name: "test", arguments: [
            "tags": .array([.string("ok"), .int(42), .string("good")]),
        ])
        let result = ParamHelpers.optionalStringArray(params, key: "tags")
        XCTAssertEqual(result, ["ok", "good"])
    }

    // MARK: - requireStringArray

    func testRequireStringArraySuccess() throws {
        let params = CallTool.Parameters(name: "test", arguments: [
            "tags": .array([.string("精选"), .string("B-roll")]),
        ])
        let result = try ParamHelpers.requireStringArray(params, key: "tags")
        XCTAssertEqual(result, ["精选", "B-roll"])
    }

    func testRequireStringArrayMissing() {
        let params = CallTool.Parameters(name: "test", arguments: [:])
        XCTAssertThrowsError(try ParamHelpers.requireStringArray(params, key: "tags"))
    }

    func testRequireStringArrayNotArray() {
        let params = CallTool.Parameters(name: "test", arguments: [
            "tags": .string("not_array"),
        ])
        XCTAssertThrowsError(try ParamHelpers.requireStringArray(params, key: "tags"))
    }

    // MARK: - toJSON

    func testToJSON() throws {
        struct Sample: Codable {
            let name: String
            let count: Int
        }
        let json = try ParamHelpers.toJSON(Sample(name: "test", count: 42))
        XCTAssertTrue(json.contains("\"name\""))
        XCTAssertTrue(json.contains("\"test\""))
        XCTAssertTrue(json.contains("\"count\""))
        XCTAssertTrue(json.contains("42"))
    }

    func testToJSONArray() throws {
        let json = try ParamHelpers.toJSON([1, 2, 3])
        XCTAssertTrue(json.contains("1"))
        XCTAssertTrue(json.contains("3"))
    }

    // MARK: - TagParsingHelpers

    func testParseTagsSpaceSeparated() {
        let result = TagParsingHelpers.parseTagsFromGlobalDB("海滩 日落 户外")
        XCTAssertEqual(result, ["海滩", "日落", "户外"])
    }

    func testParseTagsJSONArray() {
        let result = TagParsingHelpers.parseTagsFromGlobalDB("[\"海滩\",\"日落\",\"户外\"]")
        XCTAssertEqual(result, ["海滩", "日落", "户外"])
    }

    func testParseTagsNil() {
        let result = TagParsingHelpers.parseTagsFromGlobalDB(nil)
        XCTAssertEqual(result, [])
    }

    func testParseTagsEmpty() {
        let result = TagParsingHelpers.parseTagsFromGlobalDB("")
        XCTAssertEqual(result, [])
    }

    func testParseTagsSingleWord() {
        let result = TagParsingHelpers.parseTagsFromGlobalDB("海滩")
        XCTAssertEqual(result, ["海滩"])
    }
}
