import ArgumentParser
import FindItCore

@main
struct FindItCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "findit-cli",
        abstract: "FindIt 命令行工具 — 视频素材索引与搜索",
        version: FindIt.version,
        subcommands: [
            InfoCommand.self,
        ],
        defaultSubcommand: InfoCommand.self
    )
}

/// 显示项目信息
struct InfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "显示 FindIt 版本和环境信息"
    )

    func run() {
        print("FindIt v\(FindIt.version)")
        print("核心库已就绪")
    }
}
