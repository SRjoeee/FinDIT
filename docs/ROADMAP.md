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

## Stage 3.5: 管线性能优化 ✓

**Tag: `v0.3.1-perf**` — 已完成

### WhisperKit Turbo 模型

- STTProcessor 默认模型 large-v3 → openai_whisper-large-v3-v20240930 (turbo)
- 809M 参数 (vs 1.5B)，5-8x 加速，WER 仅增 ~0.6%

### Apple Vision 本地分析器

- LocalVisionAnalyzer: VNClassifyImageRequest + VNDetectFace/HumanRectanglesRequest
- 填充 6/9 个 AnalysisResult 字段 (scene, subjects, objects, shotType, lighting, colors)
- CIAreaAverage (亮度) + CIKMeans (主色提取)，~10-30ms/帧，零网络依赖

### 管线并行化

- 音频提取与场景检测并行 (async let)
- LocalVisionAnalyzer 在 clip 创建后立即运行
- 批量嵌入: embedBatch() 替代逐个 embed()

### FFmpeg 单次调用优化

- detectScenesOptimized(): 场景检测 + 时长解析 + 可选音频提取合一
- 消除独立 videoDuration() 调用

### 配置优化

- maxFramesPerScene: 5 → 3，减少 40% 关键帧和 Vision API 调用

### Apple SpeechAnalyzer (macOS 26+)

- SpeechAnalyzerBridge: @available(macOS 26.0, *) 封装 Speech 框架
- 支持 41 种语言，比 WhisperKit turbo 快 ~2.2x
- STTProcessor.transcribeWithBestAvailable(): 自动选择最优引擎

### 本地 VLM (Qwen2.5-VL-3B)

- LocalVLMAnalyzer: mlx-swift-lm 集成 (MLXVLM + MLXLMCommon)
- Qwen2.5-VL-3B-Instruct-4bit (~3 GB, 懒下载)
- Vision 策略: Gemini > LocalVLM > LocalVisionAnalyzer

**验收标准：** 全部通过 ✓

- 378 个测试全部通过 (317 + 61 新增)
- 预估总耗时从 ~5:25 降至 ~1:20（约 4x 提速）
- 所有 clip 均有可搜索元数据（不再被 Gemini 限速跳过）

---

## Stage 3.6: 管线修复 ✓

**已完成**

E2E 测试暴露的 4 个管线 bug 修复：

- 批量关键帧提取时间戳 bug（-ss 输入选项导致 t 重置，select 用绝对值不匹配）
- 音频提取门控只检查 WhisperKit（应同时检查 SpeechAnalyzer）
- 语言检测完全依赖 WhisperKit（新增 NLLanguageRecognizer 方案）
- CLI WhisperKit 初始化崩溃（do-catch 降级）

**验收标准：** 全部通过 ✓

- 383 个测试全部通过 (378 + 5 新增)
- 所有 clip 应有 ≥1 帧关键帧

---

## Stage 3.7: VisionField 重构 ✓

**已完成** — 405 tests

引入 `VisionField` 枚举作为 9 个视觉分析字段的单一事实来源，将所有消费方改为数据驱动遍历。

### VisionField 枚举

- 9 个 case: scene, subjects, actions, objects, mood, shotType, lighting, colors, description
- 计算属性: columnName, isArray, includeInTags, embeddingGroup, mergeStrategy, displayLabel
- 静态方法: buildResponseSchema(), buildVLMPrompt(), sqlSetClause(), sqlColumnNames()
- EmbeddingGroup 分组: primary / detail / meta

### 消费方迁移

- VisionAnalyzer.buildResponseSchema() → 委托 VisionField
- LocalVLMAnalyzer.analysisPrompt → VisionField.buildVLMPrompt()
- EmbeddingUtils.composeClipText() → EmbeddingGroup 驱动遍历
- PipelineManager.updateClipVision() → 动态 SQL
- SyncEngine.sync() → 动态 vision 列
- LocalVisionAnalyzer.mergeResults() → 策略驱动合并
- CLI AnalyzeCommand → VisionField 遍历打印

### 效果

- 新增字段从 ~13 处减少到 6 处（其中 2 处由编译器强制提示）
- 零性能退化: 5 条视频测试总耗时 277s (Stage 3.6: 306s, -9%)
- 17 个新增测试 (388 → 405)

**验收标准：** 全部通过 ✓

- 405 个测试全部通过
- E2E 5 视频管线性能持平或改善

---

## Stage 4: macOS App

### 4a: SwiftUI 骨架 ✓

- App 入口 + AppState / SearchState 状态管理
- ContentView: NavigationSplitView + toolbar 搜索框
- SidebarView / ResultsGrid / ClipCard / ThumbnailView
- EmptyStateView / FolderManagementSheet
- 416 个测试全部通过

### 4b+4c: 索引管理 + 并行调度 ✓

- IndexingManager: UI 层索引协调
- IndexingScheduler + ResourceMonitor: 资源池并行调度
- 索引进度 UI (IndexingStatusBar + IndexingDetailSheet)
- 448 个测试全部通过

### 4e: 视频预览 + 键盘导航 ✓

- VideoPreviewPanel: NSPanel + AVPlayerView 浮动预览窗口
  - 帧精确 seek-to-timecode (toleranceBefore/After: .zero)
  - 宽高比自适应 (异步 naturalSize + preferredTransform)
  - 无变形 resize (隐藏→invisible resize→显示; 可见→smooth animate)
  - 智能 seek 策略 (同文件不同片段→新 startTime; 同片段→恢复暂停位置)
  - NSWindowDelegate 关闭行为 (pause + hide, player 进度保留)
  - RAW 格式排除 (braw/r3d/nev)
- QuickLookCoordinator: 统一路由 (视频→VideoPreviewPanel, 其他→QLPreviewPanel)
- 统一键盘导航 (NSEvent.addLocalMonitorForEvents)
- 空格键切换预览，方向键网格导航 + 自动更新预览

### 4f: 上下文菜单 ✓

- 右键菜单：复制时间码、在 Finder 中显示、查看详细标签

### 性能优化 ✓

- VectorStore: BLAS 批量矩阵搜索 (100K clips ~25ms)
- ThumbnailView: CGImageSource 下采样 + NSCache 缓存
- composeClipText: JSON 数组字段解析去噪

### 待实现

- 拖拽到 NLE（NSItemProvider）
- 全局快捷键 ⌘⇧F（后台唤起）
- 批量多选操作扩展
- Smart Folders / 保存的搜索
- 设置页：API Key 管理、当日 API 额度显示
- 热门标签展示（从 clips.tags 统计 TOP N）

**验收标准：**

- 完整的用户流程可走通
- 搜索体验流畅，无明显卡顿
- 离线硬盘素材仍可搜索（不可预览/导出）

---

## 重构: 向量搜索引擎升级 ✓

**已完成** — 940 tests

分层搜索架构重构，引入 CLIP 跨模态搜索 + HNSW 近似最近邻 + 本地文本嵌入。

### R2a: SigLIP2 CLIP 视觉嵌入引擎 ✓

- SigLIP2ImageEncoder + SigLIP2TextEncoder: ONNX FP16 combined 模型
- 768d 跨模态嵌入 (文字搜图片)
- CLIPModelManager + CLIPEmbeddingProvider 协议封装
- CLI `siglip` 命令组
- 821 个测试通过

### R2b: USearch HNSW 双向量索引 ✓

- HNSWIndex actor: USearch 封装 + 自动扩容
- VectorIndexManager: 双索引 (clip.usearch + text.usearch)
- SearchEngine 集成: HNSW 近似搜索替代暴力 cosine
- CLI `hnsw` 命令组
- 855 个测试通过

### R2c: 三路搜索融合 + EmbeddingGemma ✓

- QueryAnalyzer: 查询意图解析 (5 种 intent)
- ThreeWayFusionEngine: CLIP + TextEmbedding + FTS5 三路融合
- 自适应权重: 根据 QueryIntent + 可用索引动态调整
- EmbeddingGemma-300M: ONNX Q8 本地文本嵌入 (768d, 离线)
- 三级回退: Gemini → EmbeddingGemma → nil (FTS5 + CLIP only)
- CLI `gemma` 命令组
- 940 个测试通过

**验收标准：** 全部通过 ✓

- CLIP 跨模态搜索: 文本查询 → 图片向量匹配
- 三路融合: 多维度搜索信号自适应加权
- 离线完全可用: CLIP + EmbeddingGemma + FTS5 无需网络
- HNSW 近似搜索: 100K+ 向量 sub-10ms

