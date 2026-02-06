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
