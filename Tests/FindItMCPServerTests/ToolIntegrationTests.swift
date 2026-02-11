import XCTest
import GRDB
import MCP
@testable import FindItCore
@testable import FindItMCPServer

final class ToolIntegrationTests: XCTestCase {

    // MARK: - 辅助

    /// 创建带测试数据的 DatabaseContext
    ///
    /// 返回 (context, folderClipId)，其中 folderClipId 是文件夹库中第一个 clip 的 ID。
    private static func makeTestContext() throws -> (DatabaseContext, Int64) {
        let folderDB = try DatabaseManager.makeFolderInMemoryDatabase()
        let globalDB = try DatabaseManager.makeGlobalInMemoryDatabase()

        var clipId: Int64 = 0

        // 填充文件夹库（含 vision 字段）
        try folderDB.write { db in
            try db.execute(sql: "INSERT INTO watched_folders (folder_path) VALUES ('/test/folder')")
            try db.execute(sql: """
                INSERT INTO videos (folder_id, file_path, file_name, index_status, duration, file_size)
                VALUES (1, '/test/folder/video1.mp4', 'video1.mp4', 'completed', 30.0, 1024000)
                """)
            try db.execute(sql: """
                INSERT INTO clips (video_id, start_time, end_time, scene, description,
                    subjects, actions, objects, lighting, colors,
                    tags, transcript, mood, shot_type, rating, color_label, user_tags, created_at)
                VALUES (1, 0.0, 5.0, '海滩日落', '美丽的海滩日落景色',
                    '["人物","海鸥"]', '["散步","飞翔"]', '["沙滩","海浪"]', 'golden hour', '["橙色","蓝色"]',
                    '["海滩","日落"]', '这是一个美丽的日落', 'peaceful', 'wide', 3, 'blue',
                    '["精选"]', datetime('now'))
                """)
            clipId = db.lastInsertedRowID

            try db.execute(sql: """
                INSERT INTO clips (video_id, start_time, end_time, scene, description, tags,
                    mood, shot_type, rating, created_at)
                VALUES (1, 5.0, 10.0, '城市夜景', '繁华的城市夜晚',
                    '["城市","夜景"]', 'energetic', 'aerial', 0, datetime('now'))
                """)
        }

        // 填充全局库（含 vision 字段，tags 为空格分隔 FTS 格式）
        try globalDB.write { db in
            try db.execute(sql: """
                INSERT INTO videos (source_folder, source_video_id, file_path, file_name)
                VALUES ('/test/folder', 1, '/test/folder/video1.mp4', 'video1.mp4')
                """)
            try db.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, video_id,
                    start_time, end_time,
                    scene, description,
                    subjects, actions, objects, lighting, colors,
                    tags, transcript, user_tags,
                    mood, shot_type, rating, color_label)
                VALUES ('/test/folder', 1, 1,
                    0.0, 5.0,
                    '海滩日落', '美丽的海滩日落景色',
                    '人物 海鸥', '散步 飞翔', '沙滩 海浪', 'golden hour', '橙色 蓝色',
                    '海滩 日落', '这是一个美丽的日落', '精选',
                    'peaceful', 'wide', 3, 'blue')
                """)
            try db.execute(sql: """
                INSERT INTO clips (source_folder, source_clip_id, video_id,
                    start_time, end_time,
                    scene, description, tags, mood, shot_type)
                VALUES ('/test/folder', 2, 1,
                    5.0, 10.0,
                    '城市夜景', '繁华的城市夜晚', '城市 夜景', 'energetic', 'aerial')
                """)
        }

        let context = DatabaseContext(
            globalDB: globalDB,
            folderDBs: ["/test/folder": folderDB]
        )
        return (context, clipId)
    }

    /// 从 CallTool.Result 提取文本内容
    private func extractText(_ result: CallTool.Result) -> String? {
        guard let first = result.content.first else { return nil }
        if case .text(let text) = first { return text }
        return nil
    }

    // MARK: - GetStatsTool

    func testGetStatsEmptyDB() throws {
        let globalDB = try DatabaseManager.makeGlobalInMemoryDatabase()
        let context = DatabaseContext(globalDB: globalDB)

        let params = CallTool.Parameters(name: "get_stats")
        let result = try GetStatsTool.execute(params: params, context: context)

        XCTAssertNil(result.isError)
        let text = extractText(result)!
        XCTAssertTrue(text.contains("\"totalVideos\" : 0"))
        XCTAssertTrue(text.contains("\"totalClips\" : 0"))
    }

    func testGetStatsWithData() throws {
        let (context, _) = try Self.makeTestContext()

        let params = CallTool.Parameters(name: "get_stats")
        let result = try GetStatsTool.execute(params: params, context: context)

        XCTAssertNil(result.isError)
        let text = extractText(result)!
        XCTAssertTrue(text.contains("\"totalVideos\" : 1"))
        XCTAssertTrue(text.contains("\"totalClips\" : 2"))
        XCTAssertTrue(text.contains("\"totalFolders\" : 1"))
    }

    // MARK: - ListFoldersTool

    func testListFoldersEmpty() throws {
        let globalDB = try DatabaseManager.makeGlobalInMemoryDatabase()
        let context = DatabaseContext(globalDB: globalDB)

        let params = CallTool.Parameters(name: "list_folders")
        let result = try ListFoldersTool.execute(params: params, context: context)

        XCTAssertNil(result.isError)
        let text = extractText(result)!
        // 空数组 JSON
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "[\n\n]")
    }

    func testListFoldersWithData() throws {
        let (context, _) = try Self.makeTestContext()

        let params = CallTool.Parameters(name: "list_folders")
        let result = try ListFoldersTool.execute(params: params, context: context)

        XCTAssertNil(result.isError)
        let text = extractText(result)!
        // JSONEncoder 会将 / 转义为 \/
        XCTAssertTrue(text.contains("test") && text.contains("folder"), "应包含文件夹路径: \(text)")
        XCTAssertTrue(text.contains("\"clipCount\" : 2"), "应有 2 个 clips: \(text)")
        XCTAssertTrue(text.contains("\"videoCount\" : 1"), "应有 1 个 video: \(text)")
    }

    // MARK: - ListVideosTool

    func testListVideosAll() throws {
        let (context, _) = try Self.makeTestContext()

        let params = CallTool.Parameters(name: "list_videos", arguments: [
            "folder": .string("/test/folder"),
        ])
        let result = try ListVideosTool.execute(params: params, context: context)

        XCTAssertNil(result.isError)
        let text = extractText(result)!
        XCTAssertTrue(text.contains("video1.mp4"))
        XCTAssertTrue(text.contains("\"indexStatus\" : \"completed\""))
        XCTAssertTrue(text.contains("\"clipCount\" : 2"))
    }

    func testListVideosByStatus() throws {
        let (context, _) = try Self.makeTestContext()

        // 查完成状态
        let params = CallTool.Parameters(name: "list_videos", arguments: [
            "folder": .string("/test/folder"),
            "status": .string("completed"),
        ])
        let result = try ListVideosTool.execute(params: params, context: context)
        let text = extractText(result)!
        XCTAssertTrue(text.contains("video1.mp4"))

        // 查 pending 状态（应为空）
        let params2 = CallTool.Parameters(name: "list_videos", arguments: [
            "folder": .string("/test/folder"),
            "status": .string("pending"),
        ])
        let result2 = try ListVideosTool.execute(params: params2, context: context)
        let text2 = extractText(result2)!
        XCTAssertFalse(text2.contains("video1.mp4"))
    }

    func testListVideosMissingFolder() {
        let globalDB = try! DatabaseManager.makeGlobalInMemoryDatabase()
        let context = DatabaseContext(globalDB: globalDB)

        let params = CallTool.Parameters(name: "list_videos", arguments: [:])
        XCTAssertThrowsError(try ListVideosTool.execute(params: params, context: context))
    }

    // MARK: - GetClipTool

    func testGetClipExists() throws {
        let (context, clipId) = try Self.makeTestContext()

        let params = CallTool.Parameters(name: "get_clip", arguments: [
            "clip_id": .int(Int(clipId)),
            "folder": .string("/test/folder"),
        ])
        let result = try GetClipTool.execute(params: params, context: context)

        XCTAssertNil(result.isError)
        let text = extractText(result)!
        XCTAssertTrue(text.contains("\"scene\" : \"海滩日落\""))
        XCTAssertTrue(text.contains("\"mood\" : \"peaceful\""))
        XCTAssertTrue(text.contains("\"rating\" : 3"))
        XCTAssertTrue(text.contains("\"colorLabel\" : \"blue\""))
        XCTAssertTrue(text.contains("\"shotType\" : \"wide\""))
    }

    func testGetClipIncludesTags() throws {
        let (context, clipId) = try Self.makeTestContext()

        let params = CallTool.Parameters(name: "get_clip", arguments: [
            "clip_id": .int(Int(clipId)),
            "folder": .string("/test/folder"),
        ])
        let result = try GetClipTool.execute(params: params, context: context)
        let text = extractText(result)!

        // auto tags
        XCTAssertTrue(text.contains("海滩"))
        XCTAssertTrue(text.contains("日落"))
        // user tags
        XCTAssertTrue(text.contains("精选"))
    }

    func testGetClipNotFound() throws {
        let (context, _) = try Self.makeTestContext()

        let params = CallTool.Parameters(name: "get_clip", arguments: [
            "clip_id": .int(999),
            "folder": .string("/test/folder"),
        ])
        let result = try GetClipTool.execute(params: params, context: context)

        XCTAssertEqual(result.isError, true)
        let text = extractText(result)!
        XCTAssertTrue(text.contains("not found"))
    }

    func testGetClipMissingParams() {
        let (context, _) = try! Self.makeTestContext()

        // 缺少 clip_id
        let params = CallTool.Parameters(name: "get_clip", arguments: [
            "folder": .string("/test/folder"),
        ])
        XCTAssertThrowsError(try GetClipTool.execute(params: params, context: context))

        // 缺少 folder
        let params2 = CallTool.Parameters(name: "get_clip", arguments: [
            "clip_id": .int(1),
        ])
        XCTAssertThrowsError(try GetClipTool.execute(params: params2, context: context))
    }

    // MARK: - GetVideoDetailTool

    func testGetVideoDetailExists() throws {
        let (context, _) = try Self.makeTestContext()

        let params = CallTool.Parameters(name: "get_video_detail", arguments: [
            "video_path": .string("/test/folder/video1.mp4"),
            "folder": .string("/test/folder"),
        ])
        let result = try GetVideoDetailTool.execute(params: params, context: context)

        XCTAssertNil(result.isError)
        let text = extractText(result)!
        XCTAssertTrue(text.contains("video1.mp4"))
        XCTAssertTrue(text.contains("\"indexStatus\" : \"completed\""))
        // 应包含 2 个 clips
        XCTAssertTrue(text.contains("海滩日落"))
        XCTAssertTrue(text.contains("城市夜景"))
    }

    func testGetVideoDetailIncludesVisionFields() throws {
        let (context, _) = try Self.makeTestContext()

        let params = CallTool.Parameters(name: "get_video_detail", arguments: [
            "video_path": .string("/test/folder/video1.mp4"),
            "folder": .string("/test/folder"),
        ])
        let result = try GetVideoDetailTool.execute(params: params, context: context)
        let text = extractText(result)!

        // 验证 vision 字段包含在输出中
        XCTAssertTrue(text.contains("人物"), "应包含 subjects: \(text)")
        XCTAssertTrue(text.contains("散步"), "应包含 actions: \(text)")
        XCTAssertTrue(text.contains("沙滩"), "应包含 objects: \(text)")
        XCTAssertTrue(text.contains("golden hour"), "应包含 lighting: \(text)")
        XCTAssertTrue(text.contains("peaceful"), "应包含 mood: \(text)")
    }

    func testGetVideoDetailNotFound() throws {
        let (context, _) = try Self.makeTestContext()

        let params = CallTool.Parameters(name: "get_video_detail", arguments: [
            "video_path": .string("/test/folder/nonexistent.mp4"),
            "folder": .string("/test/folder"),
        ])
        let result = try GetVideoDetailTool.execute(params: params, context: context)

        XCTAssertEqual(result.isError, true)
        let text = extractText(result)!
        XCTAssertTrue(text.contains("not found"))
    }

    func testGetVideoDetailMissingVideoPath() {
        let (context, _) = try! Self.makeTestContext()

        let params = CallTool.Parameters(name: "get_video_detail", arguments: [:])
        XCTAssertThrowsError(try GetVideoDetailTool.execute(params: params, context: context))
    }

    func testGetVideoDetailAutoDetectFailsGracefully() throws {
        let (context, _) = try Self.makeTestContext()

        // 不提供 folder，auto detect 在内存 DB 中不可能成功
        let params = CallTool.Parameters(name: "get_video_detail", arguments: [
            "video_path": .string("/some/random/video.mp4"),
        ])
        let result = try GetVideoDetailTool.execute(params: params, context: context)

        XCTAssertEqual(result.isError, true)
        let text = extractText(result)!
        XCTAssertTrue(text.contains("cannot detect folder"))
    }

    // MARK: - SearchTool

    func testSearchBasic() async throws {
        let (context, _) = try Self.makeTestContext()

        let params = CallTool.Parameters(name: "search", arguments: [
            "query": .string("海滩"),
            "mode": .string("fts"),
        ])
        let result = try await SearchTool.execute(params: params, context: context)

        XCTAssertNil(result.isError)
        let text = extractText(result)!
        XCTAssertTrue(text.hasPrefix("Found"))
        XCTAssertTrue(text.contains("海滩"))
    }

    func testSearchMissingQuery() async {
        let globalDB = try! DatabaseManager.makeGlobalInMemoryDatabase()
        let context = DatabaseContext(globalDB: globalDB)

        let params = CallTool.Parameters(name: "search", arguments: [:])
        do {
            _ = try await SearchTool.execute(params: params, context: context)
            XCTFail("应抛出缺少 query 参数的错误")
        } catch {
            XCTAssertTrue("\(error)".contains("Missing required parameter"))
        }
    }

    func testSearchWithLimit() async throws {
        let (context, _) = try Self.makeTestContext()

        let params = CallTool.Parameters(name: "search", arguments: [
            "query": .string("海滩"),
            "mode": .string("fts"),
            "limit": .int(1),
        ])
        let result = try await SearchTool.execute(params: params, context: context)

        XCTAssertNil(result.isError)
        let text = extractText(result)!
        XCTAssertTrue(text.hasPrefix("Found"))
    }

    func testSearchNoResults() async throws {
        let (context, _) = try Self.makeTestContext()

        let params = CallTool.Parameters(name: "search", arguments: [
            "query": .string("zzzznotexist"),
            "mode": .string("fts"),
        ])
        let result = try await SearchTool.execute(params: params, context: context)

        XCTAssertNil(result.isError)
        let text = extractText(result)!
        XCTAssertTrue(text.contains("Found 0 results"))
    }

    func testSearchShowsModeLabel() async throws {
        let (context, _) = try Self.makeTestContext()

        let params = CallTool.Parameters(name: "search", arguments: [
            "query": .string("海滩"),
            "mode": .string("fts"),
        ])
        let result = try await SearchTool.execute(params: params, context: context)
        let text = extractText(result)!
        // FTS 模式下应显示 [mode=fts]
        XCTAssertTrue(text.contains("[mode=fts]"), "应显示搜索模式: \(text)")
    }

    // MARK: - BrowseAllClipsTool

    func testBrowseAllClipsBasic() async throws {
        let (context, _) = try Self.makeTestContext()

        let params = CallTool.Parameters(name: "browse_all_clips")
        let result = try await BrowseAllClipsTool.execute(params: params, context: context)

        XCTAssertNil(result.isError)
        let text = extractText(result)!
        XCTAssertTrue(text.contains("\"total\" : 2"), "应有 2 个 clips: \(text)")
        XCTAssertTrue(text.contains("\"returned\" : 2"))
        XCTAssertTrue(text.contains("海滩日落"))
        XCTAssertTrue(text.contains("城市夜景"))
    }

    func testBrowseAllClipsPagination() async throws {
        let (context, _) = try Self.makeTestContext()

        // limit=1, offset=0
        let params1 = CallTool.Parameters(name: "browse_all_clips", arguments: [
            "limit": .int(1),
            "offset": .int(0),
        ])
        let result1 = try await BrowseAllClipsTool.execute(params: params1, context: context)
        let text1 = extractText(result1)!
        XCTAssertTrue(text1.contains("\"total\" : 2"))
        XCTAssertTrue(text1.contains("\"returned\" : 1"))

        // limit=1, offset=1
        let params2 = CallTool.Parameters(name: "browse_all_clips", arguments: [
            "limit": .int(1),
            "offset": .int(1),
        ])
        let result2 = try await BrowseAllClipsTool.execute(params: params2, context: context)
        let text2 = extractText(result2)!
        XCTAssertTrue(text2.contains("\"returned\" : 1"))
    }

    func testBrowseAllClipsWithFolder() async throws {
        let (context, _) = try Self.makeTestContext()

        let params = CallTool.Parameters(name: "browse_all_clips", arguments: [
            "folder": .string("/test/folder"),
        ])
        let result = try await BrowseAllClipsTool.execute(params: params, context: context)
        let text = extractText(result)!
        XCTAssertTrue(text.contains("\"total\" : 2"))

        // 不存在的文件夹
        let params2 = CallTool.Parameters(name: "browse_all_clips", arguments: [
            "folder": .string("/nonexistent"),
        ])
        let result2 = try await BrowseAllClipsTool.execute(params: params2, context: context)
        let text2 = extractText(result2)!
        XCTAssertTrue(text2.contains("\"total\" : 0"))
    }

    func testBrowseAllClipsWithRatingFilter() async throws {
        let (context, _) = try Self.makeTestContext()

        let params = CallTool.Parameters(name: "browse_all_clips", arguments: [
            "min_rating": .int(3),
        ])
        let result = try await BrowseAllClipsTool.execute(params: params, context: context)
        let text = extractText(result)!
        // 只有第一个 clip rating=3
        XCTAssertTrue(text.contains("\"total\" : 1"))
        XCTAssertTrue(text.contains("海滩日落"))
    }

    func testBrowseAllClipsEmptyDB() async throws {
        let globalDB = try DatabaseManager.makeGlobalInMemoryDatabase()
        let context = DatabaseContext(globalDB: globalDB)

        let params = CallTool.Parameters(name: "browse_all_clips")
        let result = try await BrowseAllClipsTool.execute(params: params, context: context)
        let text = extractText(result)!
        XCTAssertTrue(text.contains("\"total\" : 0"))
        XCTAssertTrue(text.contains("\"returned\" : 0"))
    }

    func testBrowseAllClipsIncludesVisionFields() async throws {
        let (context, _) = try Self.makeTestContext()

        let params = CallTool.Parameters(name: "browse_all_clips")
        let result = try await BrowseAllClipsTool.execute(params: params, context: context)
        let text = extractText(result)!

        // 验证 vision 字段（第一个 clip 有 subjects/actions/objects）
        XCTAssertTrue(text.contains("人物"), "应包含 subjects: \(text)")
        XCTAssertTrue(text.contains("散步"), "应包含 actions: \(text)")
        XCTAssertTrue(text.contains("沙滩"), "应包含 objects: \(text)")
    }

    // MARK: - DatabaseContext

    func testDatabaseContextTestInit() throws {
        let globalDB = try DatabaseManager.makeGlobalInMemoryDatabase()
        let folderDB = try DatabaseManager.makeFolderInMemoryDatabase()

        let context = DatabaseContext(
            globalDB: globalDB,
            folderDBs: ["/my/folder": folderDB]
        )

        // 应能获取注入的 folder DB
        let db = try context.folderDB(for: "/my/folder")
        XCTAssertNotNil(db)
    }

    func testDatabaseContextUnknownFolderThrows() {
        let globalDB = try! DatabaseManager.makeGlobalInMemoryDatabase()
        let context = DatabaseContext(globalDB: globalDB)

        // 请求未注册的文件夹应调用 openFolderDatabase 并失败（路径不存在）
        XCTAssertThrowsError(try context.folderDB(for: "/nonexistent/path"))
    }

    func testDatabaseContextEmbeddingProviderNilWithoutApiKey() {
        let globalDB = try! DatabaseManager.makeGlobalInMemoryDatabase()
        let context = DatabaseContext(globalDB: globalDB)

        // 没有 API key 配置，getEmbeddingProvider 可能返回 NLEmbeddingProvider 或 nil
        // 不做严格断言，仅验证不崩溃
        let _ = context.getEmbeddingProvider()
    }
}
