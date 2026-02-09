# Review Notes (2026-02-09): P1 搜索召回 + MainActor I/O

## 目标

这轮修复只做两个 P1，且都直接对应产品长期目标：

1. **窄范围搜索不漏召回**（不因实现细节丢结果）。
2. **后台索引不拖慢前台交互**（主线程保持可响应）。

修复原则：不改业务语义、不改状态机，只修正关键路径的执行位置与候选过滤策略。

---

## 问题 1：过滤场景下向量搜索漏召回

### 原因

`SearchState` 先从 `VectorStore` 取全局 top100，再做 folder/path 过滤。  
当过滤范围很窄时，目标结果可能完全不在全局 top100 中，造成 false negative。

### 修复

1. `VectorStore.search` 新增 `allowedClipIDs` 参数，支持“先过滤候选，再排序取 Top-K”。
2. `SearchState` 在有 folder/path 过滤时先查 `clip_id` 集合，再传给 `VectorStore`。
3. 加入过滤缓存，避免用户持续输入时重复查同一批 `clip_id`。

### 代码位置

- `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItCore/Search/VectorStore.swift`
- `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItApp/SearchState.swift`

### 验证

- 新增单测：
  - `/Users/cheongzhiyan/Developer/Findit_app/Tests/FindItCoreTests/VectorStoreTests.swift`
  - 覆盖允许集合过滤与“无匹配返回空”。

---

## 问题 2：IndexingManager 在 MainActor 执行阻塞 I/O

### 原因

`IndexingManager` 是 `@MainActor` 状态对象，目录扫描与数据库打开在主 Actor 路径执行，  
文件夹大/磁盘慢时会阻塞 UI 事件处理。

### 修复

1. 新增 `runBlockingIO`（后台 utility queue 执行阻塞 I/O）。
2. 将以下阻塞操作迁到后台执行：
   - `FileScanner.scanVideoFiles`
   - `DatabaseManager.openFolderDatabase`（全量与增量入口）

### 代码位置

- `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItApp/IndexingManager.swift`

### 设计说明

- UI 状态仍由 `@MainActor` 统一维护（进度、当前阶段、队列状态）。
- 仅把“纯阻塞 I/O”下沉，不改变调度器、状态机和错误处理语义。

---

## 回归结果

- `swift test` 通过。
- `swift build --target FindItApp` 通过。

---

## 建议 reviewer 快速检查点

1. `VectorStore.search` 是否在允许集合内排序（而不是排序后过滤）。
2. `SearchState` 的过滤缓存是否在 filter 变化、store 失效、配置刷新时正确清空。
3. `IndexingManager` 是否仅下沉阻塞 I/O，且 UI 状态更新仍在 MainActor。
