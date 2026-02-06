# FindIt 开发路线图

## 开发范式

**内核优先 + CLI 验证 + 逐步穿壳**

先用 Swift Package 构建纯逻辑内核（FindItCore），通过 CLI 命令验证每一层功能，全部跑通后再套上 SwiftUI 界面。

---

## Stage 0: 项目骨架 ✓

**Tag: `v0.0-skeleton**` — 已完成

- 项目文档体系（CLAUDE.md, ROADMAP, TASKS, ARCHITECTURE, TECH_DECISIONS）
- Package.swift + 依赖声明（GRDB v6.29.x + swift-argument-parser）
- 源文件目录结构 + 占位文件
- CLI 入口（swift-argument-parser）
- `swift build` 编译通过
- `swift run findit-cli --help` 显示帮助信息
- Git init + 2 commits + tag `v0.0-skeleton`

> 注: `swift test` 需要安装完整 Xcode（CLT 不含 XCTest）

---

## Stage 1: 存储层 ✓

**Tag: `v0.1-storage**` — 已完成

### 1a: 文件夹级 SQLite

- GRDB DatabaseManager — 连接管理 + WAL 模式
- DatabaseMigrator 版本化迁移系统
- 文件夹库 Schema: watched_folders, videos, clips 三张核心表
- CRUD 操作封装（GRDB Record 类型）

### 1b: 全局搜索索引

- 全局库 Schema: clips 镜像, videos 镜像, clips_fts, search_history
- FTS5 虚拟表创建（tags + description + transcript）
- FTS5 搜索：关键词 / 前缀匹配 / 引号精确 / 排除词

### 1c: 同步引擎

- SyncEngine: 文件夹库 → 全局搜索索引同步
- 增量同步（基于 rowid + sync_meta 追踪）
- removeFolderData: 文件夹删除时清理全局库

### 1d: CLI 验证

- CLI 命令: `db-init` — 初始化文件夹库 + 全局库
- CLI 命令: `insert-mock` — 插入模拟数据
- CLI 命令: `search <query>` — FTS5 搜索
- CLI 命令: `sync` — 手动触发同步

**验收标准：** 全部通过 ✓

- 75 个单元测试全部通过
- CLI 端到端验证：insert-mock → sync → search (中英文/OR/NOT)
- 文件夹库数据正确同步到全局搜索索引

---

## Stage 2: 处理管线

### 2a: FFmpeg 集成 ✓

**Tag: `v0.2a-ffmpeg**` — 已完成

- FFmpegBridge：子进程调用封装 + 超时保护
- 音频提取：视频 → 16kHz mono WAV
- 场景检测：`select='gt(scene,T)'` + showinfo 解析 + merge/split
- 关键帧抽取：按场景切点 + 动态帧数 + 512px 短边 JPEG
- 134 个测试，CLI 4 个子命令

### 2b: WhisperKit STT ✓

**Tag: `v0.2b-stt**` — 已完成

- WhisperKit v0.15.0 依赖集成
- STTProcessor：SRT 生成/解析、路径解析、转录映射（33 个纯函数测试）
- WhisperKit 初始化 + 音频转录（async）
- SRT 文件生成（ADR-012 降级策略）
- 转录文本按时间范围映射到场景片段
- CLI `transcribe` 子命令（AsyncParsableCommand）
- 167 个测试全部通过

### 2c: Gemini Flash 视觉分析 ✓

**Tag: `v0.2c-vision**` — 已完成

- VisionAnalyzer: Gemini 2.5 Flash REST API (纯 URLSession, 无新依赖)
- API Key 管理 (配置文件 + 环境变量 + CLI 选项)
- AnalysisResult: 9 字段 + composeTags 自动去重合成
- 结构化输出: response_schema 确保 JSON 格式
- 重试逻辑: 指数退避 (429/503/500)
- CLI `analyze` 命令 (7 秒间隔限速)
- 29 个单元测试, 196 个测试全部通过

### 2d: 管线串联 ✓

**Tag: `v0.2d-pipeline**` — 已完成

- FileScanner: 递归视频文件扫描 (9 种格式)
- PipelineManager 状态机 (pending → stt_running → stt_done → vision_running → completed)
- 断点续传（last_processed_clip, Vision 每 clip 更新）
- 错误处理 (STT 失败不致命，Vision 单 clip 跳过)
- 索引完成后自动触发 SyncEngine
- CLI `index` 命令 (单文件 / 文件夹扫描, --skip-stt, --skip-vision, --force)
- 248 个测试全部通过

**验收标准：**

- CLI 指定真实视频文件 → 全流程自动处理 → 数据入库
- SRT 文件内容合理（中英文均可识别）
- 场景切割点合理（无过度切碎或遗漏）
- Gemini 返回的 JSON 描述有意义
- tags 字段为正确的 JSON 数组

---

## Stage 3: 搜索引擎 ✓

**Tag: `v0.3-search**` — 已完成

### 3a: EmbeddingProvider 协议 + EmbeddingUtils

- EmbeddingProvider 协议 (name, dimensions, isAvailable, embed, embedBatch)
- EmbeddingUtils: composeClipText, cosineSimilarity (vDSP SIMD), serialize/deserialize, minMaxNormalize
- 22 个单元测试

### 3b: GeminiEmbeddingProvider

- Gemini text-embedding-004 (768 维, 多语言, 免费 1500 RPM)
- embedContent + batchEmbedContents API, 指数退避重试
- 20 个单元测试

### 3c: NLEmbeddingProvider

- Apple NaturalLanguage 框架 (512 维, 离线, 零依赖)
- 语言自动检测 + 词级嵌入平均
- 10 个单元测试

### 3d: DB 迁移 + 混合搜索

- v2 迁移: embedding_model 列 (文件夹库 + 全局库)
- SearchMode (fts/vector/hybrid/auto) + SearchWeights 自适应
- hybridSearch: FTS5 + 向量融合 (min-max 归一化)
- 17 个单元测试

### 3e: Pipeline 集成 + CLI

- PipelineManager 嵌入步骤 (非致命)
- CLI `search` 混合搜索 (--mode) + `embed` 命令 (--provider gemini/nl)
- 317 个测试全部通过

**验收标准：** 全部通过 ✓

- CLI 输入自然语言描述 → 语义相关的片段排在前面
- "海边夕阳" 能匹配 "海滩日落" 的描述
- 搜索延迟 < 200ms（20,000 条记录）

---

## Stage 4: macOS App

**Tag: `v0.4-app**`

- Xcode 项目创建，引入 FindItCore
- 搜索框 + 实时搜索（FTS5 即时 + 向量 300ms debounce）
- 缩略图网格视图（LazyVGrid）
- 侧边栏素材库管理（文件夹添加/删除/状态）
- Quick Look 预览（QLPreviewPanel + 空格键）
- 筛选栏（匹配类型 + 来源文件夹）+ 排序
- 右键菜单（复制时间码、Finder 显示、导出、查看标签）
- NLE 导出（EDL + FCPXML，单个/批量）
- 拖拽到 NLE（NSItemProvider）
- 后台任务管理面板（进度、暂停/恢复/取消）
- 全局快捷键 ⌘⇧F（后台唤起）
- 外接硬盘监听（DiskArbitration）
- 系统通知（索引完成/失败/硬盘恢复）
- 设置页：API Key 管理、当日 API 额度显示
- 热门标签展示（从 clips.tags 统计 TOP N）

**验收标准：**

- 完整的用户流程可走通
- 搜索体验流畅，无明显卡顿
- 离线硬盘素材仍可搜索（不可预览/导出）

