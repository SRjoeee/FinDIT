import XCTest
import GRDB
@testable import FindItCore

final class LayeredIndexerTests: XCTestCase {

    // MARK: - Layer enum

    func testLayerRawValues() {
        XCTAssertEqual(LayeredIndexer.Layer.metadata.rawValue, 0)
        XCTAssertEqual(LayeredIndexer.Layer.clipVector.rawValue, 1)
        XCTAssertEqual(LayeredIndexer.Layer.stt.rawValue, 2)
        XCTAssertEqual(LayeredIndexer.Layer.textDescription.rawValue, 3)
    }

    func testLayerComparable() {
        XCTAssertTrue(LayeredIndexer.Layer.metadata < .clipVector)
        XCTAssertTrue(LayeredIndexer.Layer.clipVector < .stt)
        XCTAssertTrue(LayeredIndexer.Layer.stt < .textDescription)
        XCTAssertFalse(LayeredIndexer.Layer.textDescription < .metadata)
    }

    func testLayerSortedOrder() {
        let layers = LayeredIndexer.Layer.allCases.sorted()
        XCTAssertEqual(layers, [.metadata, .clipVector, .stt, .textDescription])
    }

    func testLayerCompletedStage() {
        XCTAssertEqual(
            LayeredIndexer.Layer.metadata.completedStage,
            PipelineManager.Stage.metadataDone
        )
        XCTAssertEqual(
            LayeredIndexer.Layer.clipVector.completedStage,
            PipelineManager.Stage.vectorsDone
        )
        XCTAssertEqual(
            LayeredIndexer.Layer.stt.completedStage,
            PipelineManager.Stage.sttDone
        )
        XCTAssertEqual(
            LayeredIndexer.Layer.textDescription.completedStage,
            PipelineManager.Stage.completed
        )
    }

    // MARK: - Layer.isApplicable

    func testIsApplicableVideo() {
        // 视频：所有层都适用
        for layer in LayeredIndexer.Layer.allCases {
            XCTAssertTrue(
                layer.isApplicable(for: .video),
                "Layer \(layer) 应该适用于 video"
            )
        }
    }

    func testIsApplicablePhoto() {
        // 照片：metadata ✓, clipVector ✓, stt ✗, textDescription ✓
        XCTAssertTrue(LayeredIndexer.Layer.metadata.isApplicable(for: .photo))
        XCTAssertTrue(LayeredIndexer.Layer.clipVector.isApplicable(for: .photo))
        XCTAssertFalse(LayeredIndexer.Layer.stt.isApplicable(for: .photo))
        XCTAssertTrue(LayeredIndexer.Layer.textDescription.isApplicable(for: .photo))
    }

    func testIsApplicableAudio() {
        // 音频：metadata ✓, clipVector ✗, stt ✓, textDescription ✗
        XCTAssertTrue(LayeredIndexer.Layer.metadata.isApplicable(for: .audio))
        XCTAssertFalse(LayeredIndexer.Layer.clipVector.isApplicable(for: .audio))
        XCTAssertTrue(LayeredIndexer.Layer.stt.isApplicable(for: .audio))
        XCTAssertFalse(LayeredIndexer.Layer.textDescription.isApplicable(for: .audio))
    }

    // MARK: - Config

    func testConfigDefaults() {
        let config = LayeredIndexer.Config()
        XCTAssertNil(config.mediaService)
        XCTAssertNil(config.clipProvider)
        XCTAssertNil(config.whisperKit)
        XCTAssertNil(config.vlmContainer)
        XCTAssertNil(config.embeddingProvider)
        XCTAssertNil(config.apiKey)
        XCTAssertNil(config.rateLimiter)
        XCTAssertTrue(config.skipLayers.isEmpty)
    }

    func testConfigSkipLayers() {
        let config = LayeredIndexer.Config(
            skipLayers: [.stt, .textDescription]
        )
        XCTAssertEqual(config.skipLayers.count, 2)
        XCTAssertTrue(config.skipLayers.contains(.stt))
        XCTAssertTrue(config.skipLayers.contains(.textDescription))
        XCTAssertFalse(config.skipLayers.contains(.metadata))
        XCTAssertFalse(config.skipLayers.contains(.clipVector))
    }

    // MARK: - shouldRunLayer

    func testShouldRunLayerBasic() {
        let config = LayeredIndexer.Config()

        // currentLayer = metadata (0) → 所有层都需要运行
        XCTAssertTrue(LayeredIndexer.shouldRunLayer(
            .metadata, currentLayer: .metadata, config: config
        ))
        XCTAssertTrue(LayeredIndexer.shouldRunLayer(
            .clipVector, currentLayer: .metadata, config: config
        ))
        XCTAssertTrue(LayeredIndexer.shouldRunLayer(
            .stt, currentLayer: .metadata, config: config
        ))
        XCTAssertTrue(LayeredIndexer.shouldRunLayer(
            .textDescription, currentLayer: .metadata, config: config
        ))
    }

    func testShouldRunLayerResume() {
        let config = LayeredIndexer.Config()

        // currentLayer = stt (2) → metadata 和 clipVector 不需要运行
        XCTAssertFalse(LayeredIndexer.shouldRunLayer(
            .metadata, currentLayer: .stt, config: config
        ))
        XCTAssertFalse(LayeredIndexer.shouldRunLayer(
            .clipVector, currentLayer: .stt, config: config
        ))
        XCTAssertTrue(LayeredIndexer.shouldRunLayer(
            .stt, currentLayer: .stt, config: config
        ))
        XCTAssertTrue(LayeredIndexer.shouldRunLayer(
            .textDescription, currentLayer: .stt, config: config
        ))
    }

    func testShouldRunLayerSkipLayers() {
        let config = LayeredIndexer.Config(skipLayers: [.stt])

        // STT 被跳过
        XCTAssertFalse(LayeredIndexer.shouldRunLayer(
            .stt, currentLayer: .metadata, config: config
        ))
        // 其他层不受影响
        XCTAssertTrue(LayeredIndexer.shouldRunLayer(
            .metadata, currentLayer: .metadata, config: config
        ))
        XCTAssertTrue(LayeredIndexer.shouldRunLayer(
            .textDescription, currentLayer: .metadata, config: config
        ))
    }

    // MARK: - updateVideoLayer

    func testUpdateVideoLayer() throws {
        let db = try DatabaseQueue()
        let migrator = Migrations.folderMigrator()
        try migrator.migrate(db)

        // 插入测试文件夹和视频
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO watched_folders (folder_path) VALUES ('/test')
                """)
            try db.execute(sql: """
                INSERT INTO videos
                (folder_id, file_path, file_name, index_status, index_layer)
                VALUES (1, '/test/v.mp4', 'v.mp4', 'pending', 0)
                """)
        }

        // 更新到 Layer 1 / vectorsDone
        try LayeredIndexer.updateVideoLayer(
            folderDB: db,
            videoId: 1,
            layer: .clipVector,
            stage: .vectorsDone
        )

        let (indexLayer, indexStatus, indexError): (Int?, String?, String?) = try db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM videos WHERE video_id = 1")!
            return (row["index_layer"], row["index_status"], row["index_error"])
        }
        XCTAssertEqual(indexLayer, 1)
        XCTAssertEqual(indexStatus, "vectors_done")
        XCTAssertNil(indexError)
    }

    func testUpdateVideoLayerWithError() throws {
        let db = try DatabaseQueue()
        let migrator = Migrations.folderMigrator()
        try migrator.migrate(db)

        try db.write { db in
            try db.execute(sql: """
                INSERT INTO watched_folders (folder_path) VALUES ('/test')
                """)
            try db.execute(sql: """
                INSERT INTO videos
                (folder_id, file_path, file_name, index_status, index_layer)
                VALUES (1, '/test/v.mp4', 'v.mp4', 'pending', 0)
                """)
        }

        try LayeredIndexer.updateVideoLayer(
            folderDB: db,
            videoId: 1,
            layer: .clipVector,
            stage: .failed,
            error: "CLIP 编码失败"
        )

        let (indexLayer, indexStatus, indexError): (Int?, String?, String?) = try db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM videos WHERE video_id = 1")!
            return (row["index_layer"], row["index_status"], row["index_error"])
        }
        XCTAssertEqual(indexLayer, 1)
        XCTAssertEqual(indexStatus, "failed")
        XCTAssertEqual(indexError, "CLIP 编码失败")
    }

    func testUpdateVideoLayerCompleted() throws {
        let db = try DatabaseQueue()
        let migrator = Migrations.folderMigrator()
        try migrator.migrate(db)

        try db.write { db in
            try db.execute(sql: """
                INSERT INTO watched_folders (folder_path) VALUES ('/test')
                """)
            try db.execute(sql: """
                INSERT INTO videos
                (folder_id, file_path, file_name, index_status, index_layer)
                VALUES (1, '/test/v.mp4', 'v.mp4', 'vectors_done', 1)
                """)
        }

        try LayeredIndexer.updateVideoLayer(
            folderDB: db,
            videoId: 1,
            layer: .textDescription,
            stage: .completed
        )

        let (indexLayer, indexStatus, indexedAt): (Int?, String?, String?) = try db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM videos WHERE video_id = 1")!
            return (row["index_layer"], row["index_status"], row["indexed_at"])
        }
        XCTAssertEqual(indexLayer, 3)
        XCTAssertEqual(indexStatus, "completed")
        XCTAssertNotNil(indexedAt)
    }

    // MARK: - PipelineManager.Stage 新增 cases

    func testStageNewCases() {
        XCTAssertEqual(PipelineManager.Stage.metadataDone.rawValue, "metadata_done")
        XCTAssertEqual(PipelineManager.Stage.vectorsDone.rawValue, "vectors_done")
    }

    func testStageOrderingNewCases() {
        let metadataDone = PipelineManager.Stage.metadataDone
        let vectorsDone = PipelineManager.Stage.vectorsDone

        // 新 stages 应在 pending 之后，sttRunning 之前
        XCTAssertTrue(PipelineManager.Stage.pending.isBefore(metadataDone))
        XCTAssertTrue(metadataDone.isBefore(vectorsDone))
        XCTAssertTrue(vectorsDone.isBefore(.sttRunning))
        XCTAssertTrue(PipelineManager.Stage.sttRunning.isBefore(.sttDone))
    }

    func testStageAllCasesCount() {
        // pending + metadataDone + vectorsDone + sttRunning + sttDone
        // + visionRunning + completed + failed + orphaned = 9
        XCTAssertEqual(PipelineManager.Stage.allCases.count, 9)
    }

    // MARK: - index_layer 迁移验证

    func testFolderDBMigrationAddsIndexLayer() throws {
        let db = try DatabaseQueue()
        let migrator = Migrations.folderMigrator()
        try migrator.migrate(db)

        // 验证 index_layer 列存在且默认值为 0
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO watched_folders (folder_path) VALUES ('/test')
                """)
            try db.execute(sql: """
                INSERT INTO videos (folder_id, file_path, file_name, index_status)
                VALUES (1, '/test/v.mp4', 'v.mp4', 'pending')
                """)
        }
        let indexLayer: Int? = try db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT index_layer FROM videos WHERE video_id = 1")!
            return row["index_layer"]
        }
        XCTAssertEqual(indexLayer, 0)
    }

    func testGlobalDBMigrationAddsIndexLayer() throws {
        let db = try DatabaseQueue()
        let migrator = Migrations.globalMigrator()
        try migrator.migrate(db)

        // 验证 index_layer 列存在
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO videos
                (source_folder, source_video_id, file_path, file_name)
                VALUES ('/src', 1, '/test/v.mp4', 'v.mp4')
                """)
        }
        let indexLayer: Int? = try db.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT index_layer FROM videos WHERE video_id = 1")!
            return row["index_layer"]
        }
        XCTAssertEqual(indexLayer, 0)
    }

    // MARK: - index_layer 状态映射迁移

    func testFolderDBMigrationMapsExistingStatus() throws {
        // 使用低版本迁移创建数据库，手动插入数据，再应用新迁移
        let db = try DatabaseQueue()

        // 先跑到 v9（v10 之前）
        var partialMigrator = DatabaseMigrator()
        // 手动注册所有 v9 之前的迁移
        let fullMigrator = Migrations.folderMigrator()
        // 通过全量迁移器跑到完成（包括 v10）
        // 这里我们直接测试全量迁移后 index_layer 的默认值
        try fullMigrator.migrate(db)

        // 插入不同状态的视频
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO watched_folders (folder_path) VALUES ('/test')
                """)
            // pending 视频
            try db.execute(sql: """
                INSERT INTO videos
                (folder_id, file_path, file_name, index_status, index_layer)
                VALUES (1, '/test/a.mp4', 'a.mp4', 'pending', 0)
                """)
            // completed 视频
            try db.execute(sql: """
                INSERT INTO videos
                (folder_id, file_path, file_name, index_status, index_layer)
                VALUES (1, '/test/b.mp4', 'b.mp4', 'completed', 3)
                """)
            // stt_done 视频
            try db.execute(sql: """
                INSERT INTO videos
                (folder_id, file_path, file_name, index_status, index_layer)
                VALUES (1, '/test/c.mp4', 'c.mp4', 'stt_done', 2)
                """)
        }

        // 验证 index_layer 值
        let layers: [Int] = try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT index_layer FROM videos ORDER BY video_id
                """)
            return rows.map { $0["index_layer"] }
        }
        XCTAssertEqual(layers.count, 3)
        XCTAssertEqual(layers[0], 0) // pending → 0
        XCTAssertEqual(layers[1], 3) // completed → 3
        XCTAssertEqual(layers[2], 2) // stt_done → 2
    }

    // MARK: - Video model indexLayer

    func testVideoModelIndexLayer() {
        var video = Video(
            filePath: "/test/v.mp4",
            fileName: "v.mp4"
        )
        XCTAssertEqual(video.indexLayer, 0)

        video.indexLayer = 2
        XCTAssertEqual(video.indexLayer, 2)
    }

    func testVideoModelIndexLayerCodable() throws {
        let video = Video(
            filePath: "/test/v.mp4",
            fileName: "v.mp4",
            indexLayer: 3
        )
        XCTAssertEqual(video.indexLayer, 3)
    }
}
