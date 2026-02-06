# FindIt 开发路线图

## 开发范式

**内核优先 + CLI 验证 + 逐步穿壳**

先用 Swift Package 构建纯逻辑内核（FindItCore），通过 CLI 命令验证每一层功能，全部跑通后再套上 SwiftUI 界面。

---

## Stage 0: 项目骨架 ✓

**Tag: `v0.0-skeleton`** — 已完成

- [x] 项目文档体系（CLAUDE.md, ROADMAP, TASKS, ARCHITECTURE, TECH_DECISIONS）
- [x] Package.swift + 依赖声明（GRDB v6.29.x + swift-argument-parser）
- [x] 源文件目录结构 + 占位文件
- [x] CLI 入口（swift-argument-parser）
- [x] `swift build` 编译通过
- [x] `swift run findit-cli --help` 显示帮助信息
- [x] Git init + 2 commits + tag `v0.0-skeleton`

> 注: `swift test` 需要安装完整 Xcode（CLT 不含 XCTest）

---

## Stage 1: 存储层

**Tag: `v0.1-storage`**

### 1a: 文件夹级 SQLite
- [ ] GRDB DatabaseManager — 连接管理 + WAL 模式
- [ ] DatabaseMigrator 版本化迁移系统
- [ ] 文件夹库 Schema: watched_folders, videos, clips 三张核心表
- [ ] CRUD 操作封装（GRDB Record 类型）

### 1b: 全局搜索索引
- [ ] 全局库 Schema: clips 镜像, videos 镜像, clips_fts, search_history
- [ ] FTS5 虚拟表创建（tags + description + transcript）
- [ ] FTS5 搜索：关键词 / 前缀匹配 / 引号精确 / 排除词

### 1c: 同步引擎
- [ ] SyncEngine: 文件夹库 → 全局搜索索引同步
- [ ] 增量同步（基于时间戳 / rowid）
- [ ] 全量重建（文件夹新增/删除时）

### 1d: CLI 验证
- [ ] CLI 命令: `db init` — 初始化文件夹库 + 全局库
- [ ] CLI 命令: `insert-mock` — 插入模拟数据
- [ ] CLI 命令: `search <query>` — FTS5 搜索
- [ ] CLI 命令: `sync` — 手动触发同步

**验收标准：**
- CLI 插入模拟数据后搜索返回正确结果
- 精确搜索、排除搜索均工作正常
- 文件夹库数据正确同步到全局搜索索引
- 所有数据库测试通过

---

## Stage 2: 处理管线

**Tag: `v0.2-pipeline`**

### 2a: FFmpeg 集成
- [ ] FFmpegBridge：子进程调用封装
- [ ] 音频提取：视频 → 16kHz mono WAV
- [ ] 场景检测：`select='gt(scene,0.3)'` + 时间戳解析
- [ ] 关键帧抽取：按场景切点 + 长镜头均分补帧
- [ ] 图片压缩：短边 512px, JPEG quality 80

### 2b: WhisperKit STT
- [ ] WhisperKit 初始化 + 模型下载管理
- [ ] 音频转录（word-level timestamps）
- [ ] SRT 文件生成（优先视频同目录，降级到 App 目录）
- [ ] 台词文本按片段时间范围切分入库

### 2c: Gemini Flash 视觉分析
- [ ] REST API 调用封装（URLSession）
- [ ] 多帧批量发送 + 结构化 JSON 输出
- [ ] API Key 管理（macOS Keychain）
- [ ] 速率限制 + 重试逻辑
- [ ] API 额度管理（调用计数、接近限额自动暂停）
- [ ] Tags 提取：从 JSON 各字段去重合成 JSON 数组

### 2d: 管线串联
- [ ] PipelineManager 状态机 (pending → stt_running → stt_done → vision_running → completed)
- [ ] 断点续传（last_processed_clip）
- [ ] 并发控制（同时处理 1-2 个文件）
- [ ] 错误处理 + 失败重试
- [ ] 索引完成后自动触发 SyncEngine

**验收标准：**
- CLI 指定真实视频文件 → 全流程自动处理 → 数据入库
- SRT 文件内容合理（中英文均可识别）
- 场景切割点合理（无过度切碎或遗漏）
- Gemini 返回的 JSON 描述有意义
- tags 字段为正确的 JSON 数组

---

## Stage 3: 搜索引擎

**Tag: `v0.3-search`**

- [ ] BGE-M3 ONNX 模型加载（onnxruntime）
- [ ] 文本 tokenization（swift-transformers 或自实现）
- [ ] 向量嵌入计算 + 存储（SQLite BLOB, 1024 维 float32）
- [ ] 余弦相似度全量扫描
- [ ] 混合搜索：FTS5 + 向量 + 融合排序（min-max 归一化）
- [ ] 搜索策略自适应（引号 → 精确优先，长句 → 语义优先）
- [ ] 搜索历史记录（写入 search_history 表）

**验收标准：**
- CLI 输入自然语言描述 → 语义相关的片段排在前面
- "海边夕阳" 能匹配 "海滩日落" 的描述
- 搜索延迟 < 200ms（20,000 条记录）

---

## Stage 4: macOS App

**Tag: `v0.4-app`**

- [ ] Xcode 项目创建，引入 FindItCore
- [ ] 搜索框 + 实时搜索（FTS5 即时 + 向量 300ms debounce）
- [ ] 缩略图网格视图（LazyVGrid）
- [ ] 侧边栏素材库管理（文件夹添加/删除/状态）
- [ ] Quick Look 预览（QLPreviewPanel + 空格键）
- [ ] 筛选栏（匹配类型 + 来源文件夹）+ 排序
- [ ] 右键菜单（复制时间码、Finder 显示、导出、查看标签）
- [ ] NLE 导出（EDL + FCPXML，单个/批量）
- [ ] 拖拽到 NLE（NSItemProvider）
- [ ] 后台任务管理面板（进度、暂停/恢复/取消）
- [ ] 全局快捷键 ⌘⇧F（后台唤起）
- [ ] 外接硬盘监听（DiskArbitration）
- [ ] 系统通知（索引完成/失败/硬盘恢复）
- [ ] 设置页：API Key 管理、当日 API 额度显示
- [ ] 热门标签展示（从 clips.tags 统计 TOP N）

**验收标准：**
- 完整的用户流程可走通
- 搜索体验流畅，无明显卡顿
- 离线硬盘素材仍可搜索（不可预览/导出）
