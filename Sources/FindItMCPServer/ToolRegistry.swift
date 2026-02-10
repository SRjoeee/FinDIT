import Foundation
import MCP
import GRDB
import FindItCore

/// MCP Tool 注册中心
///
/// 集中定义所有 tool 的 schema 并注册 handler。
enum ToolRegistry {

    /// 注册所有 tools 到 MCP Server
    static func register(on server: Server, context: DatabaseContext) async {
        let allTools = buildToolDefinitions()

        let _ = await server
            .withMethodHandler(ListTools.self) { _ in
                ListTools.Result(tools: allTools)
            }
            .withMethodHandler(CallTool.self) { params in
                try await handleToolCall(params: params, context: context)
            }
    }

    // MARK: - Tool 定义

    private static func buildToolDefinitions() -> [Tool] {
        [
            Tool(
                name: "search",
                description: "搜索视频片段（支持混合 FTS5 + 向量语义搜索）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("搜索关键词或自然语言描述"),
                        ]),
                        "mode": .object([
                            "type": .string("string"),
                            "enum": .array([.string("fts"), .string("vector"), .string("hybrid"), .string("auto")]),
                            "description": .string("搜索模式 (默认: auto)"),
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("最大结果数 (默认: 20)"),
                        ]),
                        "min_rating": .object([
                            "type": .string("integer"),
                            "description": .string("最低评分过滤 (1-5)"),
                        ]),
                        "color_labels": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("颜色标签过滤: red, orange, yellow, green, blue, purple, gray"),
                        ]),
                        "shot_types": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("镜头类型过滤"),
                        ]),
                        "moods": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("氛围过滤"),
                        ]),
                        "sort_by": .object([
                            "type": .string("string"),
                            "enum": .array([.string("relevance"), .string("date"), .string("duration"), .string("rating")]),
                            "description": .string("排序方式 (默认: relevance)"),
                        ]),
                    ]),
                    "required": .array([.string("query")]),
                ])
            ),
            Tool(
                name: "list_folders",
                description: "列出所有已索引的素材文件夹及其统计信息",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ])
            ),
            Tool(
                name: "list_videos",
                description: "列出指定文件夹中的所有视频及其索引状态",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "folder": .object([
                            "type": .string("string"),
                            "description": .string("素材文件夹路径"),
                        ]),
                        "status": .object([
                            "type": .string("string"),
                            "description": .string("按索引状态过滤: pending, completed, failed, orphaned"),
                        ]),
                    ]),
                    "required": .array([.string("folder")]),
                ])
            ),
            Tool(
                name: "get_clip",
                description: "获取单个视频片段的完整元数据（包括视觉分析、转录文本、标签等）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "clip_id": .object([
                            "type": .string("integer"),
                            "description": .string("片段 ID"),
                        ]),
                        "folder": .object([
                            "type": .string("string"),
                            "description": .string("素材文件夹路径"),
                        ]),
                    ]),
                    "required": .array([.string("clip_id"), .string("folder")]),
                ])
            ),
            Tool(
                name: "get_video_detail",
                description: "获取视频的完整信息及其所有片段列表",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "video_path": .object([
                            "type": .string("string"),
                            "description": .string("视频文件路径"),
                        ]),
                        "folder": .object([
                            "type": .string("string"),
                            "description": .string("素材文件夹路径 (可选，自动检测)"),
                        ]),
                    ]),
                    "required": .array([.string("video_path")]),
                ])
            ),
            Tool(
                name: "get_stats",
                description: "获取数据库综合统计信息（视频数、片段数、索引覆盖率等）",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ])
            ),
            Tool(
                name: "add_tags",
                description: "给视频片段添加用户标签",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "clip_id": .object([
                            "type": .string("integer"),
                            "description": .string("片段 ID"),
                        ]),
                        "folder": .object([
                            "type": .string("string"),
                            "description": .string("素材文件夹路径"),
                        ]),
                        "tags": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("要添加的标签列表"),
                        ]),
                    ]),
                    "required": .array([.string("clip_id"), .string("folder"), .string("tags")]),
                ])
            ),
            Tool(
                name: "remove_tags",
                description: "移除视频片段的指定用户标签",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "clip_id": .object([
                            "type": .string("integer"),
                            "description": .string("片段 ID"),
                        ]),
                        "folder": .object([
                            "type": .string("string"),
                            "description": .string("素材文件夹路径"),
                        ]),
                        "tags": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("要移除的标签列表"),
                        ]),
                    ]),
                    "required": .array([.string("clip_id"), .string("folder"), .string("tags")]),
                ])
            ),
            Tool(
                name: "set_rating",
                description: "设置视频片段的星级评分",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "clip_id": .object([
                            "type": .string("integer"),
                            "description": .string("片段 ID"),
                        ]),
                        "folder": .object([
                            "type": .string("string"),
                            "description": .string("素材文件夹路径"),
                        ]),
                        "rating": .object([
                            "type": .string("integer"),
                            "description": .string("评分 (0-5, 0=清除评分)"),
                        ]),
                    ]),
                    "required": .array([.string("clip_id"), .string("folder"), .string("rating")]),
                ])
            ),
            Tool(
                name: "set_color_label",
                description: "设置视频片段的颜色标签",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "clip_id": .object([
                            "type": .string("integer"),
                            "description": .string("片段 ID"),
                        ]),
                        "folder": .object([
                            "type": .string("string"),
                            "description": .string("素材文件夹路径"),
                        ]),
                        "color": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("red"), .string("orange"), .string("yellow"),
                                .string("green"), .string("blue"), .string("purple"),
                                .string("gray"), .string("none"),
                            ]),
                            "description": .string("颜色标签 (none=清除)"),
                        ]),
                    ]),
                    "required": .array([.string("clip_id"), .string("folder"), .string("color")]),
                ])
            ),
        ]
    }

    // MARK: - Tool 调用分发

    private static func handleToolCall(
        params: CallTool.Parameters,
        context: DatabaseContext
    ) async throws -> CallTool.Result {
        switch params.name {
        case "search":
            return try await SearchTool.execute(params: params, context: context)
        case "list_folders":
            return try ListFoldersTool.execute(params: params, context: context)
        case "list_videos":
            return try ListVideosTool.execute(params: params, context: context)
        case "get_clip":
            return try GetClipTool.execute(params: params, context: context)
        case "get_video_detail":
            return try GetVideoDetailTool.execute(params: params, context: context)
        case "get_stats":
            return try GetStatsTool.execute(params: params, context: context)
        case "add_tags":
            return try AddTagsTool.execute(params: params, context: context)
        case "remove_tags":
            return try RemoveTagsTool.execute(params: params, context: context)
        case "set_rating":
            return try SetRatingTool.execute(params: params, context: context)
        case "set_color_label":
            return try SetColorLabelTool.execute(params: params, context: context)
        default:
            throw MCPError.invalidRequest("Unknown tool: \(params.name)")
        }
    }
}
