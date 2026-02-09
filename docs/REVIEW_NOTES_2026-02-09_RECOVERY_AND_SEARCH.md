# Review Notes (2026-02-09): Recovery & Search Reliability

## 背景与目标

本次修改聚焦 5 个高优先问题，目标不是“机械改代码”，而是保证以下长期设计目标可持续成立：

1. 外接卷离线/重连在跨重启后仍可恢复（依赖稳定 UUID，而非进程内缓存）。
2. 搜索在窄范围过滤下不丢召回（避免候选过早截断）。
3. 运行时设置变更无需重启即可生效（API Key / ProviderConfig 热更新）。
4. 修复保持最小侵入：不重构主流程，不改变既有断点续传与同步语义。

## 变更总览（按问题映射）

### 1) 卷路径匹配误判（`hasPrefix` 边界问题）

- **原因**: `/Volumes/T7` 会误匹配 `/Volumes/T70/...`，导致错误离线/恢复判定。
- **修复**:
  - 新增边界感知判断：`VolumeResolver.isPath(_:underMountPoint:)`
    - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItCore/Utils/VolumeResolver.swift`
  - `VolumeMonitor` 挂载/卸载判断改用该方法，替换原 `hasPrefix`
    - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItApp/VolumeMonitor.swift`
- **验证测试**:
  - `/Users/cheongzhiyan/Developer/Findit_app/Tests/FindItCoreTests/VolumeResolverTests.swift`
  - 覆盖了 exact match / child match / prefix collision / trailing slash。

### 2) `sync_meta` 缺少卷 UUID/名称（跨重启恢复退化）

- **原因**: 仅存 `folder_path + rowid 游标`，进程重启后无法可靠根据 UUID 恢复挂载点。
- **修复**:
  - 全局迁移新增 `sync_meta.volume_uuid`, `sync_meta.volume_name`
    - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItCore/Database/Migrations.swift`
  - `SyncEngine.sync` 在更新 `sync_meta` 时落库卷信息
    - 优先读取文件夹库 `watched_folders` 中持久化值
    - 缺失时回退 `VolumeResolver.resolve(path:)`
    - `COALESCE` 防止空值覆盖已有元数据
    - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItCore/Database/SyncEngine.swift`
- **验证测试**:
  - schema 列验证：
    - `/Users/cheongzhiyan/Developer/Findit_app/Tests/FindItCoreTests/MigrationsTests.swift`
  - 同步后元数据值验证：
    - `/Users/cheongzhiyan/Developer/Findit_app/Tests/FindItCoreTests/SyncEngineTests.swift`

### 3) 启动恢复依赖内存 cache（跨重启拿不到 UUID）

- **原因**: `reloadFolders()` 只查 `folder_path`，`volumeInfoCache` 重启后为空。
- **修复**:
  - `reloadFolders()` 改为直接读取 `sync_meta.volume_uuid/volume_name`
  - 在线且旧数据缺字段时自动回填 `sync_meta`（一次兼容补齐）
  - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItApp/AppState.swift`
- **效果**:
  - 启动后即使缓存为空，`folders` 也能持有 `volumeUuid`，`reconcilePathsAtStartup()` 可继续工作。

### 4) 向量检索“先截断再过滤”导致窄范围丢召回

- **原因**: `vectorSearchFromStore` 旧实现先 `prefix(900)` 后应用 folder/path 过滤。
- **修复**:
  - 改为分批 `IN` 查询，按相似度序列逐批过滤并收敛到 `limit`
  - 不再在过滤前做固定 topK 截断
  - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItCore/Database/SearchEngine.swift`
- **验证测试**:
  - 新增“1000 个 /A 高分 + 5 个 /B 后段候选”场景，确保 `/B` 可召回
  - `/Users/cheongzhiyan/Developer/Findit_app/Tests/FindItCoreTests/VectorStoreTests.swift`

### 5) API Key / Provider 运行时更新不生效（需重启）

- **原因**:
  - `SearchState` 由 `hasTriedInitProvider` 一次性门控。
  - `IndexingManager` 由 `hasResolvedAPIKey` 一次性门控。
- **修复**:
  - 新增通知：`Notification.Name.runtimeConfigChanged`
    - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItApp/Commands/FolderCommands.swift`
  - Settings 保存 API key / IndexingOptions / ProviderConfig 时统一发通知
    - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItApp/Views/SettingsView.swift`
  - `ContentView` 监听通知并触发刷新：
    - `searchState.refreshRuntimeConfig()`
    - `indexingManager.refreshRuntimeConfig()`
    - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItApp/ContentView.swift`
  - 新增刷新实现：
    - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItApp/SearchState.swift`
    - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItApp/IndexingManager.swift`

## 有意不改动（避免过度优化）

- 本次未改索引主流程并发模型与 checkpoint 策略（避免影响断点续传可靠性）。
- 未引入 ANN 或额外外部依赖；本次仅修复已确认的 correctness/reliability 缺陷。
- 未改动 UI/调度整体架构，仅补充运行时配置失效机制。

## 快速审核入口

1. `sync_meta` 结构与写入：
   - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItCore/Database/Migrations.swift`
   - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItCore/Database/SyncEngine.swift`
2. 启动恢复链路：
   - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItApp/AppState.swift`
   - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItApp/VolumeMonitor.swift`
3. 向量过滤召回：
   - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItCore/Database/SearchEngine.swift`
   - `/Users/cheongzhiyan/Developer/Findit_app/Tests/FindItCoreTests/VectorStoreTests.swift`
4. 运行时热更新：
   - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItApp/Views/SettingsView.swift`
   - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItApp/ContentView.swift`
   - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItApp/SearchState.swift`
   - `/Users/cheongzhiyan/Developer/Findit_app/Sources/FindItApp/IndexingManager.swift`

## 验证结果

- `swift test` 通过（含新增测试）。
- `swift build --target FindItApp` 通过。
