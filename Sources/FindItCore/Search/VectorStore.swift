import Foundation
import Accelerate

/// 内存向量存储 — 高效精确向量搜索
///
/// 将全部 embedding 加载到连续内存，利用 BLAS 矩阵运算
/// 和预计算范数实现批量搜索。
///
/// 性能对比（Apple Silicon, 768 维）：
/// - 逐个扫描: 10K clips ~600ms, 100K clips ~6s
/// - VectorStore: 10K clips ~5ms, 100K clips ~25ms
///
/// 设计决策：
/// - actor 保证并发安全（load/append/remove 与 search 互斥）
/// - 连续 Float 数组 + cblas_sgemv 利用 AMX 矩阵协处理器
/// - 预计算范数避免重复计算（存储向量不变，范数只算一次）
public actor VectorStore {

    /// 连续存储: [v0_d0, v0_d1, ..., v0_d(D-1), v1_d0, ...]
    private var vectors: [Float] = []

    /// 对应的 clip IDs（与 vectors 行对齐）
    private var clipIds: [Int64] = []

    /// 预计算的 L2 范数 |v|（与 clipIds 对齐）
    private var norms: [Float] = []

    /// 向量维度
    public let dimensions: Int

    /// 当前加载的 embedding model 名称
    public let embeddingModel: String

    /// 已加载的向量数量
    public var count: Int { clipIds.count }

    /// 是否已加载数据
    public var isEmpty: Bool { clipIds.isEmpty }

    public init(dimensions: Int, embeddingModel: String) {
        self.dimensions = dimensions
        self.embeddingModel = embeddingModel
    }

    // MARK: - 数据加载

    /// 批量加载向量数据
    ///
    /// 从数据库读取后传入 (clipId, embeddingData) 对。
    /// 调用方负责在 GRDB `db.read` 中提取原始数据，此方法只处理反序列化和范数计算。
    ///
    /// - Parameter entries: (clip_id, embedding BLOB) 对
    public func load(entries: [(clipId: Int64, embeddingData: Data)]) {
        vectors.removeAll(keepingCapacity: true)
        clipIds.removeAll(keepingCapacity: true)
        norms.removeAll(keepingCapacity: true)

        vectors.reserveCapacity(entries.count * dimensions)
        clipIds.reserveCapacity(entries.count)
        norms.reserveCapacity(entries.count)

        for (clipId, data) in entries {
            let vector = deserializeEmbedding(data)
            guard vector.count == dimensions else { continue }

            let norm = computeNorm(vector)
            guard norm > 0 else { continue }

            clipIds.append(clipId)
            vectors.append(contentsOf: vector)
            norms.append(norm)
        }
    }

    /// 增量添加单个向量（新索引的 clip）
    public func append(clipId: Int64, embedding: [Float]) {
        guard embedding.count == dimensions else { return }

        let norm = computeNorm(embedding)
        guard norm > 0 else { return }

        // 已存在则替换
        if let idx = clipIds.firstIndex(of: clipId) {
            let offset = idx * dimensions
            vectors.replaceSubrange(offset..<(offset + dimensions), with: embedding)
            norms[idx] = norm
        } else {
            clipIds.append(clipId)
            vectors.append(contentsOf: embedding)
            norms.append(norm)
        }
    }

    /// 移除向量（clip 被删除时）
    public func remove(clipId: Int64) {
        guard let idx = clipIds.firstIndex(of: clipId) else { return }
        clipIds.remove(at: idx)
        let offset = idx * dimensions
        vectors.removeSubrange(offset..<(offset + dimensions))
        norms.remove(at: idx)
    }

    // MARK: - 批量搜索

    /// 批量搜索：返回 top-K 最相似的 (clipId, similarity)
    ///
    /// 使用 cblas_sgemv 一次矩阵运算计算全部点积，
    /// 除以预计算范数得到余弦相似度，取 top-K 返回。
    ///
    /// - Parameters:
    ///   - query: 查询向量（维度必须等于 `dimensions`）
    ///   - limit: 返回最多 K 个结果
    ///   - allowedClipIDs: 可选过滤集合。传入后仅在该集合中排序取 Top-K。
    /// - Returns: 按相似度降序排列的 (clipId, similarity) 对
    public func search(
        query: [Float],
        limit: Int = 50,
        allowedClipIDs: Set<Int64>? = nil
    ) -> [(clipId: Int64, similarity: Float)] {
        let n = clipIds.count
        guard n > 0, query.count == dimensions else { return [] }

        // 1. Query norm
        var queryNormSq: Float = 0
        vDSP_dotpr(query, 1, query, 1, &queryNormSq, vDSP_Length(dimensions))
        let queryNorm = sqrt(queryNormSq)
        guard queryNorm > 0 else { return [] }

        // 2. 批量点积: vectors[N×D] × query[D×1] → dots[N×1]
        var dotProducts = [Float](repeating: 0, count: n)
        vectors.withUnsafeBufferPointer { vecBuf in
            query.withUnsafeBufferPointer { qBuf in
                guard let vecPtr = vecBuf.baseAddress,
                      let qPtr = qBuf.baseAddress else { return }
                vDSP_mmul(
                    vecPtr, 1,
                    qPtr, 1,
                    &dotProducts, 1,
                    vDSP_Length(n), 1, vDSP_Length(dimensions)
                )
            }
        }

        // 3. 余弦相似度: dot[i] / (queryNorm × norm[i])
        for i in 0..<n {
            dotProducts[i] /= (queryNorm * norms[i])
        }

        // 4. Top-K 排序（可选 clip_id 过滤）
        let candidateIndices: [Int]
        if let allowedClipIDs {
            var filtered: [Int] = []
            filtered.reserveCapacity(min(allowedClipIDs.count, n))
            for index in 0..<n where allowedClipIDs.contains(clipIds[index]) {
                filtered.append(index)
            }
            candidateIndices = filtered
        } else {
            candidateIndices = Array(0..<n)
        }
        guard !candidateIndices.isEmpty else { return [] }

        let k = min(limit, candidateIndices.count)
        var indices = candidateIndices
        // partialSort: 只需要前 K 个最大值
        // 对 100K 数据，full sort ~5ms，可接受
        indices.sort {
            dotProducts[$0] > dotProducts[$1] ||
            (dotProducts[$0] == dotProducts[$1] && clipIds[$0] < clipIds[$1])
        }

        return indices.prefix(k).map { i in
            (clipId: clipIds[i], similarity: dotProducts[i])
        }
    }

    // MARK: - Private

    private func computeNorm(_ vector: [Float]) -> Float {
        var normSq: Float = 0
        vDSP_dotpr(vector, 1, vector, 1, &normSq, vDSP_Length(vector.count))
        return sqrt(normSq)
    }

    private func deserializeEmbedding(_ data: Data) -> [Float] {
        EmbeddingUtils.deserializeEmbedding(data)
    }
}
