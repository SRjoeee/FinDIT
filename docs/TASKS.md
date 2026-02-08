# 当前阶段: Stage 6 — 实时同步 + 导出

## 进行中

*无*

## 待办

### Stage 6: 实时同步 + 导出

- NLE 导出（EDL + FCPXML，单个/批量）
- 拖拽到 NLE（NSItemProvider）
- 全局快捷键 ⌘⇧F（后台唤起）
- 批量多选操作（selectedClipId → Set\<Int64\>）
- Smart Folders / 保存的搜索
- 去重检测 UI（基于 fileHash）

## 已完成（Stage 6: FSEvents 文件系统实时监控）

### Core 层: FileSystemWatcher

- FSEvents 框架封装，per-folder 独立 FSEventStream
- FileChangeEvent: .added / .removed / .modified / .rescanNeeded
- 1.5s 延迟合并窗口 + 同路径去重
- 仅监控视频文件 (FileScanner.supportedExtensions)，自动过滤 .clip-index 目录
- classifyEvent: FSEvents 标志 + 文件实际存在性双重判断
- 内核缓冲区溢出/根目录变更 → rescanNeeded 事件
- 29 个单元测试

### Core 层: VideoManager

- removeVideo / removeVideos: 双层数据库删除 (文件夹库 + 全局库)
- 文件夹库 CASCADE 自动删除关联 clips
- 全局库手动删除 clips + videos (按 source_folder + source_video_id)
- 文件系统清理: 缩略图目录 + SRT 文件
- 11 个单元测试

### App 层: FileWatcherManager

- @Observable @MainActor，参照 VolumeMonitor 模式
- 生命周期: startWatching / watchFolder / unwatchFolder / stopWatching
- 事件路由: .added/.modified → IndexingManager.queueVideos(), .removed → VideoManager.removeVideos(), .rescanNeeded → IndexingManager.queueFolder()
- 索引冲突避免: folderIndexingStarted/Finished + deferredEvents 延迟缓存
- 删除时通知 SearchState 失效 VectorStore 缓存

### App 层: IndexingManager 增量队列

- queueVideos(): 单/多个视频增量索引（跳过全量扫描）
- processSpecificVideos(): 直接处理指定视频列表
- processQueue(): 全量扫描优先于增量视频

### 验收

- 665 个测试全部通过 (654 + 11 新增 VideoManager)
- 数据流: FSEvents → FileSystemWatcher → FileWatcherManager → IndexingManager/VideoManager

## 已完成（文件管理系统 — 卷监控 + 通知 + UI）

### Core 层工具

- VolumeResolver: 卷 UUID/名称解析、挂载点查找、路径恢复 (URL.resourceValues)
- FolderStats: 每文件夹视频/片段统计查询
- Clip.sqliteDatetime() 改为 public
- 15 个新增测试 (VolumeResolver 12 + FolderStats 3)

### 卷信息填充 + reloadFolders 增强

- addFolder 时记录 volumeName/volumeUuid/lastSeenAt
- reloadFolders 查询 FolderStats、缓存 VolumeInfo、UUID 路径恢复

### VolumeMonitor 卷监控

- DiskArbitration 框架实时检测卷挂载/卸载
- 卸载 → 标记离线 + 系统通知
- 挂载 → UUID 匹配恢复 + 路径更新 + 恢复索引

### NotificationManager 系统通知

- UNUserNotificationCenter macOS 通知
- 索引完成/失败、硬盘连接/断开通知
- Bundle identifier 防护 (SPM executable 兼容)

### 侧边栏 UI 增强

- 绿/红状态圆点 (在线/离线)
- 视频/片段统计文本
- 离线文件夹显示 "上次在线：X 天前"
- 外接卷名前缀显示
- 文件夹管理弹窗添加状态 badge + 统计

### 搜索结果离线蒙层

- ClipCard: isOffline 参数 + 半透明灰色遮罩 + icloud.slash 图标
- ResultsGrid: offlineFolders 集合注入

### 验收

- 505 个测试全部通过 (448 + 15 新增 + 既有 42 未变)

## 已完成（性能优化 — 搜索 + 缩略图 + 嵌入质量）

### VectorStore 批量矩阵搜索

- VectorStore actor: 连续 Float 内存 + cblas_sgemv BLAS 批量搜索
- 预计算 L2 范数，100K clips ~25ms（vs 逐行扫描 ~6s，240x 加速）
- SearchEngine.hybridSearch 集成 VectorStore 预计算结果
- SearchState 懒加载 VectorStore（首次向量搜索触发）
- 19 个新增测试

### composeClipText JSON 数组解析

- 数组字段 (subjects/actions/objects) 的 JSON 字符串解析为逗号分隔文本
- `["男子", "女子"]` → `男子, 女子`，消除嵌入向量的语法噪声
- 2 个新增测试

### ThumbnailView 缓存 + 下采样

- CGImageSource + kCGImageSourceThumbnailMaxPixelSize 解码阶段下采样
- 全局 NSCache (countLimit=200) LRU 淘汰
- 512×288 → 300×169，内存减少约 50%

### 文档更新

- ARCHITECTURE.md: 移除幻影模块 (Volume/Export)，补充实际模块
- TECH_DECISIONS.md: ADR-004 更新为 Gemini + NLEmbedding
- ROADMAP.md: Stage 4 子 block 完成状态
- TASKS.md: 测试数量更新

## 已完成（Stage 4a: SwiftUI 骨架）

### App 入口 + 状态管理

- FindItApp: @main 入口 + macOS 菜单命令（添加/管理文件夹）
- AppState: 全局 DB 初始化、文件夹 CRUD、async addFolder
- SearchState: FTS5 即时搜索 + 向量 300ms debounce + Gemini embedding 懒初始化

### 视图层

- ContentView: NavigationSplitView + toolbar 搜索框 + 状态路由
- NativeSearchField: NSSearchField 封装（macOS 原生外观）
- SidebarView: 文件夹列表 + 可用性状态
- ResultsGrid: LazyVGrid 缩略图网格 + clip 元数据
- ClipCard + ThumbnailView: 异步图片加载 + 时间码覆盖
- EmptyStateView: 新用户引导
- FolderManagementSheet: 文件夹添加/删除管理
- VisualEffectBackground: NSVisualEffectView 毛玻璃背景

## 已完成（Code Review 修复 — Rounds 5-7）

### 性能与正确性

- CIContext 静态复用（LocalVisionAnalyzer，避免每帧 GPU 分配）
- DB 索引: clips(embedding_model) + clips(video_id)，文件夹库 + 全局库
- 融合排序稳定性: clipId tie-break（vectorSearch + fusionSearch）
- API key 可重试初始化（移除 one-shot 标志）
- addFolder 异步化（Task.detached 避免主线程阻塞）

### Sendable 一致性

- 7 个 Config 结构体 + SearchWeights 全部加 `: Sendable`

### 测试

- 4 个索引契约测试（embedding_model × 2 + video_id × 2）
- 414 个测试全部通过

## 已完成（Stage 3.7: VisionField 重构）

### VisionField 枚举 — 单一事实来源

- 创建 `VisionField` enum (9 cases + 计算属性 + 静态方法)
- AnalysisResult 扩展: `stringValue(for:)`, `arrayValue(for:)`, `composeTags(from:)`
- Clip 扩展: `visionValue(for:)`
- 17 个新增测试

### 消费方迁移（7 个文件）

- VisionAnalyzer.buildResponseSchema → 委托 VisionField
- LocalVLMAnalyzer.analysisPrompt → VisionField.buildVLMPrompt()
- EmbeddingUtils.composeClipText → EmbeddingGroup 驱动
- PipelineManager.updateClipVision → 动态 SQL
- SyncEngine.sync → 动态 vision 列
- LocalVisionAnalyzer.mergeResults → 策略驱动
- CLI AnalyzeCommand → VisionField 遍历

### 验收

- 405 个测试全部通过 (388 + 17 新增)
- E2E 5 视频性能: 277s (Stage 3.6: 306s, -9%)

## 已完成（Stage 3.6: 管线修复）

### Fix 1: 批量关键帧提取时间戳 bug

- `buildBatchExtractArguments` 中 `-ss` 输入选项导致 FFmpeg 时间戳重置
- `select` 表达式使用绝对时间戳，与重置后的 `t` 不匹配
- 修复: 将绝对时间戳转为 segment-relative
- 增加安全网: 批量提取 0 帧时用单帧模式在中点补提
- 4 个新测试

### Fix 2: 音频提取门控

- `needsAudio = whisperKit != nil` 改为 `await isSttAvailable(whisperKit:)`
- 确保 macOS 26+ 纯 SpeechAnalyzer 路径也能预提取音频

### Fix 3: 语言检测不依赖 WhisperKit

- 新增 `STTProcessor.detectLanguageViaNL`: SpeechAnalyzer + NLLanguageRecognizer
- PipelineManager: WhisperKit nil 时用 NL 方案检测语言
- 英语结果可复用，避免二次转录
- 1 个新测试

### Fix 4: CLI WhisperKit 初始化降级

- IndexCommand WhisperKit 初始化包裹 do-catch
- 失败时打印警告，降级到 SpeechAnalyzer

### 验收

- 383 个测试全部通过 (378 + 5 新增)

## 已完成（Stage 3.5: 管线性能优化）

### Step 1: WhisperKit Turbo 模型切换

- STTProcessor.Config 默认模型: `large-v3` → `openai_whisper-large-v3-v20240930`
- 809M 参数 (vs 1.5B)，5-8x 加速，WER 降低 ~0.6%
- CLI `--model` 默认值同步更新

### Step 2: Apple Vision 本地分析器

- LocalVisionAnalyzer: VNClassifyImageRequest + VNDetectFace/HumanRectanglesRequest
- 填充 6/9 个 AnalysisResult 字段 (scene, subjects, objects, shotType, lighting, colors)
- CIAreaAverage (亮度分类) + CIKMeans (主色提取)
- 零网络依赖，~10-30ms/帧，33 个单元测试

### Step 3: 管线并行化

- PipelineManager: 音频提取与场景检测并行 (Task)
- LocalVisionAnalyzer 在 clip 创建后立即运行
- 批量嵌入: embedBatch() 替代逐个 embed()，降级回退

### Step 4: FFmpeg 优化

- detectScenesOptimized(): 单次 FFmpeg 调用 = 场景检测 + 时长解析 + 可选音频提取
- 消除独立 videoDuration() 调用
- CombinedDetectionResult 类型，4 个测试

### Step 5: 配置优化

- maxFramesPerScene: 5 → 3，减少 40% 关键帧和 Vision API 调用

### Step 6: Apple SpeechAnalyzer (macOS 26+)

- SpeechAnalyzerBridge: @available(macOS 26.0, *) 封装 Speech 框架
- 支持 41 种语言 (含中/日/英)，比 WhisperKit turbo 快 ~2.2x
- STTProcessor.transcribeWithBestAvailable(): 自动选择最优引擎
- PipelineManager: macOS 26+ 无需 WhisperKit 即可做 STT
- 11 个测试

### Step 7: 本地 VLM (Qwen2.5-VL-3B)

- LocalVLMAnalyzer: mlx-swift-lm 集成 (MLXVLM + MLXLMCommon)
- Qwen2.5-VL-3B-Instruct-4bit (~3 GB, 懒下载)
- ChatSession API 结构化 JSON 输出
- Vision 策略: Gemini > LocalVLM > LocalVisionAnalyzer
- PipelineManager 新增 vlmContainer 参数
- 11 个测试

### 验收

- 378 个测试全部通过 (317 + 61 新增)
- Tag: `v0.3.1-perf`

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

