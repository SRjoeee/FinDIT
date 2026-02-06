# 当前阶段: Stage 2 — 处理管线

## 进行中

_无_

## 待办

### 2d: 管线串联
- [ ] PipelineManager 状态机
- [ ] 断点续传 + 并发控制
- [ ] 错误处理 + 失败重试
- [ ] 索引完成后触发 SyncEngine

## 已完成（Stage 2c: Gemini Flash 视觉分析）

### VisionAnalyzer 视觉分析
- [x] VisionAnalyzerError 错误枚举（6 种错误）
- [x] VisionAnalyzer.Config (model, maxImages, timeout, retries)
- [x] API Key 管理 (resolveAPIKey: CLI 选项 > 配置文件 > 环境变量)
- [x] API Key 文件: `~/.config/findit/gemini-api-key.txt`
- [x] AnalysisResult 数据结构 + composeTags 自动去重合成
- [x] encodeImageToBase64 — JPEG → base64
- [x] buildRequestBody — Gemini API JSON 请求体 + response_schema
- [x] formatPrompt — PRODUCT_SPEC 3.2.5 提示词
- [x] parseResponse / parseErrorResponse — Gemini 响应解析
- [x] sendRequest — URLSession + 指数退避重试 (429/503/500)
- [x] analyzeScene — 主异步入口
- [x] 29 个单元测试（key 管理 8 + 纯函数 12 + HTTP 5 + Config 4）
- [x] CLI `analyze` 子命令 (AsyncParsableCommand)
- [x] 196 个测试全部通过
- [x] Tag: `v0.2c-vision`

## 已完成（Stage 2b: WhisperKit STT）

### STTProcessor 语音转文字
- [x] TranscriptSegment 内部类型 + STTError 错误枚举
- [x] STTProcessor.Config (modelName, language, wordTimestamps)
- [x] SRT 时间戳格式化/解析 (formatSRTTimestamp / parseSRTTimestamp)
- [x] SRT 生成/解析 (generateSRT / parseSRT) — roundtrip 验证
- [x] SRT 路径解析 (resolveSRTPath) — ADR-012 降级策略
- [x] SRT 文件写入 (writeSRT) — 优先视频目录，降级 App Support
- [x] 转录文本映射 (mapTranscriptToClips) — 时间重叠分配到场景片段
- [x] WhisperKit 初始化 (initializeWhisperKit) — 模型加载
- [x] 音频转录 (transcribe) — WhisperKit 异步调用
- [x] 完整流水线 (transcribeAndSaveSRT) — 转录 → SRT → 保存
- [x] convertSegments — WhisperKit 类型 → 内部类型转换
- [x] 33 个单元测试（时间戳 11、SRT 7、路径 4、映射 5、Config 2、hash 3、roundtrip 1）
- [x] CLI `transcribe` 子命令 (AsyncParsableCommand)
- [x] 167 个测试全部通过
- [x] Tag: `v0.2b-stt`

## 已完成（Stage 2a: FFmpeg 集成）

### 1a: 文件夹级 SQLite
- [x] 创建 Migrations.swift — DatabaseMigrator 版本化迁移
- [x] 创建 Models.swift — WatchedFolder, Video, Clip Record 类型
- [x] 实现 CRUD 操作（插入/查询/更新/删除）
- [x] 单元测试: 内存数据库测试 CRUD

### 1b: 全局搜索索引
- [x] 创建全局库 Schema（clips 镜像, videos 镜像, clips_fts, search_history）
- [x] FTS5 虚拟表建表 + content sync triggers
- [x] FTS5 搜索实现（关键词、前缀、精确、排除）
- [x] 单元测试: FTS5 搜索测试

### 1c: 同步引擎
- [x] 创建 SyncEngine.swift — 文件夹库 → 全局库同步
- [x] 增量同步逻辑（基于 rowid / 时间戳）
- [x] 单元测试: 同步正确性

### 1d: CLI 验证
- [x] CLI `db-init` 子命令 — 初始化数据库 + 注册 WatchedFolder
- [x] CLI `insert-mock` 子命令 — 插入 3 视频 7 片段中英混合模拟数据
- [x] CLI `search` 子命令 — FTS5 搜索 + 格式化结果 + 搜索历史
- [x] CLI `sync` 子命令 — 手动触发增量同步
- [x] 端到端验证: db-init → insert-mock → sync → search (中文/英文/OR 语法)

## 已完成（Stage 2a: FFmpeg 集成）

### FFmpegBridge 子进程封装
- [x] FFmpegError 错误枚举 + FFmpegConfig 配置
- [x] FFmpegBridge.run() — Process + Pipe + 超时保护
- [x] validateExecutable / version / videoDuration / parseDuration
- [x] 13 个单元测试（含集成测试）
- [x] CLI `ffmpeg-check` 子命令

### AudioExtractor 音频提取
- [x] extractAudio — 16kHz mono WAV 输出
- [x] buildArguments 纯函数
- [x] 3 个单元测试
- [x] CLI `extract-audio` 子命令

### SceneDetector 场景检测
- [x] SceneSegment 数据结构 + Config
- [x] detectScenes 完整流水线
- [x] parseTimestamps / filterByMinGap / segmentsFromCutPoints / mergeShortSegments / splitLongSegments 纯函数
- [x] buildDetectionArguments（-fps_mode vfr，兼容 FFmpeg 7.0）
- [x] 28 个单元测试（含完整流水线模拟）
- [x] CLI `detect-scenes` 子命令

### KeyframeExtractor 关键帧提取
- [x] Config + ExtractedFrame 数据结构
- [x] framesPerScene / frameTimestamps / buildExtractArguments 纯函数
- [x] extractKeyframes — 场景遍历 + 512px 短边缩略图
- [x] 15 个单元测试
- [x] CLI `extract-keyframes` 子命令

### 集成验证
- [x] 合成测试视频 3 场景端到端验证
- [x] detect-scenes: 正确识别 3 个场景（15s, 10s, 8s）
- [x] extract-keyframes: 6 帧缩略图（3+2+1），512px 短边
- [x] extract-audio: 16kHz mono WAV 输出
- [x] 134 个测试全部通过
- [x] Tag: `v0.2a-ffmpeg`

## 已完成（Stage 1: 存储层）

### 1a-1c: 数据库 + 搜索 + 同步
- [x] Migrations / Models / CRUD / FTS5 / SyncEngine
- [x] 75 个单元测试

### 1d: CLI 验证
- [x] db-init / insert-mock / sync / search 子命令
- [x] 端到端验证通过
- [x] Tag: `v0.1-storage`

## 已完成（Stage 0）

- [x] 创建项目文档体系 (CLAUDE.md, ROADMAP, TASKS, ARCHITECTURE, TECH_DECISIONS, PRODUCT_SPEC)
- [x] 创建 .gitignore
- [x] 创建 Package.swift（GRDB v6.29.x + ArgumentParser 依赖）
- [x] 创建 Sources/FindItCore/ 目录 + 占位文件
- [x] 创建 Sources/FindItCLI/CLI.swift
- [x] 创建 Tests/FindItCoreTests/ + 占位测试
- [x] 验证: `swift build` 通过, `swift run findit-cli --help` 通过
- [x] Git init + commit + tag `v0.0-skeleton`
- [x] 产品说明书 review + 技术决策补充 (ADR-008 ~ ADR-013)
- [x] 验证 `swift test` + `swift build` 在 Xcode 环境下通过
- [x] 创建 DatabaseManager.swift — 连接管理、WAL 模式、路径解析 + StorageError
