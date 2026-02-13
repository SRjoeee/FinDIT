import ArgumentParser
import Foundation
import FindItCore
import GRDB

// MARK: - reset

/// 数据重置命令组 (reset all / reset folder / reset global / reset vectors)
struct ResetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "重置索引数据（不删视频源文件和 ML 模型）",
        subcommands: [
            ResetAllCommand.self,
            ResetFolderCommand.self,
            ResetGlobalCommand.self,
            ResetVectorsCommand.self,
        ]
    )
}

// MARK: - reset all

/// 全量重置 — 删除所有索引数据
struct ResetAllCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "all",
        abstract: "删除所有索引数据（全局 DB + 文件夹库 + 向量索引 + 缩略图）"
    )

    @Flag(name: .shortAndLong, help: "跳过确认提示")
    var yes = false

    @Flag(name: .long, help: "同时删除视频同目录的 SRT 文件")
    var includeSrt = false

    @Flag(name: .long, help: "预览模式，只列出将删除的内容")
    var dryRun = false

    func run() async throws {
        let fm = FileManager.default

        // 1. 收集所有要删除的路径
        var targets: [(path: String, label: String)] = []

        // 全局文件
        let appSupportDir = appSupportFindItPath()
        let globalDB = (appSupportDir as NSString).appendingPathComponent("search.sqlite")
        let globalShm = globalDB + "-shm"
        let globalWal = globalDB + "-wal"
        let clipUsearch = USearchVectorIndex.IndexPath.clipIndex
        let textUsearch = USearchVectorIndex.IndexPath.textIndex
        let srtDir = (appSupportDir as NSString).appendingPathComponent("srt")

        for (path, label) in [
            (globalDB, "全局数据库"),
            (globalShm, "全局数据库 SHM"),
            (globalWal, "全局数据库 WAL"),
            (clipUsearch, "CLIP 向量索引"),
            (textUsearch, "文本嵌入索引"),
            (srtDir, "SRT 回退目录"),
        ] {
            if fm.fileExists(atPath: path) {
                targets.append((path, label))
            }
        }

        // 从全局 DB 读取已知文件夹路径
        var folderPaths: [String] = []
        var srtFiles: [String] = []
        if fm.fileExists(atPath: globalDB) {
            do {
                let pool = try DatabasePool(path: globalDB)
                folderPaths = try await pool.read { db in
                    try String.fetchAll(db, sql: "SELECT DISTINCT source_folder FROM clips")
                }
                // 收集视频同目录 SRT
                if includeSrt {
                    let videoPaths = try await pool.read { db in
                        try String.fetchAll(db, sql: "SELECT DISTINCT video_path FROM clips")
                    }
                    for vp in videoPaths {
                        let srt = (vp as NSString).deletingPathExtension + ".srt"
                        if fm.fileExists(atPath: srt) {
                            srtFiles.append(srt)
                        }
                    }
                }
            } catch {
                print("⚠️ 读取全局数据库失败: \(error.localizedDescription)")
            }
        }

        // .clip-index 目录
        var clipIndexDirs: [String] = []
        for folder in folderPaths {
            let ciDir = (folder as NSString).appendingPathComponent(".clip-index")
            if fm.fileExists(atPath: ciDir) {
                clipIndexDirs.append(ciDir)
                targets.append((ciDir, "文件夹索引: \(folder)"))
            }
        }

        for srt in srtFiles {
            targets.append((srt, "SRT: \(srt)"))
        }

        // 2. 显示
        if targets.isEmpty {
            print("无索引数据需要清除。")
            return
        }

        print("将删除以下索引数据:\n")
        for t in targets {
            let size = fileSize(t.path)
            print("  \(t.label)  [\(size)]")
            print("    \(t.path)")
        }
        print()

        if dryRun {
            print("(--dry-run 模式，未实际删除)")
            return
        }

        // 3. 确认
        if !yes {
            print("确认删除? (y/N): ", terminator: "")
            guard readLine()?.lowercased() == "y" else {
                print("已取消。")
                return
            }
        }

        // 4. 执行删除
        var deleted = 0
        for t in targets {
            do {
                try fm.removeItem(atPath: t.path)
                deleted += 1
            } catch {
                print("⚠️ 删除失败: \(t.path) — \(error.localizedDescription)")
            }
        }
        print("\n✅ 已删除 \(deleted)/\(targets.count) 项")
    }
}

// MARK: - reset folder

/// 重置单个文件夹的索引数据
struct ResetFolderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "folder",
        abstract: "重置单个素材文件夹的索引数据"
    )

    @Argument(help: "素材文件夹路径")
    var path: String

    @Flag(name: .shortAndLong, help: "跳过确认提示")
    var yes = false

    @Flag(name: .long, help: "预览模式")
    var dryRun = false

    func run() async throws {
        let fm = FileManager.default
        let folderPath = (path as NSString).standardizingPath

        guard fm.fileExists(atPath: folderPath) else {
            print("❌ 文件夹不存在: \(folderPath)")
            throw ExitCode.failure
        }

        var targets: [(path: String, label: String)] = []

        // .clip-index 目录
        let ciDir = (folderPath as NSString).appendingPathComponent(".clip-index")
        if fm.fileExists(atPath: ciDir) {
            let size = fileSize(ciDir)
            targets.append((ciDir, "文件夹索引 [\(size)]"))
        }

        // 显示
        if targets.isEmpty {
            print("该文件夹无索引数据。")
            return
        }

        print("将删除:")
        for t in targets {
            print("  \(t.label): \(t.path)")
        }
        print("\n同时从全局数据库中清除该文件夹的记录。")

        if dryRun {
            print("\n(--dry-run 模式，未实际删除)")
            return
        }

        if !yes {
            print("\n确认? (y/N): ", terminator: "")
            guard readLine()?.lowercased() == "y" else {
                print("已取消。")
                return
            }
        }

        // 删除 .clip-index
        for t in targets {
            do {
                try fm.removeItem(atPath: t.path)
                print("✅ 已删除: \(t.label)")
            } catch {
                print("⚠️ 删除失败: \(t.path) — \(error.localizedDescription)")
            }
        }

        // 从全局 DB 清除
        let appSupportDir = appSupportFindItPath()
        let globalDBPath = (appSupportDir as NSString).appendingPathComponent("search.sqlite")
        if fm.fileExists(atPath: globalDBPath) {
            do {
                let globalDB = try DatabaseManager.openGlobalDatabase()
                try SyncEngine.removeFolderData(folderPath: folderPath, from: globalDB)
                print("✅ 已从全局数据库清除该文件夹记录")
            } catch {
                print("⚠️ 清除全局数据库记录失败: \(error.localizedDescription)")
            }
        }

        print("\n重置完成。")
    }
}

// MARK: - reset global

/// 仅重置全局索引（文件夹级库保留，可用 sync 重建）
struct ResetGlobalCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "global",
        abstract: "仅重置全局搜索索引和向量索引（文件夹级库保留）"
    )

    @Flag(name: .shortAndLong, help: "跳过确认提示")
    var yes = false

    @Flag(name: .long, help: "预览模式")
    var dryRun = false

    func run() async throws {
        let fm = FileManager.default
        let appSupportDir = appSupportFindItPath()

        var targets: [(path: String, label: String)] = []

        let files: [(String, String)] = [
            ("search.sqlite", "全局数据库"),
            ("search.sqlite-shm", "全局数据库 SHM"),
            ("search.sqlite-wal", "全局数据库 WAL"),
        ]
        for (name, label) in files {
            let path = (appSupportDir as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: path) {
                targets.append((path, "\(label) [\(fileSize(path))]"))
            }
        }

        // USearch
        for (path, label) in [
            (USearchVectorIndex.IndexPath.clipIndex, "CLIP 向量索引"),
            (USearchVectorIndex.IndexPath.textIndex, "文本嵌入索引"),
        ] {
            if fm.fileExists(atPath: path) {
                targets.append((path, "\(label) [\(fileSize(path))]"))
            }
        }

        if targets.isEmpty {
            print("全局索引已经为空。")
            return
        }

        print("将删除:")
        for t in targets {
            print("  \(t.label)")
        }
        print("\n文件夹级库 (.clip-index/) 保留，可用 `findit-cli sync` 重建全局索引。")

        if dryRun {
            print("\n(--dry-run 模式，未实际删除)")
            return
        }

        if !yes {
            print("\n确认? (y/N): ", terminator: "")
            guard readLine()?.lowercased() == "y" else {
                print("已取消。")
                return
            }
        }

        var deleted = 0
        for t in targets {
            do {
                try fm.removeItem(atPath: t.path)
                deleted += 1
            } catch {
                print("⚠️ 删除失败: \(t.path) — \(error.localizedDescription)")
            }
        }
        print("\n✅ 已删除 \(deleted)/\(targets.count) 项")
    }
}

// MARK: - reset vectors

/// 仅重置向量索引文件
struct ResetVectorsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vectors",
        abstract: "仅重置 USearch 向量索引文件（从 clip_vectors 表可重建）"
    )

    @Flag(name: .shortAndLong, help: "跳过确认提示")
    var yes = false

    @Flag(name: .long, help: "预览模式")
    var dryRun = false

    func run() async throws {
        let fm = FileManager.default
        var targets: [(path: String, label: String)] = []

        for (path, label) in [
            (USearchVectorIndex.IndexPath.clipIndex, "CLIP 向量索引"),
            (USearchVectorIndex.IndexPath.textIndex, "文本嵌入索引"),
        ] {
            if fm.fileExists(atPath: path) {
                targets.append((path, "\(label) [\(fileSize(path))]"))
            }
        }

        if targets.isEmpty {
            print("无向量索引文件。")
            return
        }

        print("将删除:")
        for t in targets {
            print("  \(t.label): \(t.path)")
        }
        print("\n搜索时会从 clip_vectors 表自动重建。")

        if dryRun {
            print("\n(--dry-run 模式，未实际删除)")
            return
        }

        if !yes {
            print("\n确认? (y/N): ", terminator: "")
            guard readLine()?.lowercased() == "y" else {
                print("已取消。")
                return
            }
        }

        var deleted = 0
        for t in targets {
            do {
                try fm.removeItem(atPath: t.path)
                deleted += 1
            } catch {
                print("⚠️ 删除失败: \(t.path) — \(error.localizedDescription)")
            }
        }
        print("\n✅ 已删除 \(deleted)/\(targets.count) 项")
    }
}

// MARK: - Helpers

/// 获取 ~/Library/Application Support/FindIt/ 路径
private func appSupportFindItPath() -> String {
    let base = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first!.path
    return (base as NSString).appendingPathComponent("FindIt")
}

/// 友好的文件/目录大小显示
private func fileSize(_ path: String) -> String {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return "0 B" }

    if isDir.boolValue {
        // 递归计算目录大小
        guard let enumerator = fm.enumerator(atPath: path) else { return "?" }
        var total: UInt64 = 0
        while let file = enumerator.nextObject() as? String {
            let fullPath = (path as NSString).appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
               let size = attrs[.size] as? UInt64 {
                total += size
            }
        }
        return formatBytes(total)
    } else {
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else { return "?" }
        return formatBytes(size)
    }
}

private func formatBytes(_ bytes: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var value = Double(bytes)
    var unitIndex = 0
    while value >= 1024 && unitIndex < units.count - 1 {
        value /= 1024
        unitIndex += 1
    }
    if unitIndex == 0 { return "\(bytes) B" }
    return String(format: "%.1f %@", value, units[unitIndex])
}
