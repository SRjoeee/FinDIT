# Review Notes — Audio-less Video FFmpeg Fallback (2026-02-09)

## 问题现象

索引过程中，部分视频报错：

- `Output file does not contain any stream`
- `Error opening output files: Invalid argument`
- UI 显示为 `FFmpeg 退出码 ...`

这些视频通常只有视频流/数据流（如 `tmcd`），没有可提取的音轨。

## 根因（设计层）

当前管线在 FFmpeg 准备阶段做了单次合并调用：

1. 场景检测（视频流）
2. 音频提取到 WAV（音频流）

该优化路径在“有音轨”时性能更好，但在“无音轨”输入下会让 FFmpeg 整次命令非零退出，导致视频在场景阶段直接失败。  
这与产品目标“STT 失败不致命、主索引应继续”不一致。

## 修复策略（全局最优）

保留性能主路径，不牺牲常规场景吞吐：

1. 先执行原单次合并调用（场景+音频）。
2. 若命中“无音轨”特征错误，仅对该视频回退到“仅场景检测”调用。
3. 返回 `audioExtracted=false`，后续显式跳过 STT，不再二次尝试音频提取。

这保证：

- 有音轨视频：性能不变（仍 1 次 FFmpeg）。
- 无音轨视频：不再整条失败，进入“无字幕但可检索视觉/场景”的可用状态。
- 其他 FFmpeg 错误：仍保持失败语义，不会被误吞。

## 改动文件

- `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItCore/Pipeline/FFmpegBridge.swift`
  - 新增 `isMissingAudioStreamError(stderr:)` 错误分类函数。
- `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItCore/Pipeline/SceneDetector.swift`
  - `detectScenesOptimized` 增加无音轨回退逻辑。
  - `CombinedDetectionResult` 增加 `audioExtracted` 标记。
- `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItCore/Pipeline/PipelineManager.swift`
  - 根据 `audioExtracted` 跳过 STT，并提示“视频无音轨，跳过语音转录”。
- `/Users/cheongzhiyan/Developer/Findit_app/Tests/FindItCoreTests/FFmpegBridgeTests.swift`
  - 新增无音轨错误识别单元测试。

## 审核重点

1. 仅“无音轨”错误触发回退，其他错误仍上抛失败。
2. 回退后场景检测结果与原逻辑一致（仅跳过音频提取）。
3. `audioExtracted=false` 时不再进入 STT 音频提取路径。
4. 有音轨场景不受影响（无额外进程开销）。

## 验证命令

- `swift test --filter FFmpegBridgeTests`
- `swift test --filter SceneDetectorTests`
- `swift test --filter PipelineManagerTests`
- `swift test`
