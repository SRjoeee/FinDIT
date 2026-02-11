import XCTest
import MCP
@testable import FindItMCPServer

final class ToolRegistryTests: XCTestCase {

    private lazy var tools = ToolRegistry.buildToolDefinitions()

    // MARK: - Tool 数量和名称

    func testToolCount() {
        XCTAssertEqual(tools.count, 7, "应暴露 7 个只读 tools")
    }

    func testAllToolNamesPresent() {
        let names = Set(tools.map(\.name))
        let expected: Set<String> = [
            "search", "browse_all_clips",
            "list_folders", "list_videos",
            "get_clip", "get_video_detail", "get_stats",
        ]
        XCTAssertEqual(names, expected)
    }

    // MARK: - Schema 验证

    func testSearchToolHasRequiredQuery() {
        guard let search = tools.first(where: { $0.name == "search" }) else {
            return XCTFail("search tool not found")
        }

        // inputSchema 应声明 query 为 required
        if case .object(let schema) = search.inputSchema {
            if case .array(let required) = schema["required"] {
                let requiredNames = required.compactMap { val -> String? in
                    if case .string(let s) = val { return s }
                    return nil
                }
                XCTAssertTrue(requiredNames.contains("query"), "search 应要求 query 参数")
            } else {
                XCTFail("search schema 缺少 required 数组")
            }
        } else {
            XCTFail("search inputSchema 不是 object")
        }
    }

    func testSearchToolHasOffsetParam() {
        guard let search = tools.first(where: { $0.name == "search" }) else {
            return XCTFail("search tool not found")
        }

        if case .object(let schema) = search.inputSchema,
           case .object(let props) = schema["properties"] {
            XCTAssertNotNil(props["offset"], "search 应有 offset 参数")
        } else {
            XCTFail("search schema 结构不正确")
        }
    }

    func testSearchToolHasFolderParam() {
        guard let search = tools.first(where: { $0.name == "search" }) else {
            return XCTFail("search tool not found")
        }

        if case .object(let schema) = search.inputSchema,
           case .object(let props) = schema["properties"] {
            XCTAssertNotNil(props["folder"], "search 应有 folder 参数")
        } else {
            XCTFail("search schema 结构不正确")
        }
    }

    func testListVideosRequiresFolder() {
        guard let tool = tools.first(where: { $0.name == "list_videos" }) else {
            return XCTFail("list_videos tool not found")
        }

        if case .object(let schema) = tool.inputSchema,
           case .array(let required) = schema["required"] {
            let names = required.compactMap { val -> String? in
                if case .string(let s) = val { return s }
                return nil
            }
            XCTAssertTrue(names.contains("folder"), "list_videos 应要求 folder 参数")
        } else {
            XCTFail("list_videos schema 结构不正确")
        }
    }

    func testBrowseAllClipsToolSchema() {
        guard let tool = tools.first(where: { $0.name == "browse_all_clips" }) else {
            return XCTFail("browse_all_clips tool not found")
        }

        if case .object(let schema) = tool.inputSchema,
           case .object(let props) = schema["properties"] {
            XCTAssertNotNil(props["folder"], "browse_all_clips 应有 folder 参数")
            XCTAssertNotNil(props["offset"], "browse_all_clips 应有 offset 参数")
            XCTAssertNotNil(props["limit"], "browse_all_clips 应有 limit 参数")
            XCTAssertNotNil(props["sort_by"], "browse_all_clips 应有 sort_by 参数")
        } else {
            XCTFail("browse_all_clips schema 结构不正确")
        }

        // browse_all_clips 没有 required 字段（全部可选）
        if case .object(let schema) = tool.inputSchema {
            XCTAssertNil(schema["required"], "browse_all_clips 不应有 required 字段")
        }
    }

    func testAllToolsHaveDescriptions() {
        for tool in tools {
            XCTAssertNotNil(tool.description, "\(tool.name) 应有描述")
            XCTAssertFalse(tool.description?.isEmpty ?? true, "\(tool.name) 描述不应为空")
        }
    }

    func testSearchToolHasModeEnum() {
        guard let search = tools.first(where: { $0.name == "search" }) else {
            return XCTFail("search tool not found")
        }

        if case .object(let schema) = search.inputSchema,
           case .object(let props) = schema["properties"],
           case .object(let modeProp) = props["mode"],
           case .array(let enumVals) = modeProp["enum"] {
            let modes = enumVals.compactMap { val -> String? in
                if case .string(let s) = val { return s }
                return nil
            }
            XCTAssertEqual(Set(modes), Set(["fts", "vector", "hybrid", "auto"]))
        } else {
            XCTFail("search mode 属性缺少 enum")
        }
    }
}
