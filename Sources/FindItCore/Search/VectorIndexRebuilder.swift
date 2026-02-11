import Foundation
import GRDB

/// 向量索引重建器
///
/// 从 SQLite `clip_vectors` 表重建 USearch 索引文件。
/// 用于：
/// - App 首次启动（索引文件不存在）
/// - 索引文件损坏或删除后恢复
/// - 模型升级后重新编码
public enum VectorIndexRebuilder {

    /// 重建结果
    public struct RebuildResult: Sendable {
        /// 重建的向量数量
        public let vectorCount: Int
        /// 耗时（秒）
        public let duration: TimeInterval
    }

    /// 从全局库的 clip_vectors 表重建 USearch 索引
    ///
    /// - Parameters:
    ///   - db: 全局搜索索引数据库（只读）
    ///   - modelName: 模型名称（用于过滤 clip_vectors 表）
    ///   - config: USearch 索引配置
    ///   - savePath: 索引文件保存路径
    /// - Returns: 重建结果
    public static func rebuild(
        from db: DatabaseReader,
        modelName: String,
        config: USearchVectorIndex.Config = .clip768,
        savePath: String
    ) throws -> RebuildResult {
        let start = CFAbsoluteTimeGetCurrent()

        let vectorIndex = try USearchVectorIndex(config: config)

        // 分批读取向量数据，避免一次加载过多到内存
        let batchSize = 5000
        var offset = 0
        var totalCount = 0

        // 先获取总数以预分配容量
        let totalVectors = try db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM clip_vectors WHERE model_name = ?
                """, arguments: [modelName]) ?? 0
        }

        if totalVectors > 0 {
            try vectorIndex.reserve(totalVectors)
        }

        while true {
            let batch: [(clipId: Int64, vector: Data)] = try db.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT clip_id, vector FROM clip_vectors
                    WHERE model_name = ?
                    ORDER BY vector_id
                    LIMIT ? OFFSET ?
                    """, arguments: [modelName, batchSize, offset])
                return rows.map { row in
                    (clipId: row["clip_id"] as Int64, vector: row["vector"] as Data)
                }
            }

            guard !batch.isEmpty else { break }

            for (clipId, vectorData) in batch {
                let vector = EmbeddingUtils.deserializeEmbedding(vectorData)
                guard vector.count == Int(config.dimensions) else { continue }
                let key = USearchVectorIndex.clipIdToKey(clipId)
                try vectorIndex.add(key: key, vector: vector)
            }

            totalCount += batch.count
            offset += batchSize

            if batch.count < batchSize { break }
        }

        try vectorIndex.save(to: savePath)

        let duration = CFAbsoluteTimeGetCurrent() - start
        return RebuildResult(vectorCount: totalCount, duration: duration)
    }

    /// 从文件夹库的 clip_vectors 表重建索引
    ///
    /// 与 `rebuild(from:)` 类似，但从文件夹级库读取。
    /// 用于单个文件夹的索引重建。
    public static func rebuildFromFolder(
        folderDB: DatabaseReader,
        modelName: String,
        config: USearchVectorIndex.Config = .clip768,
        savePath: String
    ) throws -> RebuildResult {
        return try rebuild(
            from: folderDB,
            modelName: modelName,
            config: config,
            savePath: savePath
        )
    }

    /// 检查索引文件是否需要重建
    ///
    /// - Parameters:
    ///   - indexPath: USearch 索引文件路径
    ///   - db: 数据库（用于比较向量数量）
    ///   - modelName: 模型名称
    /// - Returns: 是否需要重建
    public static func needsRebuild(
        indexPath: String,
        db: DatabaseReader,
        modelName: String
    ) throws -> Bool {
        // 索引文件不存在 → 需要重建
        guard USearchVectorIndex.indexFileExists(at: indexPath) else {
            return true
        }

        // 尝试加载索引检查向量数量
        let dbCount = try db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM clip_vectors WHERE model_name = ?
                """, arguments: [modelName]) ?? 0
        }

        // 数据库无向量 → 无需重建（空索引文件有效）
        if dbCount == 0 {
            return false
        }

        // 加载索引比较数量
        let config = USearchVectorIndex.Config.clip768
        let index = try USearchVectorIndex(config: config)
        try index.load(from: indexPath)
        let indexCount = try index.count

        // 数量不匹配 → 需要重建
        return indexCount != dbCount
    }
}
