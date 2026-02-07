import GRDB

/// 数据库迁移定义
///
/// 提供文件夹级库和全局搜索索引两套迁移。
/// 使用 GRDB 的 `DatabaseMigrator` 版本化迁移机制，
/// 后续版本升级只需追加新的迁移步骤。
public enum Migrations {

    // MARK: - 文件夹级库迁移

    /// 为文件夹级索引数据库注册迁移
    public static func folderMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_createTables") { db in
            // watched_folders 表
            try db.create(table: "watched_folders") { t in
                t.autoIncrementedPrimaryKey("folder_id")
                t.column("folder_path", .text).notNull()
                t.column("volume_name", .text)
                t.column("volume_uuid", .text)
                t.column("is_available", .integer).defaults(to: 1)
                t.column("last_seen_at", .text)
                t.column("total_files", .integer).defaults(to: 0)
                t.column("indexed_files", .integer).defaults(to: 0)
            }

            // videos 表
            try db.create(table: "videos") { t in
                t.autoIncrementedPrimaryKey("video_id")
                t.column("folder_id", .integer)
                    .references("watched_folders", onDelete: .cascade)
                t.column("file_path", .text).notNull().unique()
                t.column("file_name", .text).notNull()
                t.column("duration", .double)
                t.column("file_size", .integer)
                t.column("file_hash", .text)
                t.column("file_modified", .text)
                t.column("created_at", .text)
                t.column("indexed_at", .text)
                t.column("index_status", .text).defaults(to: "pending")
                t.column("index_error", .text)
                t.column("orphaned_at", .text)
                t.column("priority", .integer).defaults(to: 0)
                t.column("last_processed_clip", .integer)
                t.column("srt_path", .text)
            }

            // clips 表
            try db.create(table: "clips") { t in
                t.autoIncrementedPrimaryKey("clip_id")
                t.column("video_id", .integer)
                    .references("videos", onDelete: .cascade)
                t.column("start_time", .double).notNull()
                t.column("end_time", .double).notNull()
                t.column("thumbnail_path", .text)
                t.column("scene", .text)
                t.column("subjects", .text)
                t.column("actions", .text)
                t.column("objects", .text)
                t.column("mood", .text)
                t.column("shot_type", .text)
                t.column("lighting", .text)
                t.column("colors", .text)
                t.column("description", .text)
                t.column("tags", .text)
                t.column("transcript", .text)
                t.column("embedding", .blob)
                t.column("created_at", .text)
                    .notNull()
                    .defaults(sql: "(datetime('now'))")
            }
        }

        migrator.registerMigration("v2_addEmbeddingModel") { db in
            try db.alter(table: "clips") { t in
                t.add(column: "embedding_model", .text)
            }
        }

        migrator.registerMigration("v3_addIndexes") { db in
            // index_status 被 fetchByStatus() 频繁查询，需索引加速
            try db.create(
                index: "idx_videos_index_status",
                on: "videos",
                columns: ["index_status"]
            )
        }

        migrator.registerMigration("v4_addEmbeddingModelIndex") { db in
            try db.create(
                index: "idx_clips_embedding_model",
                on: "clips",
                columns: ["embedding_model"]
            )
        }

        migrator.registerMigration("v5_addClipsVideoIdIndex") { db in
            try db.create(
                index: "idx_clips_video_id",
                on: "clips",
                columns: ["video_id"]
            )
        }

        return migrator
    }

    // MARK: - 全局搜索索引迁移

    /// 为全局搜索索引数据库注册迁移
    public static func globalMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_createTables") { db in
            // 全局 videos 镜像表
            try db.create(table: "videos") { t in
                t.autoIncrementedPrimaryKey("video_id")
                t.column("source_folder", .text).notNull()
                t.column("source_video_id", .integer).notNull()
                t.column("file_path", .text).notNull().unique()
                t.column("file_name", .text).notNull()
                t.column("duration", .double)
                t.column("file_size", .integer)
                t.column("srt_path", .text)
                t.uniqueKey(["source_folder", "source_video_id"])
            }

            // 全局 clips 镜像表
            try db.create(table: "clips") { t in
                t.autoIncrementedPrimaryKey("clip_id")
                t.column("source_folder", .text).notNull()
                t.column("source_clip_id", .integer).notNull()
                t.column("video_id", .integer)
                t.column("start_time", .double).notNull()
                t.column("end_time", .double).notNull()
                t.column("thumbnail_path", .text)
                t.column("scene", .text)
                t.column("subjects", .text)
                t.column("actions", .text)
                t.column("objects", .text)
                t.column("mood", .text)
                t.column("shot_type", .text)
                t.column("lighting", .text)
                t.column("colors", .text)
                t.column("description", .text)
                t.column("tags", .text)
                t.column("transcript", .text)
                t.column("embedding", .blob)
                t.uniqueKey(["source_folder", "source_clip_id"])
            }

            // FTS5 全文搜索虚拟表
            try db.execute(sql: """
                CREATE VIRTUAL TABLE clips_fts USING fts5(
                    tags,
                    description,
                    transcript,
                    content='clips',
                    content_rowid='clip_id'
                )
                """)

            // FTS5 同步触发器（外部内容表需手动维护索引）
            try db.execute(sql: """
                CREATE TRIGGER clips_fts_ai AFTER INSERT ON clips BEGIN
                    INSERT INTO clips_fts(rowid, tags, description, transcript)
                    VALUES (new.clip_id, new.tags, new.description, new.transcript);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER clips_fts_bd BEFORE DELETE ON clips BEGIN
                    INSERT INTO clips_fts(clips_fts, rowid, tags, description, transcript)
                    VALUES ('delete', old.clip_id, old.tags, old.description, old.transcript);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER clips_fts_bu BEFORE UPDATE ON clips BEGIN
                    INSERT INTO clips_fts(clips_fts, rowid, tags, description, transcript)
                    VALUES ('delete', old.clip_id, old.tags, old.description, old.transcript);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER clips_fts_au AFTER UPDATE ON clips BEGIN
                    INSERT INTO clips_fts(rowid, tags, description, transcript)
                    VALUES (new.clip_id, new.tags, new.description, new.transcript);
                END
                """)

            // 搜索历史表
            try db.create(table: "search_history") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("query", .text).notNull()
                t.column("searched_at", .text)
                    .notNull()
                    .defaults(sql: "(datetime('now'))")
                t.column("result_count", .integer).defaults(to: 0)
            }

            // 同步元数据表
            try db.create(table: "sync_meta") { t in
                t.column("folder_path", .text).notNull().primaryKey()
                t.column("last_synced_clip_rowid", .integer).defaults(to: 0)
                t.column("last_synced_video_rowid", .integer).defaults(to: 0)
                t.column("last_synced_at", .text)
            }
        }

        migrator.registerMigration("v2_addEmbeddingModel") { db in
            try db.alter(table: "clips") { t in
                t.add(column: "embedding_model", .text)
            }
        }

        migrator.registerMigration("v3_addEmbeddingModelIndex") { db in
            try db.create(
                index: "idx_clips_embedding_model",
                on: "clips",
                columns: ["embedding_model"]
            )
        }

        migrator.registerMigration("v4_addClipsVideoIdIndex") { db in
            try db.create(
                index: "idx_clips_video_id",
                on: "clips",
                columns: ["video_id"]
            )
        }

        return migrator
    }
}
