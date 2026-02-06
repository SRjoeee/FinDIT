# 当前阶段: Stage 4 — macOS App

## 进行中

*无*

## 待办

### Stage 4: macOS App

- Xcode 项目创建 + SwiftUI 界面
- 搜索框 + 实时搜索 (FTS5 即时 + 向量 300ms debounce)
- 缩略图网格视图
- BGE-M3 ONNX 本地嵌入 (可选增强)

## 已完成（Stage 3: 搜索引擎）

### EmbeddingProvider 协议 + EmbeddingUtils

- EmbeddingProvider 协议 (name, dimensions, isAvailable, embed, embedBatch)
- EmbeddingError 错误枚举 (5 种错误)
- EmbeddingUtils: composeClipText, cosineSimilarity (vDSP SIMD), serialize/deserialize, minMaxNormalize
- 22 个单元测试

### GeminiEmbeddingProvider

- Gemini text-embedding-004 REST API (768 维, 多语言, 免费 1500 RPM)
- embedContent (单文本) + batchEmbedContents (批量, 自动分片 ≤100)
- 指数退避重试 (429/503/500)
- 复用 VisionAnalyzer API Key 管理
- 20 个单元测试

### NLEmbeddingProvider

- Apple NaturalLanguage 框架离线嵌入 (512 维)
- 语言自动检测 + 词级嵌入平均
- 完全离线，零依赖，无需 API Key
- 10 个单元测试

### DB 迁移 + SearchEngine 混合搜索

- v2 迁移: ALTER TABLE clips ADD COLUMN embedding_model TEXT (文件夹库 + 全局库)
- Clip 模型新增 embeddingModel 字段
- SearchMode: fts / vector / hybrid / auto
- SearchWeights: default (0.4/0.6), exactMatch (0.9/0.1), semantic (0.2/0.8)
- hybridSearch: FTS5 + 向量融合排序 (min-max 归一化)
- vectorSearch: 余弦相似度 + embedding_model 过滤
- resolveWeights: 自适应权重 (引号→精确优先, 长句→语义优先)
- SyncEngine 同步 embedding_model 列
- 17 个单元测试

### Pipeline 集成 + CLI

- PipelineManager 新增嵌入步骤 (非致命, Vision 完成后 sync 之前)
- CLI `search` 升级为 AsyncParsableCommand + --mode (fts/vector/hybrid/auto) + --api-key
- CLI 新增 `embed` 命令 (--folder, --provider gemini/nl, --force)
- 搜索自动选择 embedding provider (Gemini 优先, NLEmbedding 回退)

### 验收

- 317 个测试全部通过 (248 + 69 新增)
- Tag: `v0.3-search`

## 已完成（Stage 2d: 管线串联）

### FileScanner 文件扫描

- supportedExtensions (9 种视频格式)
- scanVideoFiles — 递归扫描 + 隐藏文件跳过
- isVideoFile — 扩展名判断
- 8 个单元测试

### PipelineManager 全流程编排

- Stage 状态机 (pending → stt_running → stt_done → vision_running → completed / failed)
- processVideo — 完整端到端管线编排
- 断点续传 (last_processed_clip, Vision 每个 clip 更新)
- 恢复模式 (根据 index_status 跳过已完成的步骤)
- 错误处理 (STT 失败不致命，Vision 单 clip 失败跳过继续)
- 索引完成后自动触发 SyncEngine.sync()
- 纯函数: thumbnailDirectory, tmpDirectory, groupFramesByScene, encodeJSONArray, selectThumbnail
- 12 个单元测试

### CLI index 子命令

- 单文件模式 (--input) 和文件夹扫描模式
- --skip-stt / --skip-vision 跳过模式
- --force 强制重索引
- --api-key / --model 选项
- 进度报告 + 耗时统计

### 验收

- 248 个测试全部通过
- Tag: `v0.2d-pipeline`

## 已完成（Stage 2c: Gemini Flash 视觉分析）

### VisionAnalyzer 视觉分析

- VisionAnalyzerError 错误枚举（6 种错误）
- VisionAnalyzer.Config (model, maxImages, timeout, retries)
- API Key 管理 (resolveAPIKey: CLI 选项 > 配置文件 > 环境变量)
- API Key 文件: `~/.config/findit/gemini-api-key.txt`
- AnalysisResult 数据结构 + composeTags 自动去重合成
- encodeImageToBase64 — JPEG → base64
- buildRequestBody — Gemini API JSON 请求体 + response_schema
- formatPrompt — PRODUCT_SPEC 3.2.5 提示词
- parseResponse / parseErrorResponse — Gemini 响应解析
- sendRequest — URLSession + 指数退避重试 (429/503/500)
- analyzeScene — 主异步入口
- 29 个单元测试（key 管理 8 + 纯函数 12 + HTTP 5 + Config 4）
- CLI `analyze` 子命令 (AsyncParsableCommand)
- 196 个测试全部通过
- Tag: `v0.2c-vision`

## 已完成（Stage 2b: WhisperKit STT）

### STTProcessor 语音转文字

- TranscriptSegment 内部类型 + STTError 错误枚举
- STTProcessor.Config (modelName, language, wordTimestamps)
- SRT 时间戳格式化/解析 (formatSRTTimestamp / parseSRTTimestamp)
- SRT 生成/解析 (generateSRT / parseSRT) — roundtrip 验证
- SRT 路径解析 (resolveSRTPath) — ADR-012 降级策略
- SRT 文件写入 (writeSRT) — 优先视频目录，降级 App Support
- 转录文本映射 (mapTranscriptToClips) — 时间重叠分配到场景片段
- WhisperKit 初始化 (initializeWhisperKit) — 模型加载
- 音频转录 (transcribe) — WhisperKit 异步调用
- 完整流水线 (transcribeAndSaveSRT) — 转录 → SRT → 保存
- convertSegments — WhisperKit 类型 → 内部类型转换
- 33 个单元测试（时间戳 11、SRT 7、路径 4、映射 5、Config 2、hash 3、roundtrip 1）
- CLI `transcribe` 子命令 (AsyncParsableCommand)
- 167 个测试全部通过
- Tag: `v0.2b-stt`

## 已完成（Stage 2a: FFmpeg 集成）

### 1a: 文件夹级 SQLite

- 创建 Migrations.swift — DatabaseMigrator 版本化迁移
- 创建 Models.swift — WatchedFolder, Video, Clip Record 类型
- 实现 CRUD 操作（插入/查询/更新/删除）
- 单元测试: 内存数据库测试 CRUD

### 1b: 全局搜索索引

- 创建全局库 Schema（clips 镜像, videos 镜像, clips_fts, search_history）
- FTS5 虚拟表建表 + content sync triggers
- FTS5 搜索实现（关键词、前缀、精确、排除）
- 单元测试: FTS5 搜索测试

### 1c: 同步引擎

- 创建 SyncEngine.swift — 文件夹库 → 全局库同步
- 增量同步逻辑（基于 rowid / 时间戳）
- 单元测试: 同步正确性

### 1d: CLI 验证

- CLI `db-init` 子命令 — 初始化数据库 + 注册 WatchedFolder
- CLI `insert-mock` 子命令 — 插入 3 视频 7 片段中英混合模拟数据
- CLI `search` 子命令 — FTS5 搜索 + 格式化结果 + 搜索历史
- CLI `sync` 子命令 — 手动触发增量同步
- 端到端验证: db-init → insert-mock → sync → search (中文/英文/OR 语法)

## 已完成（Stage 2a: FFmpeg 集成）

### FFmpegBridge 子进程封装

- FFmpegError 错误枚举 + FFmpegConfig 配置
- FFmpegBridge.run() — Process + Pipe + 超时保护
- validateExecutable / version / videoDuration / parseDuration
- 13 个单元测试（含集成测试）
- CLI `ffmpeg-check` 子命令

### AudioExtractor 音频提取

- extractAudio — 16kHz mono WAV 输出
- buildArguments 纯函数
- 3 个单元测试
- CLI `extract-audio` 子命令

### SceneDetector 场景检测

- SceneSegment 数据结构 + Config
- detectScenes 完整流水线
- parseTimestamps / filterByMinGap / segmentsFromCutPoints / mergeShortSegments / splitLongSegments 纯函数
- buildDetectionArguments（-fps_mode vfr，兼容 FFmpeg 7.0）
- 28 个单元测试（含完整流水线模拟）
- CLI `detect-scenes` 子命令

### KeyframeExtractor 关键帧提取

- Config + ExtractedFrame 数据结构
- framesPerScene / frameTimestamps / buildExtractArguments 纯函数
- extractKeyframes — 场景遍历 + 512px 短边缩略图
- 15 个单元测试
- CLI `extract-keyframes` 子命令

### 集成验证

- 合成测试视频 3 场景端到端验证
- detect-scenes: 正确识别 3 个场景（15s, 10s, 8s）
- extract-keyframes: 6 帧缩略图（3+2+1），512px 短边
- extract-audio: 16kHz mono WAV 输出
- 134 个测试全部通过
- Tag: `v0.2a-ffmpeg`

## 已完成（Stage 1: 存储层）

### 1a-1c: 数据库 + 搜索 + 同步

- Migrations / Models / CRUD / FTS5 / SyncEngine
- 75 个单元测试

### 1d: CLI 验证

- db-init / insert-mock / sync / search 子命令
- 端到端验证通过
- Tag: `v0.1-storage`

## 已完成（Stage 0）

- 创建项目文档体系 (CLAUDE.md, ROADMAP, TASKS, ARCHITECTURE, TECH_DECISIONS, PRODUCT_SPEC)
- 创建 .gitignore
- 创建 Package.swift（GRDB v6.29.x + ArgumentParser 依赖）
- 创建 Sources/FindItCore/ 目录 + 占位文件
- 创建 Sources/FindItCLI/CLI.swift
- 创建 Tests/FindItCoreTests/ + 占位测试
- 验证: `swift build` 通过, `swift run findit-cli --help` 通过
- Git init + commit + tag `v0.0-skeleton`
- 产品说明书 review + 技术决策补充 (ADR-008 ~ ADR-013)
- 验证 `swift test` + `swift build` 在 Xcode 环境下通过
- 创建 DatabaseManager.swift — 连接管理、WAL 模式、路径解析 + StorageError

