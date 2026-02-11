import Foundation

/// 视频文件发现工具
///
/// 递归扫描指定文件夹中的视频文件，按支持的扩展名过滤。
/// 跳过隐藏文件和隐藏目录（以 `.` 开头）。
public enum FileScanner {

    /// 支持的视频文件扩展名（小写）
    public static let supportedExtensions: Set<String> = [
        "mp4", "mov", "mkv", "avi", "mxf", "webm", "m4v", "ts", "mts",
        "braw", "r3d", "nev"
    ]

    /// 支持的照片扩展名（预埋，R5 启用）
    public static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "tiff", "webp", "raw", "dng"
    ]

    /// 支持的音频扩展名（预埋，R5 启用）
    public static let audioExtensions: Set<String> = [
        "mp3", "wav", "aac", "flac", "m4a", "aiff"
    ]

    /// 所有支持的媒体扩展名
    public static let allSupportedExtensions: Set<String> =
        supportedExtensions.union(photoExtensions).union(audioExtensions)

    /// 判断文件路径是否为支持的视频格式
    public static func isVideoFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }

    /// 判断文件的媒体类型
    ///
    /// - Returns: `.video`, `.photo`, `.audio`, 或 nil（不支持的格式）
    public static func mediaType(for path: String) -> MediaType? {
        let ext = (path as NSString).pathExtension.lowercased()
        if supportedExtensions.contains(ext) { return .video }
        if photoExtensions.contains(ext) { return .photo }
        if audioExtensions.contains(ext) { return .audio }
        return nil
    }

    /// 递归扫描文件夹中的视频文件
    ///
    /// 跳过隐藏文件/目录（以 `.` 开头的名称）。
    /// 返回按文件路径字母序排序的绝对路径数组。
    ///
    /// - Parameter folderPath: 文件夹的绝对路径
    /// - Returns: 视频文件路径数组（已排序）
    public static func scanVideoFiles(in folderPath: String) throws -> [String] {
        try scanVideoFiles(in: folderPath, excluding: [])
    }

    /// 递归扫描文件夹中的视频文件，排除指定子目录
    ///
    /// 当添加父文件夹时（已有子文件夹被独立索引），使用此方法
    /// 跳过已索引的子文件夹路径，避免重复索引。
    ///
    /// - Parameters:
    ///   - folderPath: 文件夹的绝对路径
    ///   - excluding: 要排除的子文件夹路径集合
    /// - Returns: 视频文件路径数组（已排序）
    public static func scanVideoFiles(
        in folderPath: String,
        excluding: Set<String>
    ) throws -> [String] {
        let fm = FileManager.default
        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        // 规范化 + 解析符号链接排除路径
        // macOS 枚举器可能返回 /private/var/... 而输入路径是 /var/...
        // 通过 resolvingSymlinksInPath 统一为规范路径
        let normalizedExclusions = Set(excluding.map {
            URL(fileURLWithPath: FolderHierarchy.normalize($0))
                .resolvingSymlinksInPath().path
        })

        var results: [String] = []
        for case let fileURL as URL in enumerator {
            // 用解析后的路径做比较，避免 /var vs /private/var 不匹配
            let resolvedPath = fileURL.resolvingSymlinksInPath().path

            // 检查是否进入了排除的子目录
            if !normalizedExclusions.isEmpty {
                let isExcluded = normalizedExclusions.contains { excl in
                    resolvedPath == excl || resolvedPath.hasPrefix(excl + "/")
                }
                if isExcluded {
                    // 如果是目录，跳过其后代
                    let dirValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
                    if dirValues?.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
            }

            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            if isVideoFile(resolvedPath) {
                results.append(resolvedPath)
            }
        }

        return results.sorted()
    }
}
