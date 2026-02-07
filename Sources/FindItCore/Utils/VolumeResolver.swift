import Foundation

/// 卷信息解析工具
///
/// 从文件路径解析所在卷的元数据（UUID、名称、可移除性等），
/// 支持通过 UUID 在已挂载卷中查找匹配的挂载点。
/// 纯 Foundation 框架，零外部依赖。
public enum VolumeResolver {

    /// 卷信息
    public struct VolumeInfo: Sendable, Equatable {
        /// 卷 UUID — 唯一标识，不随挂载点变化
        public let uuid: String?
        /// 卷名称（如 "素材盘A"）
        public let name: String?
        /// 是否可移除卷（外接硬盘/U盘）
        public let isRemovable: Bool
        /// 是否内置卷（启动盘等）
        public let isInternal: Bool

        public init(uuid: String? = nil, name: String? = nil, isRemovable: Bool = false, isInternal: Bool = true) {
            self.uuid = uuid
            self.name = name
            self.isRemovable = isRemovable
            self.isInternal = isInternal
        }
    }

    /// 从文件路径解析所在卷的信息
    ///
    /// 使用 `URL.resourceValues` 读取卷属性。
    /// 路径不存在或读取失败时返回默认值（nil uuid/name，非可移除，内置）。
    ///
    /// - Parameter path: 文件或目录的绝对路径
    /// - Returns: 卷信息
    public static func resolve(path: String) -> VolumeInfo {
        let url = URL(fileURLWithPath: path)

        do {
            let values = try url.resourceValues(forKeys: [
                .volumeUUIDStringKey,
                .volumeNameKey,
                .volumeIsRemovableKey,
                .volumeIsInternalKey,
            ])

            return VolumeInfo(
                uuid: values.volumeUUIDString,
                name: values.volumeName,
                isRemovable: values.volumeIsRemovable ?? false,
                isInternal: values.volumeIsInternal ?? true
            )
        } catch {
            return VolumeInfo()
        }
    }

    /// 检查路径是否可访问
    ///
    /// 检查文件或目录是否存在于已挂载的卷上。
    /// 比 `FileManager.fileExists` 更明确地表达"卷级别可达性"的语义。
    ///
    /// - Parameter path: 绝对路径
    /// - Returns: 路径是否可访问
    public static func isAccessible(path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// 通过 UUID 在所有已挂载卷中查找匹配的挂载点
    ///
    /// 用于外接硬盘重新连接后，通过 UUID 匹配新的挂载路径
    /// （即使挂载点变了也能识别同一个卷）。
    ///
    /// - Parameter uuid: 目标卷的 UUID 字符串
    /// - Returns: 匹配卷的挂载点路径，未找到返回 nil
    public static func findMountPoint(forVolumeUUID uuid: String) -> String? {
        guard !uuid.isEmpty else { return nil }

        // 获取所有挂载点
        let mountPoints = mountedVolumePaths()

        for mountPath in mountPoints {
            let url = URL(fileURLWithPath: mountPath)
            if let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]),
               values.volumeUUIDString == uuid {
                return mountPath
            }
        }

        return nil
    }

    /// 通过卷 UUID 更新文件夹路径
    ///
    /// 当外接硬盘重新连接但挂载点可能变化时，根据 UUID 查找新挂载点，
    /// 再拼接原始文件夹的相对路径部分。
    ///
    /// - Parameters:
    ///   - oldPath: 旧的文件夹绝对路径
    ///   - volumeUUID: 卷 UUID
    /// - Returns: 更新后的路径，未找到返回 nil
    public static func resolveUpdatedPath(oldPath: String, volumeUUID: String) -> String? {
        guard let newMountPoint = findMountPoint(forVolumeUUID: volumeUUID) else { return nil }

        // 获取旧路径所在的旧挂载点
        let oldMountPoint = mountPointForPath(oldPath)

        // 计算相对路径
        guard oldPath.hasPrefix(oldMountPoint) else { return nil }
        let relativePart = String(oldPath.dropFirst(oldMountPoint.count))

        // 拼接新路径
        let newPath = newMountPoint + relativePart
        return FileManager.default.fileExists(atPath: newPath) ? newPath : nil
    }

    // MARK: - Private

    /// 获取所有已挂载卷的路径
    static func mountedVolumePaths() -> [String] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.volumeUUIDStringKey]
        let options: FileManager.VolumeEnumerationOptions = [.skipHiddenVolumes]

        guard let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: options) else {
            return []
        }

        return urls.map(\.path)
    }

    /// 获取路径所在卷的挂载点
    private static func mountPointForPath(_ path: String) -> String {
        // /Volumes/DiskName/some/folder → /Volumes/DiskName
        if path.hasPrefix("/Volumes/") {
            let parts = path.split(separator: "/", maxSplits: 3)
            if parts.count >= 2 {
                return "/\(parts[0])/\(parts[1])"
            }
        }
        // 根卷路径
        return "/"
    }
}
