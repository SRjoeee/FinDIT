import Foundation

/// 文件夹层级关系工具
///
/// 判断文件夹路径间的父子关系，规划新文件夹添加策略。
/// 用于智能嵌套文件夹功能（替代简单的 overlap 拒绝）。
public enum FolderHierarchy {

    /// 两个路径的关系
    public enum Relationship: Equatable, Sendable {
        /// `a` 是 `b` 的父级（`a` 包含 `b`）
        case parent
        /// `a` 是 `b` 的子级（`a` 被 `b` 包含）
        case child
        /// 无关
        case unrelated
        /// 相同路径
        case duplicate
    }

    /// 判断路径 `a` 相对于路径 `b` 的关系
    ///
    /// 路径会自动规范化（去除尾部 `/`）。
    ///
    /// ```swift
    /// FolderHierarchy.relationship("/A", "/A/B")   // .parent  (A 包含 A/B)
    /// FolderHierarchy.relationship("/A/B", "/A")   // .child   (A/B 被 A 包含)
    /// FolderHierarchy.relationship("/A", "/C")     // .unrelated
    /// FolderHierarchy.relationship("/A", "/A")     // .duplicate
    /// ```
    public static func relationship(_ a: String, _ b: String) -> Relationship {
        let normA = normalize(a)
        let normB = normalize(b)

        if normA == normB { return .duplicate }
        if normB.hasPrefix(normA + "/") { return .parent }
        if normA.hasPrefix(normB + "/") { return .child }
        return .unrelated
    }

    /// 添加方案
    public struct AdditionPlan: Sendable, Equatable {
        /// 系统应执行的动作
        public let action: Action

        /// 添加动作类型
        public enum Action: Sendable, Equatable {
            /// 正常添加（无重叠）
            case addNormally
            /// 作为父级添加，排除已索引的子文件夹
            case addAsParent(existingChildren: [String])
            /// 作为子级快捷入口（不索引，仅 UI 书签）
            case addAsSubfolderBookmark(parentFolder: String)
            /// 已存在完全相同的路径
            case duplicate
        }
    }

    /// 计算添加新文件夹时的行动方案
    ///
    /// - Parameters:
    ///   - newPath: 待添加的文件夹路径
    ///   - existingPaths: 已注册的文件夹路径列表
    /// - Returns: 建议的添加方案
    public static func resolveAddition(
        newPath: String,
        existingPaths: [String]
    ) -> AdditionPlan {
        let norm = normalize(newPath)

        var children: [String] = []
        var parentFolder: String?

        for existing in existingPaths {
            let normExisting = normalize(existing)

            switch relationship(norm, normExisting) {
            case .duplicate:
                return AdditionPlan(action: .duplicate)
            case .parent:
                // newPath 包含 existing → newPath 是父级
                children.append(existing)
            case .child:
                // newPath 被 existing 包含 → newPath 是子级
                // 取最近的（最长路径）父级
                if let current = parentFolder {
                    if normExisting.count > normalize(current).count {
                        parentFolder = existing
                    }
                } else {
                    parentFolder = existing
                }
            case .unrelated:
                continue
            }
        }

        if let parent = parentFolder {
            return AdditionPlan(action: .addAsSubfolderBookmark(parentFolder: parent))
        }

        if !children.isEmpty {
            return AdditionPlan(action: .addAsParent(existingChildren: children.sorted()))
        }

        return AdditionPlan(action: .addNormally)
    }

    /// 在文件夹列表中找出给定路径的所有已注册子文件夹
    ///
    /// - Parameters:
    ///   - path: 父文件夹路径
    ///   - paths: 所有已注册文件夹路径
    /// - Returns: 子文件夹路径数组（已排序）
    public static func findChildren(of path: String, in paths: [String]) -> [String] {
        let norm = normalize(path)
        return paths
            .filter { normalize($0).hasPrefix(norm + "/") }
            .sorted()
    }

    /// 在文件夹列表中找出给定路径的已注册父文件夹
    ///
    /// 如有多个层级的父文件夹，返回最近的（最长路径）。
    ///
    /// - Parameters:
    ///   - path: 子文件夹路径
    ///   - paths: 所有已注册文件夹路径
    /// - Returns: 最近的父文件夹路径，无则 nil
    public static func findParent(of path: String, in paths: [String]) -> String? {
        let norm = normalize(path)
        var best: String?
        for p in paths {
            let normP = normalize(p)
            if norm.hasPrefix(normP + "/") {
                if let current = best {
                    if normP.count > normalize(current).count {
                        best = p
                    }
                } else {
                    best = p
                }
            }
        }
        return best
    }

    // MARK: - 内部

    /// 规范化路径：去除尾部 `/`
    static func normalize(_ path: String) -> String {
        var p = path
        while p.hasSuffix("/") && p.count > 1 {
            p.removeLast()
        }
        return p
    }
}
