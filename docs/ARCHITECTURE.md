# FindIt 技术架构

## 分层架构

```
┌─────────────────────────────────────────────┐
│           macOS App (SwiftUI)               │  ← Stage 4
│          搜索框 · 网格 · 侧边栏 · 预览       │
├─────────────────────────────────────────────┤
│           FindItCLI (验证层)                 │  ← Stage 0-3
│          子命令入口 · 结果格式化               │
├─────────────────────────────────────────────┤
│           FindItCore (核心库)                │
│                                             │
│   ┌────────────┐  ┌───────────────────┐    │
│   │SearchEngine │  │  PipelineManager  │    │
│   │ FTS5+向量   │  │  调度 STT/视觉管线 │    │
│   │ VectorStore │  │  IndexingScheduler│    │
│   └──────┬─────┘  └─────────┬─────────┘    │
│          │                   │               │
│   ┌──────┴─────┐  ┌─────────┴──────────┐   │
│   │  Database   │  │  FFmpegBridge      │   │
│   │  GRDB/FTS5  │  │  STTProcessor      │   │
│   │  向量 BLOB  │  │  VisionAnalyzer    │   │
│   └────────────┘  └────────────────────┘   │
├─────────────────────────────────────────────┤
│   双层 SQLite 存储                           │
│                                             │
│   文件夹级库 (source of truth):              │
│     <素材文件夹>/.clip-index/index.sqlite    │
│     → watched_folders, videos, clips        │
│                                             │
│   全局搜索索引 (聚合缓存):                    │
│     ~/Library/App Support/FindIt/search.sqlite │
│     → clips_fts, 向量索引, search_history    │
└─────────────────────────────────────────────┘
```

## 源码目录结构

```
Sources/FindItCore/
├── Database/
│   ├── DatabaseManager.swift       # 连接管理 + WAL 模式（文件夹库 + 全局库）
│   ├── Models.swift                # WatchedFolder, Video, Clip 数据模型
│   ├── Migrations.swift            # 版本化建表迁移（两种 schema）
│   ├── SearchEngine.swift          # FTS5 + 向量混合搜索（操作全局库）
│   └── SyncEngine.swift            # 文件夹库 → 全局搜索索引同步
├── Pipeline/
│   ├── PipelineManager.swift       # 统一管线调度 + 状态机
│   ├── FFmpegBridge.swift          # FFmpeg 子进程调用封装
│   ├── SceneDetector.swift         # 场景检测 + 关键帧提取
│   ├── KeyframeExtractor.swift     # 关键帧抽取 (512px 短边 JPEG)
│   ├── AudioExtractor.swift        # 音频提取 (16kHz mono WAV)
│   ├── STTProcessor.swift          # WhisperKit + SpeechAnalyzer 封装
│   ├── SpeechAnalyzerBridge.swift  # macOS 26+ Speech 框架封装
│   ├── VisionAnalyzer.swift        # Gemini REST API 调用
│   ├── LocalVisionAnalyzer.swift   # Apple Vision 框架本地分析
│   ├── LocalVLMAnalyzer.swift      # mlx-swift-lm 本地 VLM
│   ├── VisionField.swift           # 9 字段元数据枚举（单一事实来源）
│   ├── FileScanner.swift           # 递归视频文件扫描
│   └── IndexingScheduler.swift     # 并行索引调度 + ResourceMonitor
├── Search/
│   ├── EmbeddingProvider.swift     # 嵌入协议 + EmbeddingUtils
│   ├── GeminiEmbeddingProvider.swift  # Gemini text-embedding-004 (768 维)
│   ├── NLEmbeddingProvider.swift   # Apple NLEmbedding 离线 (512 维)
│   └── VectorStore.swift           # 内存向量存储 (BLAS 批量搜索)
└── Config/
    └── ProviderConfig.swift        # API Key + 模型配置管理
```

## 模块职责

| 模块 | 职责 | 外部依赖 |
|------|------|---------|
| **Database** | 连接管理、建表迁移、CRUD、事务（文件夹库 + 全局库） | GRDB.swift |
| **SyncEngine** | 文件夹库 → 全局搜索索引的数据同步、增量更新 | Database |
| **SearchEngine** | FTS5 搜索、向量余弦相似度、融合排序（操作全局库） | Database |
| **VectorStore** | 内存向量存储，BLAS 批量矩阵搜索（100K clips ~25ms） | Accelerate |
| **FFmpegBridge** | 构建 FFmpeg 命令、解析输出、临时文件管理 | Foundation (Process) |
| **STTProcessor** | WhisperKit/SpeechAnalyzer 双引擎转录、SRT 生成 | WhisperKit, Speech |
| **VisionAnalyzer** | Gemini API 调用、图片 Base64 编码、JSON 解析 | Foundation (URLSession) |
| **LocalVisionAnalyzer** | Apple Vision 框架本地分析（6/9 字段，零网络） | Vision, CoreImage |
| **LocalVLMAnalyzer** | mlx-swift-lm 本地 VLM（Qwen3-VL-4B） | mlx-swift-lm |
| **VisionField** | 9 字段元数据枚举，数据驱动的 schema/prompt/SQL 生成 | — |
| **EmbeddingProvider** | 嵌入向量协议 + Gemini/NLEmbedding 双实现 | NaturalLanguage |
| **IndexingScheduler** | 资源池并行调度，动态并发控制 | — |
| **PipelineManager** | 管线调度、状态机管理、断点续传 | 上述所有模块 |

## 数据流

```
视频文件
    │
    ├──→ FFmpegBridge: 提取音频 (16kHz WAV)
    │         │
    │         └──→ STTProcessor (WhisperKit)
    │                   │
    │                   └──→ 转录文本 + 时间戳 → SRT 文件
    │
    └──→ FFmpegBridge: 场景检测 + 关键帧抽取
              │
              └──→ VisionAnalyzer (Gemini Flash)
                        │
                        └──→ JSON 描述 (scene, subjects, actions...)
                                  │
                                  ▼
                        文件夹级 SQLite (source of truth)
                      ┌─────────────────────┐
                      │ videos + clips 表    │
                      └──────────┬──────────┘
                                 │
                           SyncEngine (同步)
                                 │
                                 ▼
                        全局搜索索引 SQLite
                      ┌─────────────────────┐
                      │ clips_fts + 向量索引  │
                      │ + search_history     │
                      └──────────┬──────────┘
                                 │
                           SearchEngine
                      (FTS5 关键词 + 向量语义)
                                 │
                                 ▼
                           搜索结果列表
```

## 双层 SQLite 存储策略

### 文件夹级库（Source of Truth）

每个被监控的素材文件夹内创建 `.clip-index/index.sqlite`：

- 存储该文件夹下所有视频的原始索引数据
- 随文件夹移动/拷贝，天然便携（外接硬盘换电脑直接可用）
- 删除后可从原始素材重新索引

### 全局搜索索引（聚合缓存）

`~/Library/Application Support/FindIt/search.sqlite`：

- 聚合所有文件夹库的数据，支持跨文件夹搜索
- 包含 FTS5 全文索引、向量索引、搜索历史
- 删除后可从所有在线文件夹库重建

### 同步机制

- App 启动时检查各文件夹库版本，增量同步到全局库
- 索引完成后立即同步新数据
- 文件夹库新增/删除时全量重建受影响部分

## 数据库 Schema

### 文件夹级库 Schema

```sql
-- 监控文件夹表
CREATE TABLE watched_folders (
    folder_id       INTEGER PRIMARY KEY,
    folder_path     TEXT NOT NULL,
    volume_name     TEXT,                    -- 卷名（如 "素材盘A"）
    volume_uuid     TEXT,                    -- 卷 UUID（唯一标识，不随挂载点变化）
    is_available    INTEGER DEFAULT 1,       -- 当前是否可访问
    last_seen_at    TEXT,                    -- 上次可访问时间
    total_files     INTEGER DEFAULT 0,
    indexed_files   INTEGER DEFAULT 0
);

-- 视频文件表
CREATE TABLE videos (
    video_id        INTEGER PRIMARY KEY,
    folder_id       INTEGER REFERENCES watched_folders(folder_id),
    file_path       TEXT UNIQUE NOT NULL,
    file_name       TEXT NOT NULL,
    duration        REAL,                    -- 视频总时长（秒）
    file_size       INTEGER,                 -- 文件大小（字节）
    file_hash       TEXT,                    -- 快速哈希（头尾各 1MB SHA256）
    file_modified   TEXT,                    -- 文件修改时间
    created_at      TEXT,
    indexed_at      TEXT,
    index_status    TEXT DEFAULT 'pending',  -- pending / stt_running / stt_done
                                             -- / vision_running / completed
                                             -- / failed / orphaned
    index_error     TEXT,                    -- 失败原因
    orphaned_at     TEXT,                    -- 标记为 orphaned 的时间
    priority        INTEGER DEFAULT 0,       -- 用户可调优先级
    last_processed_clip INTEGER,             -- 视觉分析断点（恢复用）
    srt_path        TEXT                     -- SRT 文件实际路径（可能降级存储）
);

-- 片段表（核心搜索对象）
CREATE TABLE clips (
    clip_id         INTEGER PRIMARY KEY AUTOINCREMENT,
    video_id        INTEGER REFERENCES videos(video_id),
    start_time      REAL NOT NULL,           -- 起始时间码（秒）
    end_time        REAL NOT NULL,           -- 结束时间码（秒）
    thumbnail_path  TEXT,                    -- 缩略图缓存路径
    scene           TEXT,                    -- 场景描述
    subjects        TEXT,                    -- 主体（JSON 数组）
    actions         TEXT,                    -- 动作（JSON 数组）
    objects         TEXT,                    -- 道具/物体（JSON 数组）
    mood            TEXT,                    -- 氛围/情绪
    shot_type       TEXT,                    -- 镜头类型
    lighting        TEXT,                    -- 光线
    colors          TEXT,                    -- 色调
    description     TEXT,                    -- 自然语言描述
    tags            TEXT,                    -- 所有标签（JSON 数组，供 FTS 搜索）
    transcript      TEXT,                    -- 该时间段内的台词
    embedding       BLOB,                    -- 嵌入向量（Gemini 768维 / NL 512维 float32）
    created_at      TEXT NOT NULL DEFAULT (datetime('now'))  -- 用于增量同步
);
```

### 全局搜索索引 Schema

**ID 策略**：全局库的 clip_id / video_id 由全局库自动分配（AUTOINCREMENT），不复用文件夹库的 ID。通过 `source_folder + source_clip_id` 复合字段追溯到文件夹库原始记录。

```sql
-- 全局 clips 镜像表（从各文件夹库聚合）
CREATE TABLE clips (
    clip_id         INTEGER PRIMARY KEY AUTOINCREMENT,
    source_folder   TEXT NOT NULL,           -- 来源文件夹路径（定位文件夹库）
    source_clip_id  INTEGER NOT NULL,        -- 文件夹库中的原始 clip_id
    video_id        INTEGER,                 -- 全局库中的 video_id
    start_time      REAL NOT NULL,
    end_time        REAL NOT NULL,
    thumbnail_path  TEXT,
    scene           TEXT,
    subjects        TEXT,
    actions         TEXT,
    objects         TEXT,
    mood            TEXT,
    shot_type       TEXT,
    lighting        TEXT,
    colors          TEXT,
    description     TEXT,
    tags            TEXT,
    transcript      TEXT,
    embedding       BLOB,
    UNIQUE(source_folder, source_clip_id)    -- 防止重复同步
);

-- 全局 videos 镜像表
CREATE TABLE videos (
    video_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    source_folder   TEXT NOT NULL,
    source_video_id INTEGER NOT NULL,
    file_path       TEXT UNIQUE NOT NULL,
    file_name       TEXT NOT NULL,
    duration        REAL,
    file_size       INTEGER,
    srt_path        TEXT,
    UNIQUE(source_folder, source_video_id)
);

-- FTS5 全文搜索虚拟表
CREATE VIRTUAL TABLE clips_fts USING fts5(
    tags,                                    -- JSON 数组展开为空格分隔文本
    description,
    transcript,
    content='clips',
    content_rowid='clip_id'
);

-- 搜索历史表
CREATE TABLE search_history (
    id          INTEGER PRIMARY KEY,
    query       TEXT NOT NULL,
    searched_at TEXT NOT NULL DEFAULT (datetime('now')),
    result_count INTEGER DEFAULT 0
);

-- 同步元数据表（记录每个文件夹的同步进度）
CREATE TABLE sync_meta (
    folder_path     TEXT PRIMARY KEY,
    last_synced_clip_rowid  INTEGER DEFAULT 0,  -- 上次同步到的 clip rowid
    last_synced_video_rowid INTEGER DEFAULT 0,  -- 上次同步到的 video rowid
    last_synced_at  TEXT                        -- 上次同步时间
);
```
