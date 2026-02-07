# 技术选型决策记录 (ADR)

## ADR-001: STT 引擎 — WhisperKit

- **决策**: WhisperKit (`https://github.com/argmaxinc/WhisperKit.git`, SPM)
- **原因**:
  - Swift 原生 SPM 包，两行代码初始化
  - CoreML + ANE 硬件加速，比纯 CPU 快 2-3x
  - 原生 word-level 时间戳，可直接生成 SRT
  - 多模型可选 (tiny ~30MB 到 large-v3 ~1.5GB)
- **素材适配**: 中英混合对白 → 选用 large-v3 获得最佳多语言支持
- **备选**: SenseVoice（中文精度更高，但需 Python 桥接增加复杂度）
- **日期**: 2026-02-06

## ADR-002: SQLite 库 — GRDB.swift

- **决策**: GRDB.swift v6.29.x (`https://github.com/groue/GRDB.swift.git`, SPM)
- **原因**:
  - Swift 风格 Record API，类型安全
  - 完整 FTS5 支持（建表、搜索、排名）
  - WAL 模式支持并发读写
  - DatabaseMigrator 版本化迁移
  - 活跃维护，社区成熟
- **版本说明**: v7 需要更新的 Swift 工具链（swiftLanguageModes 支持），当前 CLT 6.0.0-dev 不兼容，选用 v6
- **备选**: 原生 sqlite3 C API（零依赖但代码冗长、非类型安全）
- **注意**: macOS 系统 SQLite 已内置 FTS5，GRDB 默认使用系统 SQLite
- **日期**: 2026-02-06

## ADR-003: 视觉分析 — Gemini Flash REST API

- **决策**: 直接 HTTP 调用 Gemini API（Foundation URLSession）
- **原因**:
  - 避免引入 Firebase iOS SDK 重依赖（macOS App 不需要 Firebase 服务）
  - REST 调用简单、透明、易调试
  - 支持单次请求多张图片（最多 3600 张，实际建议 ≤50 张/请求）
  - 支持 responseSchema 结构化 JSON 输出
- **成本**: 用户自带 API Key，零运营成本
  - Gemini 2.5 Flash: $0.30/1M input tokens, $2.50/1M output tokens
  - 免费额度: 10 RPM, 250 RPD
- **备选**: Firebase AI Logic SDK（官方推荐但过重）、OpenAI Vision（更贵）
- **日期**: 2026-02-06

## ADR-004: 向量嵌入 — Gemini text-embedding-004 + Apple NLEmbedding

- **决策**: 双 provider 策略 — Gemini 云端优先，NLEmbedding 离线回退
- **Gemini text-embedding-004**:
  - 768 维密集向量，多语言支持
  - 免费额度 1500 RPM，零本地模型依赖
  - REST API 调用（复用 VisionAnalyzer 的 API Key 管理）
- **Apple NLEmbedding**:
  - 512 维，NaturalLanguage 框架内置
  - 完全离线，零依赖，无需 API Key
  - 作为 Gemini 不可用时的回退方案
- **搜索加速**: VectorStore actor 将全部 embedding 加载到连续内存，
  利用 cblas_sgemv (BLAS) 矩阵运算批量搜索（100K clips ~25ms）
- **原计划**: BGE-M3 + ONNX Runtime（因 tokenizer 集成复杂度放弃）
- **日期**: 2026-02-06（初版），2026-02-08（更新为实际实现）

## ADR-005: macOS 目标版本 — macOS 14 (Sonoma)

- **决策**: Package.swift 声明最低 macOS 14，macOS 15+ API 通过 `@available` 按需使用
- **原因**:
  - swift-tools-version 5.9 下 `.macOS(.v15)` 不可用（需 6.0）
  - 当前 CLT 工具链虽为 Swift 6.0 但 PackageDescription 版本支持有限
  - macOS 14 已提供 @Observable macro 和大部分 SwiftUI 新特性
  - macOS 15 独有 API 可通过 `if #available(macOS 15, *)` 条件使用
- **日期**: 2026-02-06

## ADR-006: CLI 框架 — swift-argument-parser

- **决策**: apple/swift-argument-parser (`https://github.com/apple/swift-argument-parser.git`)
- **原因**: Apple 官方维护；轻量；子命令支持完善；自动生成 --help；类型安全的参数解析
- **日期**: 2026-02-06

## ADR-007: 视频处理 — FFmpeg 子进程调用

- **决策**: 通过 Foundation.Process 调用系统 FFmpeg/FFprobe
- **原因**:
  - 用户环境已安装 FFmpeg 7.0
  - App 已需要 FFmpeg 做音频提取，复用同一工具做场景检测和抽帧
  - 无需引入 Python (PySceneDetect) 运行时
- **路径**: `~/.local/bin/ffmpeg`, `~/.local/bin/ffprobe`
- **日期**: 2026-02-06

## ADR-008: 双层 SQLite 存储策略

- **决策**: 文件夹级 SQLite + 全局搜索索引
- **文件夹库**: `<素材文件夹>/.clip-index/index.sqlite`
  - 存储原始数据：watched_folders, videos, clips
  - 随文件夹移动 / 拷贝，天然便携
  - 删除后可从原始素材重新索引
- **全局搜索索引**: `~/Library/Application Support/FindIt/search.sqlite`
  - 聚合所有文件夹库的数据
  - 包含 FTS5 虚拟表 + 向量索引
  - 包含 search_history 表
  - 删除后可从所有文件夹库重建
- **同步机制**: App 启动时 / 索引完成后，从文件夹库同步到全局库
- **原因**:
  - 用户需要便携性（外接硬盘拷贝到新电脑直接可用）
  - 又需要跨文件夹搜索的效率（单次查询一个 SQLite 而非扫描多个）
  - 全局库可视为缓存，文件夹库是 source of truth
- **日期**: 2026-02-06

## ADR-009: 融合排序归一化方案

- **决策**: FTS5 rank 与余弦相似度做 min-max 归一化后加权融合
- **公式**: `final = α × normalize(fts_rank) + β × cosine_similarity`
  - FTS5 rank（负 BM25 值）做 min-max 归一化映射到 [0, 1]
  - 余弦相似度天然在 [0, 1] 范围内
  - α, β 权重可调，初始建议 α=0.4, β=0.6
- **原因**:
  - FTS5 的 `rank` 返回负 BM25 值（越小越相关），与余弦相似度（越大越相关）量纲不同
  - 直接相加没有意义，必须先归一化到统一区间
- **日期**: 2026-02-06

## ADR-010: tags 字段存储为 JSON 数组

- **决策**: `clips.tags` 存储为 JSON 数组
- **格式**: `["海滩", "户外", "全景", "暖色调", "女性", "行走"]`
- **来源**: 从 Gemini 返回的 JSON 中提取 scene / subjects / actions / objects / mood / shot_type / lighting / colors 各字段，去重后合成 tags 数组
- **FTS5 同步**: 写入 clips_fts 时，将 JSON 数组展开为空格分隔的文本
  - 例: `"海滩 户外 全景 暖色调 女性 行走"`
- **原因**:
  - 每个 tag 是独立的字符串，方便统计高频词、UI 展示
  - JSON 数组在 Swift 中解码简单（`JSONDecoder` / `JSONSerialization`）
  - FTS5 需要纯文本，展开为空格分隔即可
- **日期**: 2026-02-06

## ADR-011: Gemini API 额度管理

- **决策**: 主动管理 API 调用额度，避免超限导致索引中断
- **策略**:
  - 索引前估算所需 API 调用次数，提示用户预计耗时
  - 运行时追踪当日已用调用次数
  - 接近免费额度限制（250 RPD）时自动暂停，提示"明日继续"
  - 设置页显示当日已用 / 剩余调用次数
- **原因**:
  - Gemini Flash 免费额度有限（10 RPM, 250 RPD）
  - 不做管理会导致 429 错误频发，用户体验差
  - 付费用户额度充足，仅免费用户需要此机制
- **日期**: 2026-02-06

## ADR-012: SRT 文件存储降级策略

- **决策**: SRT 文件优先写视频同目录，失败时降级到 App 目录
- **路径优先级**:
  1. `<视频文件所在目录>/<视频文件名>.srt` — 优先
  2. `~/Library/Application Support/FindIt/srt/<video_hash>.srt` — 降级
- **数据库记录**: `videos` 表增加 `srt_path` 字段记录 SRT 实际存储路径
- **原因**:
  - 外接硬盘或只读卷无法在视频同目录写入
  - 降级到 App 目录确保 SRT 不会丢失
  - 记录实际路径便于后续读取
- **日期**: 2026-02-06

## ADR-013: 搜索历史表

- **决策**: 在全局搜索库新增 `search_history` 表
- **Schema**:
  ```sql
  CREATE TABLE search_history (
      id          INTEGER PRIMARY KEY,
      query       TEXT NOT NULL,
      searched_at TEXT NOT NULL DEFAULT (datetime('now')),
      result_count INTEGER DEFAULT 0
  );
  ```
- **热门标签**: 从 `clips.tags` 统计 TOP N 高频词，无需额外表
- **原因**:
  - 支持搜索历史展示（最近搜过的）
  - 支持搜索分析（什么查询最热门）
  - 热门标签直接从现有数据统计，不增加冗余
- **日期**: 2026-02-06

## ADR-014: 并行索引调度 — 资源池模型

- **决策**: 实现基于资源池的并行索引调度器，替代当前串行逐视频处理
- **架构**: 三层分离

  | 层级 | 组件 | 职责 |
  |------|------|------|
  | 资源管理 | `ResourceMonitor` (actor) | 采样系统状态，动态调整资源池大小 |
  | 调度 | `IndexingScheduler` (actor) | 资源池 acquire/release，多视频并发编排 |
  | 协调 | `IndexingManager` (@Observable) | UI 进度、队列管理，调用 Scheduler |

- **资源池模型**:
  - **CPU Pool**: 控制 FFmpeg/LocalVision 等 CPU 密集任务并发数
  - **GPU Pool**: 控制 STT/LocalVLM 等 GPU 独占任务（slots=1）
  - **Network Pool**: 控制 Gemini API 调用（已有 GeminiRateLimiter 管理）
  - 每个管线阶段声明资源需求，调度器按需分配

  | 任务 | CPU | GPU | Network |
  |------|-----|-----|---------|
  | FFmpeg 场景检测 | 1 slot | - | - |
  | 关键帧提取 | 1 slot | - | - |
  | STT (SpeechAnalyzer) | - | 1 slot | - |
  | Vision (Gemini) | - | - | rate-limited |
  | Vision (LocalVLM) | - | 1 slot | - |
  | Vision (LocalVision) | 1 slot | - | - |
  | Embedding (NL) | - | - | - |

- **动态调整策略**:
  - 监控 `ProcessInfo.thermalState`（nominal/fair/serious/critical）
  - 监控 `os_proc_available_memory()` 可用内存
  - 监控 `ProcessInfo.isLowPowerModeEnabled` 节能模式
  - `thermalState` 升高 → 自动缩减 CPU Pool slots
  - 可用内存不足 → 暂停新任务入队
  - 持续采样（每 5 秒），非一次性设定

- **性能模式** (`PerformanceMode` enum):

  | 模式 | CPU Slots | QoS | 场景 |
  |------|-----------|-----|------|
  | `fullSpeed` | cores-2 | `.userInitiated` | 用户手动选择快速完成 |
  | `balanced` | cores/2 | `.utility` | 默认模式 |
  | `background` | max(1, cores/4) | `.background` | 最低干扰 |

- **关键约束**:
  - GPU Pool slots=1（STT 和 LocalVLM 互斥，不能并行）
  - Gemini API 由 `GeminiRateLimiter` actor 自管理，无需额外 pool
  - GRDB `DatabasePool` 支持并发读+串行写，多视频同时写同一个 folder DB 安全
  - 所有管线组件是 enum + static methods，无实例状态，天然线程安全

- **预估加速**:
  - 有 API Key: ~3x（GPU 和 Network 并行）
  - 纯本地: ~2x（FFmpeg 并行，GPU 串行）

- **实现方式**: `AsyncSemaphore` actor 作为资源池原语，`TaskGroup` 管理并发视频处理
- **可扩展性**: 未来新增分析阶段只需声明资源需求，调度器自动处理
- **CLI 支持**: `index --parallel` 标志启用并行模式
- **日期**: 2026-02-07
