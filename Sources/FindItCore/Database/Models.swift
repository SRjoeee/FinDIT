import Foundation
import GRDB

// MARK: - WatchedFolder

/// 监控文件夹记录
///
/// 对应文件夹级库 `watched_folders` 表。
/// 记录用户添加的素材文件夹路径、所在卷信息、可用状态及索引进度。
public struct WatchedFolder: Codable, FetchableRecord, MutablePersistableRecord {
    public var folderId: Int64?
    public var folderPath: String
    public var volumeName: String?
    public var volumeUuid: String?
    public var isAvailable: Bool
    public var lastSeenAt: String?
    public var totalFiles: Int
    public var indexedFiles: Int

    public static let databaseTableName = "watched_folders"

    enum CodingKeys: String, CodingKey {
        case folderId = "folder_id"
        case folderPath = "folder_path"
        case volumeName = "volume_name"
        case volumeUuid = "volume_uuid"
        case isAvailable = "is_available"
        case lastSeenAt = "last_seen_at"
        case totalFiles = "total_files"
        case indexedFiles = "indexed_files"
    }

    public init(
        folderId: Int64? = nil,
        folderPath: String,
        volumeName: String? = nil,
        volumeUuid: String? = nil,
        isAvailable: Bool = true,
        lastSeenAt: String? = nil,
        totalFiles: Int = 0,
        indexedFiles: Int = 0
    ) {
        self.folderId = folderId
        self.folderPath = folderPath
        self.volumeName = volumeName
        self.volumeUuid = volumeUuid
        self.isAvailable = isAvailable
        self.lastSeenAt = lastSeenAt
        self.totalFiles = totalFiles
        self.indexedFiles = indexedFiles
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        folderId = inserted.rowID
    }
}

// MARK: - Video

/// 视频文件记录
///
/// 对应文件夹级库 `videos` 表。
/// 记录视频文件元数据、索引状态及断点续传进度。
public struct Video: Codable, FetchableRecord, MutablePersistableRecord {
    public var videoId: Int64?
    public var folderId: Int64?
    public var filePath: String
    public var fileName: String
    public var duration: Double?
    public var fileSize: Int64?
    public var fileHash: String?
    public var fileModified: String?
    public var createdAt: String?
    public var indexedAt: String?
    public var indexStatus: String
    public var indexError: String?
    public var orphanedAt: String?
    public var priority: Int
    public var lastProcessedClip: Int?
    public var srtPath: String?

    public static let databaseTableName = "videos"

    enum CodingKeys: String, CodingKey {
        case videoId = "video_id"
        case folderId = "folder_id"
        case filePath = "file_path"
        case fileName = "file_name"
        case duration
        case fileSize = "file_size"
        case fileHash = "file_hash"
        case fileModified = "file_modified"
        case createdAt = "created_at"
        case indexedAt = "indexed_at"
        case indexStatus = "index_status"
        case indexError = "index_error"
        case orphanedAt = "orphaned_at"
        case priority
        case lastProcessedClip = "last_processed_clip"
        case srtPath = "srt_path"
    }

    public init(
        videoId: Int64? = nil,
        folderId: Int64? = nil,
        filePath: String,
        fileName: String,
        duration: Double? = nil,
        fileSize: Int64? = nil,
        fileHash: String? = nil,
        fileModified: String? = nil,
        createdAt: String? = nil,
        indexedAt: String? = nil,
        indexStatus: String = "pending",
        indexError: String? = nil,
        orphanedAt: String? = nil,
        priority: Int = 0,
        lastProcessedClip: Int? = nil,
        srtPath: String? = nil
    ) {
        self.videoId = videoId
        self.folderId = folderId
        self.filePath = filePath
        self.fileName = fileName
        self.duration = duration
        self.fileSize = fileSize
        self.fileHash = fileHash
        self.fileModified = fileModified
        self.createdAt = createdAt
        self.indexedAt = indexedAt
        self.indexStatus = indexStatus
        self.indexError = indexError
        self.orphanedAt = orphanedAt
        self.priority = priority
        self.lastProcessedClip = lastProcessedClip
        self.srtPath = srtPath
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        videoId = inserted.rowID
    }
}

// MARK: - Clip

/// 视频片段记录（核心搜索对象）
///
/// 对应文件夹级库 `clips` 表。
/// 存储场景检测分割后的片段元数据、Gemini 视觉分析结果、
/// 转录文本、标签及向量嵌入。
///
/// `tags` 字段存储为 JSON 数组字符串（如 `["海滩","户外"]`），
/// 可通过 `tagsArray` / `setTags(_:)` 便利访问。
public struct Clip: Codable, FetchableRecord, MutablePersistableRecord {
    public var clipId: Int64?
    public var videoId: Int64?
    public var startTime: Double
    public var endTime: Double
    public var thumbnailPath: String?
    public var scene: String?
    public var subjects: String?
    public var actions: String?
    public var objects: String?
    public var mood: String?
    public var shotType: String?
    public var lighting: String?
    public var colors: String?
    public var clipDescription: String?
    public var tags: String?
    public var transcript: String?
    public var embedding: Data?
    public var embeddingModel: String?
    public var userTags: String?
    public var createdAt: String

    public static let databaseTableName = "clips"

    enum CodingKeys: String, CodingKey {
        case clipId = "clip_id"
        case videoId = "video_id"
        case startTime = "start_time"
        case endTime = "end_time"
        case thumbnailPath = "thumbnail_path"
        case scene
        case subjects
        case actions
        case objects
        case mood
        case shotType = "shot_type"
        case lighting
        case colors
        case clipDescription = "description"
        case tags
        case transcript
        case embedding
        case embeddingModel = "embedding_model"
        case userTags = "user_tags"
        case createdAt = "created_at"
    }

    public init(
        clipId: Int64? = nil,
        videoId: Int64? = nil,
        startTime: Double,
        endTime: Double,
        thumbnailPath: String? = nil,
        scene: String? = nil,
        subjects: String? = nil,
        actions: String? = nil,
        objects: String? = nil,
        mood: String? = nil,
        shotType: String? = nil,
        lighting: String? = nil,
        colors: String? = nil,
        clipDescription: String? = nil,
        tags: String? = nil,
        transcript: String? = nil,
        embedding: Data? = nil,
        embeddingModel: String? = nil,
        userTags: String? = nil,
        createdAt: String? = nil
    ) {
        self.clipId = clipId
        self.videoId = videoId
        self.startTime = startTime
        self.endTime = endTime
        self.thumbnailPath = thumbnailPath
        self.scene = scene
        self.subjects = subjects
        self.actions = actions
        self.objects = objects
        self.mood = mood
        self.shotType = shotType
        self.lighting = lighting
        self.colors = colors
        self.clipDescription = clipDescription
        self.tags = tags
        self.transcript = transcript
        self.embedding = embedding
        self.embeddingModel = embeddingModel
        self.userTags = userTags
        self.createdAt = createdAt ?? Self.sqliteDatetime()
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        clipId = inserted.rowID
    }

    // MARK: - Tags JSON 便利方法

    /// 将 tags JSON 字符串解析为字符串数组
    public var tagsArray: [String] {
        guard let tags = tags,
              let data = tags.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return array
    }

    /// 从字符串数组生成 tags JSON 字符串
    public mutating func setTags(_ array: [String]) {
        guard !array.isEmpty,
              let data = try? JSONEncoder().encode(array),
              let string = String(data: data, encoding: .utf8) else {
            tags = nil
            return
        }
        tags = string
    }

    // MARK: - User Tags JSON 便利方法

    /// 将 user_tags JSON 字符串解析为字符串数组
    public var userTagsArray: [String] {
        guard let userTags = userTags,
              let data = userTags.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return array
    }

    /// 从字符串数组生成 user_tags JSON 字符串
    public mutating func setUserTags(_ array: [String]) {
        guard !array.isEmpty,
              let data = try? JSONEncoder().encode(array),
              let string = String(data: data, encoding: .utf8) else {
            userTags = nil
            return
        }
        userTags = string
    }

    /// 合并 auto tags + user tags（去重）
    public var allTagsArray: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tagsArray + userTagsArray {
            let trimmed = tag.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    // MARK: - Date Utilities

    /// 复用的 UTC 日期格式化器（避免每次调用重新创建）
    ///
    /// 包内可见，供 PipelineManager 等模块格式化文件修改时间。
    static let utcFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// 生成与 SQLite `datetime('now')` 兼容的 UTC 时间字符串
    public static func sqliteDatetime() -> String {
        utcFormatter.string(from: Date())
    }

    /// 将指定日期格式化为 SQLite datetime 兼容字符串
    public static func sqliteDatetime(_ date: Date) -> String {
        utcFormatter.string(from: date)
    }
}

// MARK: - Clip + VisionField

extension Clip {

    /// 按 VisionField 获取视觉分析字段值
    ///
    /// 注意: Clip 中数组字段以 JSON 字符串存储（如 `["man","woman"]`），
    /// 此方法直接返回原始字符串值。
    public func visionValue(for field: VisionField) -> String? {
        switch field {
        case .scene:       return scene
        case .subjects:    return subjects
        case .actions:     return actions
        case .objects:     return objects
        case .mood:        return mood
        case .shotType:    return shotType
        case .lighting:    return lighting
        case .colors:      return colors
        case .description: return clipDescription
        }
    }
}

// MARK: - WatchedFolder 查询

extension WatchedFolder {

    /// 按文件夹路径查找
    public static func fetchByPath(_ db: Database, path: String) throws -> WatchedFolder? {
        try WatchedFolder.filter(Column("folder_path") == path).fetchOne(db)
    }

    /// 获取所有监控文件夹
    public static func fetchAllFolders(_ db: Database) throws -> [WatchedFolder] {
        try WatchedFolder.order(Column("folder_id")).fetchAll(db)
    }

    /// 更新可用状态
    public mutating func updateAvailability(_ db: Database, isAvailable: Bool) throws {
        self.isAvailable = isAvailable
        self.lastSeenAt = isAvailable ? Clip.sqliteDatetime() : lastSeenAt
        try update(db)
    }

    /// 更新索引进度计数
    public mutating func updateProgress(_ db: Database, totalFiles: Int, indexedFiles: Int) throws {
        self.totalFiles = totalFiles
        self.indexedFiles = indexedFiles
        try update(db)
    }
}

// MARK: - Video 查询

extension Video {

    /// 按文件路径查找（唯一）
    public static func fetchByPath(_ db: Database, path: String) throws -> Video? {
        try Video.filter(Column("file_path") == path).fetchOne(db)
    }

    /// 获取指定文件夹下的所有视频
    public static func fetchAll(forFolder folderId: Int64, in db: Database) throws -> [Video] {
        try Video.filter(Column("folder_id") == folderId)
            .order(Column("video_id"))
            .fetchAll(db)
    }

    /// 按索引状态获取视频（用于管线调度）
    public static func fetchByStatus(_ db: Database, status: String, limit: Int? = nil) throws -> [Video] {
        var request = Video.filter(Column("index_status") == status)
            .order(Column("priority").desc, Column("video_id"))
        if let limit = limit {
            request = request.limit(limit)
        }
        return try request.fetchAll(db)
    }

    /// 更新索引状态
    public mutating func updateIndexStatus(_ db: Database, status: String, error: String? = nil) throws {
        self.indexStatus = status
        self.indexError = error
        if status == "completed" {
            self.indexedAt = Clip.sqliteDatetime()
        }
        try update(db)
    }

    /// 获取 rowid 大于指定值的视频（增量同步用）
    public static func fetchAfterRowId(_ db: Database, rowId: Int64, limit: Int = 100) throws -> [Video] {
        try Video.filter(Column("video_id") > rowId)
            .order(Column("video_id"))
            .limit(limit)
            .fetchAll(db)
    }
}

// MARK: - Clip 查询

extension Clip {

    /// 获取指定视频的所有片段
    public static func fetchAll(forVideo videoId: Int64, in db: Database) throws -> [Clip] {
        try Clip.filter(Column("video_id") == videoId)
            .order(Column("start_time"))
            .fetchAll(db)
    }

    /// 获取 rowid 大于指定值的片段（增量同步用）
    public static func fetchAfterRowId(_ db: Database, rowId: Int64, limit: Int = 100) throws -> [Clip] {
        try Clip.filter(Column("clip_id") > rowId)
            .order(Column("clip_id"))
            .limit(limit)
            .fetchAll(db)
    }
}
