# Review Notes (2026-02-09): Indexing Recovery + Path Rebase Consistency

## 背景与修复目标

本次修复针对 3 个真实缺陷，目标是保证以下长期不变量：

1. 文件夹恢复后，索引任务一定会自动继续。
2. 父文件夹重扫时，子文件夹排除规则稳定且与当前注册状态一致。
3. 卷挂载点变化后，"文件夹库" 与 "全局库" 的路径字段保持一致，不出现静默漏同步。

这些问题不是“暂时现象”或“刻意设计”。它们会导致可观察的错误结果（漏索引、路径不一致、恢复后数据缺失），因此需要修复。

## 修改点与定位

### 1) 启动恢复任务缺失
- 文件: `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItApp/ContentView.swift`
- 位置: `ContentView.task` 初始化流程
- 修改: 在 `appState.initialize()` + `startWatching()` 后，显式调用 `indexingManager.indexPendingFolders()`。
- 原因: 启动后未恢复 pending/failed/orphan 路径，导致“设计上可恢复，实际不恢复”。

### 2) 父文件夹排除规则在重扫时不稳定
- 文件: `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItApp/IndexingManager.swift`
- 位置 A: `indexPendingFolders()`
- 修改 A: 仅对 `isAvailable == true` 的文件夹恢复入队。
- 原因 A: 离线卷应由 `VolumeMonitor` 恢复后再入队，避免无效扫描。

- 位置 B: `processFolder(_:)`
- 修改 B: 排除集合改为 “显式排除 + 当前注册文件夹动态父子关系” 的并集。
- 原因 B: 只依赖一次性入队参数会在后续重扫丢失排除语义；动态计算可保证长期一致。

### 3) 路径重定向时全局镜像可能不完整
- 文件: `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItApp/VolumeMonitor.swift`
- 位置: `updateFolderPath(from:to:)`
- 修改:
  - 先执行 `PathRebaser.rebaseIfNeeded(folderDB:newPath)` 修复文件夹库（source of truth）。
  - 同步更新全局库中的 `sync_meta.folder_path`、`videos.source_folder`、`clips.source_folder`。
  - 增补更新 `videos.srt_path` 与 `clips.thumbnail_path` 前缀。
  - 若文件夹库发生重定向，则执行一次 `SyncEngine.sync(..., force: true)` 覆盖 rowid 不变但字段已改的场景。
- 原因: 仅做增量同步可能看不到“rowid 未变但路径字段已变”的记录，造成全局搜索镜像陈旧。

## Reviewer 快速检查清单

1. 启动路径
- 查看 `ContentView.task` 是否在初始化后调用了 `indexPendingFolders()`。

2. 排除规则
- 查看 `IndexingManager.processFolder(_:)` 是否每次都基于当前 `appState.folders` 重新计算子目录排除。

3. 路径一致性
- 查看 `VolumeMonitor.updateFolderPath(from:to:)` 是否满足顺序：
  - 先 rebase folderDB
  - 再更新 globalDB 路径字段
  - rebase 发生时再 force sync

4. 回归验证
- `swift build --target FindItApp`
- `swift test --filter IndexingSchedulerTests`
- `swift test --filter PathRebaserTests`
- `swift test --filter SyncEngineTests`

## 本次未改动（有意）

- 未引入额外的批量/异步复杂度到 UI 初始化流程，保持启动路径最小改动。
- 未改动现有数据库 schema，仅修复流程与同步一致性，控制变更半径。
