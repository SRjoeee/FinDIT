# FindIt — macOS 视频素材自然语言搜索应用

## 项目类型

这是一个 **Swift Package** 项目（非 Node.js/Bun）。请忽略上级 CLAUDE.md 中的 Bun 相关指令。

## 构建与运行

- `swift build` — 编译项目
- `swift test` — 运行全部测试（**需要安装完整 Xcode**，CLT 不含 XCTest）
- `swift run findit-cli <subcommand>` — CLI 验证工具
- FFmpeg 路径: `~/.local/bin/ffmpeg`
- FFprobe 路径: `~/.local/bin/ffprobe`

## 编码规范

- Swift 编译器 6.0.0-dev，但 swift-tools-version 为 **5.9**（6.0 的 `.macOS(.v15)` 在当前 CLT 下不可用）
- Package 声明最低 macOS 14，macOS 15+ API 通过 `@available` 使用
- 使用 async/await 处理异步操作，避免回调
- 错误处理：定义明确的 Error enum，禁止 try! / force unwrap
- 命名遵循 Swift API Design Guidelines（驼峰命名）
- 每个公开 API 必须有简短文档注释（`///` 格式）

## 依赖管理

严格控制第三方依赖数量，优先使用系统框架：
- SQLite: GRDB.swift **v6.29.x**（v7 需 swiftLanguageModes 支持，当前 CLT 不兼容）
- CLI 框架: swift-argument-parser
- STT: WhisperKit（Stage 2 启用）
- 向量推理: onnxruntime（Stage 3 启用）

## 存储架构：双层 SQLite

- **文件夹级库** `<素材文件夹>/.clip-index/index.sqlite` — Source of truth，存原始索引数据，便携
- **全局搜索索引** `~/Library/Application Support/FindIt/search.sqlite` — 聚合缓存，含 FTS5 + 向量 + search_history
- 全局库删了可从文件夹库重建；文件夹库随素材文件夹移动

## 数据格式约定

- `clips.tags` 存储为 JSON 数组: `["海滩", "户外", "全景"]`
- FTS5 同步时 tags 展开为空格分隔文本
- SRT 文件优先写视频同目录，失败降级到 `~/Library/Application Support/FindIt/srt/`

## 测试规范

- 每个模块必须有对应的测试文件
- 使用 XCTest，遵循 AAA 模式 (Arrange-Act-Assert)
- 数据库测试使用内存数据库 (`:memory:`)
- 外部依赖 (FFmpeg, API) 通过 protocol 抽象以便 mock

## Git 规范

- Conventional Commits: `feat:`, `fix:`, `test:`, `docs:`, `refactor:`
- 每个功能点一个 commit，不堆积大 commit
- 阶段完成打 tag: `v0.0-skeleton`, `v0.1-storage`, `v0.2-pipeline`...

## 项目结构

```
Sources/FindItCore/  — 核心库，零 UI 依赖，可独立测试
Sources/FindItCLI/   — 命令行验证工具，调用 Core 接口
Tests/               — 与 Sources 一一对应的测试
docs/                — 项目文档（路线图、架构、技术决策等）
```

## 开发流程

每次开始工作时，遵循以下循环：

### 1. 计划阶段
- 读取 `docs/TASKS.md` 找到当前阶段的下一个待执行任务
- 向用户简要说明：要做什么、预期输出、验证方式
- **等用户确认后再开始写代码**

### 2. 执行阶段
- 实现功能代码
- **Core 层任务**（数据库、模型、搜索引擎等）：同时编写单元测试，完成后运行 `swift test`
- **CLI 层任务**（命令行入口）：CLI 是薄封装，不写单元测试，通过 `swift run findit-cli` 手动验证

### 3. 验收阶段
- Core 层：展示 `swift test` 输出（截断过长内容）
- CLI 层：展示 `swift run findit-cli <command>` 的运行结果
- 如果有需要用户手动验证的内容（比如 CLI 输出、SRT 文件），告诉用户具体验证方式和文件位置
- **等用户确认"通过"**

### 4. 收尾阶段
- 用户确认通过后，按文件名 `git add` 相关文件并 commit
- 更新 `docs/TASKS.md` 标记完成，阶段完成时更新 `docs/ROADMAP.md`
- 告诉用户下一个任务是什么，简要说明计划

### 重要规则
- **每次只做一个任务**，不要跳步
- 写代码前先说计划，不要直接动手
- commit 前必须测试通过
- 如果测试失败，先尝试自己修复，修复后重新跑测试
- 如果连续修复 3 次仍未通过，停下来跟用户讨论
- **禁止为了通过测试而删除测试、注释断言或降低验收标准**
