# FindIt MCP Server 改进记录

> 基于 AI 实际使用 MCP 进行视频混剪的完整体验，系统性地发现并修复了 MCP 工具链的问题。
> 本分支包含从最初的向量搜索修复到完整的 MCP 工具链增强的所有变更。

---

## 背景

FindIt 是一个视频素材管理工具，通过 MCP (Model Context Protocol) 为 AI 提供视频片段搜索和浏览能力。在 AI 实际使用 MCP 完成视频混剪任务的过程中，我们发现了一系列影响效率的问题，并逐步修复和增强。

### 核心架构

- **双 SQLite 架构**：文件夹级 DB（原始 vision 数据，tags 以 JSON 数组存储）+ 全局搜索索引（由 SyncEngine 同步，tags 转为空格分隔的 FTS5 格式）
- **混合搜索引擎**：FTS5 全文搜索 + 向量余弦相似度（VectorStore + BLAS/vDSP）
- **MCP Server**：Swift 6 实现，严格 Sendable 模式

---

## 变更总览（按 commit 时序）

### 已提交的 commits

| Commit | 类型 | 说明 |
|--------|------|------|
| `c75405b` | fix | **SearchTool 向量搜索修复** — hybridSearch() 调用时未传 queryEmbedding，导致向量搜索从未激活 |
| `8f4d6a0` | feat | **新增 browse_all_clips 工具** — AI 可一次批量读取素材库全部片段（分页、过滤、排序） |
| `c885c61` | fix | **get_video_detail 补全 vision 字段** — 每个 clip 补全 description/mood/lighting/colors/shotType/subjects/actions/objects |
| `fcee68c` | feat | **SearchResult 补全 vision 字段** — subjects/actions/objects/lighting/colors 加入搜索结果 |
| `fe1d8b4` | feat | **FTS5 索引扩展至 10 列** — 从 4 列(tags/description/transcript/user_tags) 扩展到 10 列，新增 scene/subjects/actions/objects/mood/shot_type，配合加权 BM25 排名 |

### 本次待提交的变更（6 项 MCP 工具链增强）

基于 AI 使用上述功能完成一次完整视频混剪后的反馈，进一步优化：

| # | 文件 | 类型 | 说明 |
|---|------|------|------|
| 1 | `TagParsingHelpers.swift` | 新建 | 全局 DB tags 解析工具 |
| 2 | `BrowseAllClipsTool.swift` | 修改 | 补 filePath、修 tags 解析、新增过滤参数 |
| 3 | `SearchTool.swift` | 修改 | tags 格式统一、新增 folder/offset 参数 |
| 4 | `GetLibrarySummaryTool.swift` | 新建 | 素材库概览工具 |
| 5 | `ToolRegistry.swift` | 修改 | 注册新参数和新工具 |

---

## 详细变更说明

### 1. Tags 解析修复（P0 Bug Fix）

**问题**：`browse_all_clips` 的 tags 字段始终返回空数组 `[]`。

**根因**：
- 文件夹级 DB 存储 tags 为 JSON 数组：`["海滩","户外","全景"]`
- SyncEngine.convertTagsForFTS() 在同步到全局 DB 时转为空格分隔：`海滩 户外 全景`
- `BrowseAllClipsTool` 使用 `parseJSONArray()` 解析全局 DB 的 tags → JSON 解析失败 → 返回 `[]`

**修复**：
- 新建 `TagParsingHelpers.swift`，提供 `parseTagsFromGlobalDB()` 方法
- 先尝试 JSON 数组格式（兜底未转换的 edge case），失败则按空格分割
- `BrowseAllClipsTool` 和 `SearchTool` 统一使用此方法
- 删除 `BrowseAllClipsTool` 中错误的私有 `parseJSONArray()` 方法

**影响**：修复数据展示 bug，无性能影响。

### 2. browse_all_clips 补 filePath（P0 Enhancement）

**问题**：AI 在生成 FFmpeg 命令时需要视频文件的完整路径，但 `browse_all_clips` 只返回 `fileName`（如 `C0001.MP4`），无法直接用于命令行操作。

**修复**：SQL SELECT 新增 `v.file_path`，ClipItem struct 新增 `filePath: String?` 字段。

**影响**：JOIN 查询多取一列，性能影响可忽略。

### 3. search 返回格式统一（P0 Consistency）

**问题**：
- `search` 返回 `tags: String?`（原始空格分隔字符串），而 `browse_all_clips` 返回 `tags: [String]`（数组），格式不一致
- `search` 缺少 `userTags` 和 `filePath` 字段

**修复**：
- `tags` 从 `String?` 改为 `[String]`，使用 `TagParsingHelpers.parseTagsFromGlobalDB()`
- 新增 `userTags: [String]` 和 `filePath: String?` 字段（SearchResult 已有这些数据，只是之前未映射到输出）

**影响**：**Breaking Change** — `tags` 字段从字符串变为数组。由于 MCP 客户端均为 AI agent，不存在向后兼容负担。

### 4. search 新增 folder 参数（P1 Enhancement）

**问题**：AI 搜索时无法限定文件夹范围，导致跨项目结果混杂。

**修复**：
- 新增 `folder: String?` 参数
- 转为 `Set<String>` 传递给 `SearchEngine.hybridSearch()` 已有的 `folderPaths` 参数
- 不修改 SearchEngine 核心代码

**设计决策**：使用单个 string 而非数组，与 `browse_all_clips` 保持一致。`hybridSearch` 底层已支持多文件夹，未来如有需求可扩展。

**影响**：指定 folder 时搜索范围缩小（SQL WHERE 过滤），**性能正向提升**。

### 5. search 新增 offset 分页（P1 Enhancement）

**问题**：search 只有 `limit` 无 `offset`，AI 无法翻页浏览后续结果。

**修复**：
- 新增 `offset: Int` 参数（默认 0，校验非负）
- 向 hybridSearch 请求 `offset + limit` 条结果
- FilterEngine 过滤后，`results.dropFirst(offset).prefix(limit)` 内存切片

**设计决策**：选择内存切片而非引擎级 offset。理由：
1. hybridSearch 的融合排名逻辑复杂（FTS5 BM25 + 向量余弦 + 权重融合），加入 offset 会大幅增加核心引擎复杂度
2. MCP 场景下 AI 的 offset 通常 <50，内存切片的额外开销可忽略
3. 不修改 SearchEngine 核心代码 = 零风险

**影响**：大 offset 时会多取数据再丢弃，但对典型使用场景（offset <50）影响可忽略。

### 6. browse_all_clips 新增 shot_types/moods 过滤（P1 Enhancement）

**问题**：AI 在大量素材中筛选特定镜头类型或氛围时，只能全量读取后在 context 中手动过滤，浪费 token。

**修复**：
- 新增 `shot_types: [String]?` 和 `moods: [String]?` 参数
- SQL 层面 `WHERE c.shot_type IN (?, ?)` 和 `WHERE c.mood IN (?, ?)` 过滤
- 使用参数化查询（GRDB StatementArguments），防止 SQL 注入

**影响**：SQL WHERE 过滤比内存过滤更高效，**性能正向提升**。

### 7. 新增 get_library_summary 工具（P2 New Tool）

**问题**：AI 在开始工作前需要了解素材库的整体结构，但没有快速获取概览的方式。只能调用 `get_stats`（基础计数）或 `browse_all_clips`（逐页读取）。

**修复**：新建 `GetLibrarySummaryTool`，一次返回：
- 基础统计：文件夹数、视频数、片段数、总时长
- 文件夹分布：每个文件夹的视频数、片段数、时长
- 分面统计：镜头类型分布、氛围分布、评分分布、颜色标签分布

**设计决策**：复用已有的 `FilterEngine.availableFacets()` 获取分面数据（DRY 原则），不引入新的查询逻辑。

**影响**：4-5 个 GROUP BY 聚合查询，总耗时 <200ms（1165 clips 的实测库）。

---

## 安全性

- 所有 SQL 查询使用 GRDB 参数化（`?` 占位符 + `StatementArguments`），防止 SQL 注入
- ORDER BY 使用白名单校验（switch-case 硬编码列名），非用户输入直接拼接
- offset 参数校验非负（`max(..., 0)`）
- limit 参数有上限约束（browse_all_clips 最大 500）

## 兼容性

- 所有新参数均为可选（optional），不传时行为与改进前一致
- `tags` 字段从 `String?` 改为 `[String]` 是唯一的 Breaking Change，但 MCP 客户端均为 AI agent，无人工依赖
- 不修改 FindItCore 核心库（SearchEngine/FilterEngine/SyncEngine），零风险

## 构建验证

```bash
swift build --product findit-mcp-server  # MCP server 构建零错误
swift build                               # 全项目构建零错误
```

## MCP 工具验证结果

| 工具调用 | 预期 | 实际 |
|---------|------|------|
| `browse_all_clips {limit: 2}` | tags 为数组，有 filePath | tags 正确解析，filePath 返回完整路径 |
| `browse_all_clips {shot_types: ["特写"]}` | 只返回特写镜头 | total 从 1165 降至 68，全部为特写 |
| `search {query: "对话", folder: "/Users/.../Movies"}` | 限定文件夹 | 结果全部来自指定文件夹 |
| `search {query: "舞台", offset: 5, limit: 2}` | 跳过前 5 条 | 从第 6 条开始返回 |
| `search {query: "海滩", limit: 2}` | tags 为数组，有 filePath/userTags | 全部字段正确 |
| `get_library_summary {}` | 返回完整统计 | 3 文件夹、20 种 mood、20 种 shotType 分布 |
