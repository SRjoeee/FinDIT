# 当前阶段: Stage 1 — 存储层

## 进行中

_无_

## 待办

### 1a: 文件夹级 SQLite
- [x] 创建 Migrations.swift — DatabaseMigrator 版本化迁移
- [x] 创建 Models.swift — WatchedFolder, Video, Clip Record 类型
- [x] 实现 CRUD 操作（插入/查询/更新/删除）
- [x] 单元测试: 内存数据库测试 CRUD

### 1b: 全局搜索索引
- [x] 创建全局库 Schema（clips 镜像, videos 镜像, clips_fts, search_history）
- [x] FTS5 虚拟表建表 + content sync triggers
- [x] FTS5 搜索实现（关键词、前缀、精确、排除）
- [x] 单元测试: FTS5 搜索测试

### 1c: 同步引擎
- [x] 创建 SyncEngine.swift — 文件夹库 → 全局库同步
- [x] 增量同步逻辑（基于 rowid / 时间戳）
- [x] 单元测试: 同步正确性

### 1d: CLI 验证
- [x] CLI `db-init` 子命令 — 初始化数据库 + 注册 WatchedFolder
- [x] CLI `insert-mock` 子命令 — 插入 3 视频 7 片段中英混合模拟数据
- [x] CLI `search` 子命令 — FTS5 搜索 + 格式化结果 + 搜索历史
- [x] CLI `sync` 子命令 — 手动触发增量同步
- [x] 端到端验证: db-init → insert-mock → sync → search (中文/英文/OR 语法)

## 已完成（Stage 0）

- [x] 创建项目文档体系 (CLAUDE.md, ROADMAP, TASKS, ARCHITECTURE, TECH_DECISIONS, PRODUCT_SPEC)
- [x] 创建 .gitignore
- [x] 创建 Package.swift（GRDB v6.29.x + ArgumentParser 依赖）
- [x] 创建 Sources/FindItCore/ 目录 + 占位文件
- [x] 创建 Sources/FindItCLI/CLI.swift
- [x] 创建 Tests/FindItCoreTests/ + 占位测试
- [x] 验证: `swift build` 通过, `swift run findit-cli --help` 通过
- [x] Git init + commit + tag `v0.0-skeleton`
- [x] 产品说明书 review + 技术决策补充 (ADR-008 ~ ADR-013)
- [x] 验证 `swift test` + `swift build` 在 Xcode 环境下通过
- [x] 创建 DatabaseManager.swift — 连接管理、WAL 模式、路径解析 + StorageError
