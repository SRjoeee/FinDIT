import Foundation
import GRDB

/// USearch 双索引生命周期管理
///
/// 管理 CLIP 索引 (`clip.usearch`) 和文本嵌入索引 (`text.usearch`) 的:
/// - 懒加载: mmap 优先，不存在时从 SQLite 重建
/// - 缓存: 索引实例保留到失效
/// - 失效: 新视频入库后外部调用 `invalidate` 触发下次重新加载
///
/// 搜索层通过此 actor 获取索引实例，无需关心底层加载/重建细节。
public actor VectorIndexManager {

    private var clipIndex: USearchVectorIndex?
    private var textIndex: USearchVectorIndex?

    /// 全局搜索索引数据库（只读，用于重建）
    private let globalDB: DatabaseReader

    public init(globalDB: DatabaseReader) {
        self.globalDB = globalDB
    }

    // MARK: - CLIP Index

    /// 获取 CLIP 向量索引（懒加载）
    ///
    /// 加载策略:
    /// 1. 索引文件存在 → mmap 只读加载（零拷贝，最快）
    /// 2. 索引文件不存在 → 从 `clip_vectors` 表重建并保存
    /// 3. 数据库无向量 → 返回 nil
    public func getClipIndex() async throws -> USearchVectorIndex? {
        if let existing = clipIndex {
            return existing
        }

        let path = USearchVectorIndex.IndexPath.clipIndex
        let config = USearchVectorIndex.Config.clip768

        if USearchVectorIndex.indexFileExists(at: path) {
            let index = try USearchVectorIndex(config: config)
            try index.view(from: path)
            clipIndex = index
            return index
        }

        // 尝试重建
        let dbCount = try await globalDB.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM clip_vectors WHERE model_name = ?
                """, arguments: ["siglip2-base"]) ?? 0
        }
        guard dbCount > 0 else { return nil }

        let result = try VectorIndexRebuilder.rebuild(
            from: globalDB,
            modelName: "siglip2-base",
            config: config,
            savePath: path
        )

        // 重建后用 mmap 模式加载（保持只读一致性）
        let index = try USearchVectorIndex(config: config)
        try index.view(from: path)
        clipIndex = index
        _ = result // suppress unused warning
        return index
    }

    // MARK: - Text Embedding Index

    /// 获取文本嵌入向量索引（懒加载）
    ///
    /// 加载策略同 CLIP 索引，但使用 `text.usearch` 路径
    /// 和文本嵌入模型名称。
    public func getTextIndex() async throws -> USearchVectorIndex? {
        if let existing = textIndex {
            return existing
        }

        let path = USearchVectorIndex.IndexPath.textIndex
        let config = USearchVectorIndex.Config.textEmb768

        if USearchVectorIndex.indexFileExists(at: path) {
            let index = try USearchVectorIndex(config: config)
            try index.view(from: path)
            textIndex = index
            return index
        }

        // 文本嵌入可能来自 gemini 或 embedding-gemma
        let modelNames = ["gemini", "embedding-gemma"]
        let placeholders = modelNames.map { _ in "?" }.joined(separator: ", ")
        let dbCount = try await globalDB.read { db in
            var args = StatementArguments()
            for name in modelNames { args += [name] }
            return try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM clip_vectors WHERE model_name IN (\(placeholders))
                """, arguments: args) ?? 0
        }
        guard dbCount > 0 else { return nil }

        // 使用第一个有数据的模型名重建
        let primaryModel = try await globalDB.read { db -> String in
            for name in modelNames {
                let count = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM clip_vectors WHERE model_name = ?
                    """, arguments: [name]) ?? 0
                if count > 0 { return name }
            }
            return modelNames[0]
        }

        let result = try VectorIndexRebuilder.rebuild(
            from: globalDB,
            modelName: primaryModel,
            config: config,
            savePath: path
        )

        let index = try USearchVectorIndex(config: config)
        try index.view(from: path)
        textIndex = index
        _ = result
        return index
    }

    // MARK: - Invalidation

    /// CLIP 索引失效（新视频入库后调用）
    ///
    /// 下次 `getClipIndex()` 将重新加载/重建。
    public func invalidateClipIndex() {
        clipIndex = nil
    }

    /// 文本嵌入索引失效
    public func invalidateTextIndex() {
        textIndex = nil
    }

    /// 全部失效
    public func invalidateAll() {
        clipIndex = nil
        textIndex = nil
    }
}
