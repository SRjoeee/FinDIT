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

        // Stage 5b: file_hash 列已在 v1 schema 中存在，此处仅添加索引
        migrator.registerMigration("v6_addFileHashIndex") { db in
            try db.create(
                index: "idx_videos_file_hash",
                on: "videos",
                columns: ["file_hash"],
                ifNotExists: true
            )
        }

        // Stage 5c: 用户自定义标签
        migrator.registerMigration("v7_addUserTags") { db in
            try db.alter(table: "clips") { t in
                t.add(column: "user_tags", .text)
            }
        }

        // Stage 5d: 星级评分 & 颜色标签
        migrator.registerMigration("v8_addRatingColorLabel") { db in
            try db.alter(table: "clips") { t in
                t.add(column: "rating", .integer).defaults(to: 0)
                t.add(column: "color_label", .text)
            }
            try db.create(
                index: "idx_clips_rating",
                on: "clips",
                columns: ["rating"]
            )
            try db.create(
                index: "idx_clips_color_label",
                on: "clips",
                columns: ["color_label"]
            )
        }

        // R2b: CLIP 向量存储表（Source of truth，USearch 索引可从此重建）
        migrator.registerMigration("v9_addClipVectors") { db in
            try db.create(table: "clip_vectors") { t in
                t.autoIncrementedPrimaryKey("vector_id")
                t.column("clip_id", .integer).notNull()
                    .references("clips", onDelete: .cascade)
                t.column("model_name", .text).notNull()
                t.column("dimensions", .integer).notNull()
                t.column("vector", .blob).notNull()
                t.column("created_at", .text)
                    .notNull()
                    .defaults(sql: "(datetime('now'))")
                t.uniqueKey(["clip_id", "model_name"])
            }
            try db.create(
                index: "idx_clip_vectors_model",
                on: "clip_vectors",
                columns: ["model_name"]
            )
        }

        // R3: 分层索引 — 添加 index_layer 列
        migrator.registerMigration("v10_addIndexLayer") { db in
            try db.alter(table: "videos") { t in
                t.add(column: "index_layer", .integer).defaults(to: 0)
            }
            // 映射现有 index_status 到 index_layer
            try db.execute(sql: """
                UPDATE videos SET index_layer = CASE
                    WHEN index_status = 'completed' THEN 3
                    WHEN index_status IN ('stt_done', 'vision_running') THEN 2
                    WHEN index_status = 'stt_running' THEN 1
                    ELSE 0
                END
            """)
        }

        // R1: MediaService — 添加 media_type 列
        migrator.registerMigration("v11_addMediaType") { db in
            try db.alter(table: "videos") { t in
                t.add(column: "media_type", .text).defaults(to: "video")
            }
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

        // Stage 5b: 全局库 videos 表添加 file_hash 列
        migrator.registerMigration("v5_addFileHashToGlobalVideos") { db in
            try db.alter(table: "videos") { t in
                t.add(column: "file_hash", .text)
            }
        }

        // Stage 5c: 用户标签 + FTS5 重建（加入 user_tags 列）
        migrator.registerMigration("v6_addUserTagsAndRebuildFTS") { db in
            // 添加 user_tags 列
            try db.alter(table: "clips") { t in
                t.add(column: "user_tags", .text)
            }

            // 删除旧触发器
            try db.execute(sql: "DROP TRIGGER IF EXISTS clips_fts_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS clips_fts_bd")
            try db.execute(sql: "DROP TRIGGER IF EXISTS clips_fts_bu")
            try db.execute(sql: "DROP TRIGGER IF EXISTS clips_fts_au")

            // 删除旧 FTS5 表
            try db.execute(sql: "DROP TABLE IF EXISTS clips_fts")

            // 重建 FTS5（加入 user_tags）
            try db.execute(sql: """
                CREATE VIRTUAL TABLE clips_fts USING fts5(
                    tags,
                    description,
                    transcript,
                    user_tags,
                    content='clips',
                    content_rowid='clip_id'
                )
                """)

            // 重建触发器（加入 user_tags）
            try db.execute(sql: """
                CREATE TRIGGER clips_fts_ai AFTER INSERT ON clips BEGIN
                    INSERT INTO clips_fts(rowid, tags, description, transcript, user_tags)
                    VALUES (new.clip_id, new.tags, new.description, new.transcript, new.user_tags);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER clips_fts_bd BEFORE DELETE ON clips BEGIN
                    INSERT INTO clips_fts(clips_fts, rowid, tags, description, transcript, user_tags)
                    VALUES ('delete', old.clip_id, old.tags, old.description, old.transcript, old.user_tags);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER clips_fts_bu BEFORE UPDATE ON clips BEGIN
                    INSERT INTO clips_fts(clips_fts, rowid, tags, description, transcript, user_tags)
                    VALUES ('delete', old.clip_id, old.tags, old.description, old.transcript, old.user_tags);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER clips_fts_au AFTER UPDATE ON clips BEGIN
                    INSERT INTO clips_fts(rowid, tags, description, transcript, user_tags)
                    VALUES (new.clip_id, new.tags, new.description, new.transcript, new.user_tags);
                END
                """)

            // 从现有数据重建 FTS 索引
            try db.execute(sql: "INSERT INTO clips_fts(clips_fts) VALUES('rebuild')")
        }

        // Stage 5d: 星级评分 & 颜色标签
        migrator.registerMigration("v7_addRatingColorLabel") { db in
            try db.alter(table: "clips") { t in
                t.add(column: "rating", .integer).defaults(to: 0)
                t.add(column: "color_label", .text)
            }
            try db.create(
                index: "idx_clips_rating",
                on: "clips",
                columns: ["rating"]
            )
            try db.create(
                index: "idx_clips_color_label",
                on: "clips",
                columns: ["color_label"]
            )
        }

        // Stage 6: sync_meta 持久化卷标识（支持跨重启 UUID 恢复）
        migrator.registerMigration("v8_addSyncMetaVolumeInfo") { db in
            try db.alter(table: "sync_meta") { t in
                t.add(column: "volume_uuid", .text)
                t.add(column: "volume_name", .text)
            }
        }

        // FTS5 索引扩展 — 4 列扩展到 10 列
        //
        // 新增 scene, subjects, actions, objects, mood, shot_type 六个高价值搜索字段。
        // 不含 lighting/colors（搜索价值低，适合 filter/facet）。
        //
        // 同时引入 bm25() 列权重排序，替代默认的等权 rank。
        // 列顺序与权重:
        //   tags(10), description(5), transcript(3), user_tags(8),
        //   scene(4), subjects(3), actions(3), objects(2), mood(2), shot_type(1)
        migrator.registerMigration("v9_expandFTS5Index") { db in
            // 删除旧触发器
            try db.execute(sql: "DROP TRIGGER IF EXISTS clips_fts_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS clips_fts_bd")
            try db.execute(sql: "DROP TRIGGER IF EXISTS clips_fts_bu")
            try db.execute(sql: "DROP TRIGGER IF EXISTS clips_fts_au")

            // 删除旧 FTS5 表
            try db.execute(sql: "DROP TABLE IF EXISTS clips_fts")

            // 重建 FTS5（10 列）
            try db.execute(sql: """
                CREATE VIRTUAL TABLE clips_fts USING fts5(
                    tags,
                    description,
                    transcript,
                    user_tags,
                    scene,
                    subjects,
                    actions,
                    objects,
                    mood,
                    shot_type,
                    content='clips',
                    content_rowid='clip_id'
                )
                """)

            // 重建触发器（10 列）
            try db.execute(sql: """
                CREATE TRIGGER clips_fts_ai AFTER INSERT ON clips BEGIN
                    INSERT INTO clips_fts(rowid, tags, description, transcript, user_tags,
                                          scene, subjects, actions, objects, mood, shot_type)
                    VALUES (new.clip_id, new.tags, new.description, new.transcript, new.user_tags,
                            new.scene, new.subjects, new.actions, new.objects, new.mood, new.shot_type);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER clips_fts_bd BEFORE DELETE ON clips BEGIN
                    INSERT INTO clips_fts(clips_fts, rowid, tags, description, transcript, user_tags,
                                          scene, subjects, actions, objects, mood, shot_type)
                    VALUES ('delete', old.clip_id, old.tags, old.description, old.transcript, old.user_tags,
                            old.scene, old.subjects, old.actions, old.objects, old.mood, old.shot_type);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER clips_fts_bu BEFORE UPDATE ON clips BEGIN
                    INSERT INTO clips_fts(clips_fts, rowid, tags, description, transcript, user_tags,
                                          scene, subjects, actions, objects, mood, shot_type)
                    VALUES ('delete', old.clip_id, old.tags, old.description, old.transcript, old.user_tags,
                            old.scene, old.subjects, old.actions, old.objects, old.mood, old.shot_type);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER clips_fts_au AFTER UPDATE ON clips BEGIN
                    INSERT INTO clips_fts(rowid, tags, description, transcript, user_tags,
                                          scene, subjects, actions, objects, mood, shot_type)
                    VALUES (new.clip_id, new.tags, new.description, new.transcript, new.user_tags,
                            new.scene, new.subjects, new.actions, new.objects, new.mood, new.shot_type);
                END
                """)

            // 从现有数据重建 FTS 索引
            try db.execute(sql: "INSERT INTO clips_fts(clips_fts) VALUES('rebuild')")
        }

        // R2b: CLIP 向量存储表（从文件夹库同步，USearch 索引可从此重建）
        migrator.registerMigration("v10_addClipVectors") { db in
            try db.create(table: "clip_vectors") { t in
                t.autoIncrementedPrimaryKey("vector_id")
                t.column("clip_id", .integer).notNull()
                    .references("clips", onDelete: .cascade)
                t.column("source_folder", .text).notNull()
                t.column("source_vector_id", .integer).notNull()
                t.column("model_name", .text).notNull()
                t.column("dimensions", .integer).notNull()
                t.column("vector", .blob).notNull()
                t.uniqueKey(["source_folder", "source_vector_id"])
            }
            try db.create(
                index: "idx_clip_vectors_clip_id",
                on: "clip_vectors",
                columns: ["clip_id"]
            )
            try db.create(
                index: "idx_clip_vectors_model",
                on: "clip_vectors",
                columns: ["model_name"]
            )
        }

        // R2c: 全局库 clip_vectors 补齐 created_at 列（与文件夹库 v9 对齐）
        migrator.registerMigration("v11_addClipVectorsCreatedAt") { db in
            try db.alter(table: "clip_vectors") { t in
                t.add(column: "created_at", .text).defaults(sql: "(datetime('now'))")
            }
        }

        // R3: 分层索引 — 全局库添加 index_layer 列
        migrator.registerMigration("v12_addIndexLayer") { db in
            try db.alter(table: "videos") { t in
                t.add(column: "index_layer", .integer).defaults(to: 0)
            }
        }

        // R1: MediaService — 添加 media_type 列
        migrator.registerMigration("v13_addMediaType") { db in
            try db.alter(table: "videos") { t in
                t.add(column: "media_type", .text).defaults(to: "video")
            }
        }

        // 补全: 全局 videos 添加 created_at 列
        migrator.registerMigration("v14_addCreatedAt") { db in
            // SQLite ALTER TABLE ADD COLUMN 不支持非常量默认值，
            // 先添加列（默认 NULL），再回填
            try db.alter(table: "videos") { t in
                t.add(column: "created_at", .text)
            }
            try db.execute(sql: "UPDATE videos SET created_at = datetime('now') WHERE created_at IS NULL")
        }

        // 补全: 回填 index_layer（从文件夹库的 index_status 映射）
        migrator.registerMigration("v15_backfillIndexLayer") { db in
            // 全局库的 videos 没有 index_status 列，
            // 将所有 index_layer = 0 且有 clips 的视频标记为已完成（保守策略）
            try db.execute(sql: """
                UPDATE videos SET index_layer = 3
                WHERE index_layer = 0
                  AND video_id IN (SELECT DISTINCT video_id FROM clips)
            """)
        }

        return migrator
    }
}
