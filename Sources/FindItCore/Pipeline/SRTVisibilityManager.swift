import Foundation
import GRDB

/// SRT 文件可见性管理
///
/// 通过 macOS 原生 `URLResourceValues.isHidden` 属性控制 SRT 文件在 Finder 中的可见性。
/// 不修改文件名或路径，仅设置隐藏标记。
public enum SRTVisibilityManager {

    /// 设置单个 SRT 文件的隐藏状态
    ///
    /// - Parameters:
    ///   - path: SRT 文件绝对路径
    ///   - hidden: true = Finder 中不可见
    public static func setHidden(_ path: String, hidden: Bool) throws {
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.isHidden = hidden
        try url.setResourceValues(values)
    }

    /// 批量切换所有已索引 SRT 文件的隐藏状态
    ///
    /// 遍历所有已注册文件夹的 `videos.srt_path`，仅处理视频同目录的 SRT（非 App Support 目录的降级路径）。
    ///
    /// - Parameters:
    ///   - hidden: true = 隐藏
    ///   - folderPaths: 已注册的素材文件夹路径列表
    /// - Returns: (processed: 成功处理数, failed: 失败数)
    public static func batchSetVisibility(
        hidden: Bool,
        folderPaths: [String]
    ) async -> (processed: Int, failed: Int) {
        var processed = 0
        var failed = 0

        // App Support 目录前缀（降级 SRT 不受隐藏设置影响）
        let appSupportPrefix: String
        if let url = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            appSupportPrefix = url.appendingPathComponent("FindIt/srt").path
        } else {
            appSupportPrefix = ""
        }

        for folderPath in folderPaths {
            let srtPaths = collectSRTPaths(folderPath: folderPath)

            for srtPath in srtPaths {
                // 跳过 App Support 降级路径
                if !appSupportPrefix.isEmpty && srtPath.hasPrefix(appSupportPrefix) {
                    continue
                }

                guard FileManager.default.fileExists(atPath: srtPath) else { continue }

                do {
                    try setHidden(srtPath, hidden: hidden)
                    processed += 1
                } catch {
                    failed += 1
                }
            }
        }

        return (processed, failed)
    }

    /// 从文件夹级数据库中收集所有 SRT 路径
    private static func collectSRTPaths(folderPath: String) -> [String] {
        do {
            let folderDB = try DatabaseManager.openFolderDatabase(at: folderPath)
            return try folderDB.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT srt_path FROM videos WHERE srt_path IS NOT NULL
                """)
                return rows.compactMap { row -> String? in
                    let path: String? = row["srt_path"]
                    return path
                }
            }
        } catch {
            return []
        }
    }
}
