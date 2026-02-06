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

## ADR-004: 向量嵌入 — BGE-M3 + ONNX Runtime

- **决策**: BGE-M3 ONNX 模型 + onnxruntime-swift-package-manager
- **原因**:
  - 中英双语原生支持（100+ 语言）
  - 1024 维密集向量，语义质量高
  - ~100MB 模型体积可接受
  - ONNX Runtime 提供官方 Swift SPM 包
- **挑战**: Swift 缺少原生 BPE tokenizer
  - 方案 A: swift-transformers (Hugging Face)
  - 方案 B: 自实现 BPE（参考 tokenizer.json）
  - 方案 C: 备用 — 轻量 tokenizer + 更简单的模型
- **策略**: Stage 1-2 先用纯 FTS5，Stage 3 再加向量搜索
- **日期**: 2026-02-06

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
