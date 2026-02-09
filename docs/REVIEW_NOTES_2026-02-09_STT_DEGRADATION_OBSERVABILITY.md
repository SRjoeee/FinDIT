# Review Notes — STT 无音轨降级可观测性 (2026-02-09)

## 修复原因

上一轮已修复“无音轨视频导致整条索引失败”的核心问题，但当前实现仍有一个产品层缺口：

1. Pipeline 内部知道“无音轨，已跳过 STT”，但该信号没有传到调度层和 UI。
2. 用户和 reviewer 在进度界面只能看到“完成/失败”，无法区分“成功但降级”。
3. 这会降低可观测性，影响排障效率和回归验证。

该问题是**真实缺陷**（observability 缺失），不是“有意设计”。

## 全局方案（不牺牲性能）

本次采用“只传递已存在信号，不新增额外 I/O/推理”的方案：

1. 在 `PipelineManager.ProcessingResult` 增加 `sttSkippedNoAudio` 标记。
2. 在 `IndexingScheduler.VideoOutcome` 透传该标记。
3. `IndexingManager` 仅在内存进度结构中累计：
   - `sttSkippedNoAudioVideos`
   - `nonFatalIssues`（降级详情列表）
4. UI 将“已降级”与“错误”分开展示，避免把非致命情况误报为失败。
5. CLI 汇总增加“无音轨跳过 STT”计数，便于自动化回归日志审阅。

该方案的复杂度和运行时开销都近似 O(1)（仅字段透传 + 内存计数），不影响索引吞吐。

## 代码定位（供 reviewer 快速核查）

- 结果模型透传
  - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItCore/Pipeline/PipelineManager.swift`
  - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItCore/Scheduling/IndexingScheduler.swift`

- 进度/统计与日志
  - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItApp/IndexingManager.swift`
  - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItCLI/CLI.swift`

- UI 可视化（非致命降级）
  - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItApp/Views/IndexingDetailSheet.swift`
  - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItApp/Views/IndexingStatusBar.swift`
  - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItApp/Views/FolderManagementSheet.swift`
  - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItApp/Views/SidebarView.swift`

- 测试补充
  - `/Users/cheongzhiyan/Developer/Findit_app/Tests/FindItCoreTests/IndexingSchedulerTests.swift`

## Reviewer 验证清单

1. 含音轨视频路径：行为与性能无变化（无新增同步点、无新增 DB 查询）。
2. 无音轨视频路径：任务应为成功完成，且出现“无音轨跳过 STT”统计/条目。
3. 错误路径：仍只计入 `failedVideos/errors`，不混入降级统计。
4. 进度环和完成状态：仅失败影响告警色；降级不改变失败语义。
