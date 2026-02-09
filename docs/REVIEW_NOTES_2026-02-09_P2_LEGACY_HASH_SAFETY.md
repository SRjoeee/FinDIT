# Review Notes — P2 Legacy Hash Safety (2026-02-09)

## 背景

目标是修复 `completed + file_hash == nil` 的遗留分支风险，同时不牺牲整体性能。

原行为：

- 当已完成视频的 `file_size`/`file_modified` 变化且 `file_hash` 为空时，
  仅“补充 hash 后跳过”。
- 风险：如果内容确实变了，旧索引可能被静默复用。

## 修复策略（安全与性能平衡）

在 `PipelineManager.processVideo(...)` 中将该分支改为双路径：

1. **文件大小明确变化**（`old != new` 且两者都非空）  
   进入 `pending` 重建流程，避免陈旧索引。
2. **仅 mtime 变化**（或 size 无法可靠比较）  
   仅回填 `file_hash` 并保持快速跳过，避免不必要重建。

这保证：

- 高置信内容变化会被修复；
- 常见“仅时间戳抖动”场景不增加管线耗时。

## 代码位置

- 逻辑修改：
  - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItCore/Pipeline/PipelineManager.swift`
- 回归测试：
  - `/Users/cheongzhiyan/Developer/Findit_app/Tests/FindItCoreTests/PipelineManagerTests.swift`

## 同事审核重点

1. `hasReliableSizeChange` 条件是否符合预期（仅在 size 可比较且变化时触发重建）。
2. 重建分支是否正确清理状态：
   - `index_status = pending`
   - `index_error = NULL`
   - `last_processed_clip = NULL`
   - `file_hash = NULL`
3. 回填分支是否保持原有快速跳过体验，并写入新 hash。

## 新增测试

1. `testProcessVideo_completedWithoutHashAndSizeChange_reindexes`
   - 验证 size 变化时进入重建分支。
2. `testProcessVideo_completedWithoutHashAndOnlyMtimeChange_backfillsHashAndSkips`
   - 验证仅 mtime 变化时回填 hash 并跳过重建。

## 验证命令

- `swift test --filter PipelineManagerTests`
- `swift build --target FindItApp`
- `swift test`
