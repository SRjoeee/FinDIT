import Foundation
import MCP
import FindItCore

/// FindIt MCP Server 入口
///
/// 通过 Model Context Protocol 暴露 FindIt 视频搜索和管理能力。
/// 使用 stdio 传输，可被 Claude Code 等 AI 工具直接调用。
@main
struct FindItMCPMain {
    static func main() async throws {
        let server = Server(
            name: "findit-mcp",
            version: "0.1.0",
            capabilities: .init(tools: .init())
        )

        let context = try DatabaseContext()
        await ToolRegistry.register(on: server, context: context)

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}
