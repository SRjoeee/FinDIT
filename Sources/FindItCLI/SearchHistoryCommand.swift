import ArgumentParser
import Foundation
import FindItCore
import GRDB

/// 查看最近搜索记录
///
/// 从全局搜索索引读取搜索历史（query、时间、结果数）。
struct SearchHistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search-history",
        abstract: "查看最近搜索记录"
    )

    @Option(name: .shortAndLong, help: "显示条数")
    var limit: Int = 20

    @Option(name: .long, help: "输出格式: text, json")
    var format: OutputFormat = .text

    func run() throws {
        let globalDB = try DatabaseManager.openGlobalDatabase()

        let history = try globalDB.read { db in
            try SearchEngine.recentSearches(db, limit: limit)
        }

        switch format {
        case .json:
            struct HistoryEntry: Codable {
                let query: String
                let searchedAt: String
                let resultCount: Int
            }
            let entries = history.map {
                HistoryEntry(query: $0.query, searchedAt: $0.searchedAt, resultCount: $0.resultCount)
            }
            try JSONOutput.print(entries)
        case .text:
            if history.isEmpty {
                print("无搜索记录")
                return
            }
            print("最近搜索记录 (\(history.count) 条):\n")
            for (i, h) in history.enumerated() {
                print("[\(i + 1)] \"\(h.query)\" → \(h.resultCount) 个结果  (\(h.searchedAt))")
            }
        }
    }
}
