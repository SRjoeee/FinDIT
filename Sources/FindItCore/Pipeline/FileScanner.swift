import Foundation

/// 视频文件发现工具
///
/// 递归扫描指定文件夹中的视频文件，按支持的扩展名过滤。
/// 跳过隐藏文件和隐藏目录（以 `.` 开头）。
public enum FileScanner {

    /// 支持的视频文件扩展名（小写）
    public static let supportedExtensions: Set<String> = [
        "mp4", "mov", "mkv", "avi", "mxf", "webm", "m4v", "ts", "mts"
    ]

    /// 判断文件路径是否为支持的视频格式
    public static func isVideoFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }

    /// 递归扫描文件夹中的视频文件
    ///
    /// 跳过隐藏文件/目录（以 `.` 开头的名称）。
    /// 返回按文件路径字母序排序的绝对路径数组。
    ///
    /// - Parameter folderPath: 文件夹的绝对路径
    /// - Returns: 视频文件路径数组（已排序）
    public static func scanVideoFiles(in folderPath: String) throws -> [String] {
        let fm = FileManager.default
        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [String] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            if isVideoFile(fileURL.path) {
                results.append(fileURL.path)
            }
        }

        return results.sorted()
    }
}
