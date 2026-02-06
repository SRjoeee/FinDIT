# FindIt — macOS 视频素材自然语言搜索应用

## 项目类型

这是一个 **Swift Package** 项目（非 Node.js/Bun）。请忽略上级 CLAUDE.md 中的 Bun 相关指令。

## 构建与运行

- `swift build` — 编译项目
- `swift test` — 运行全部测试
- `swift run findit-cli <subcommand>` — CLI 验证工具
- FFmpeg 路径: `~/.local/bin/ffmpeg`
- FFprobe 路径: `~/.local/bin/ffprobe`

## 编码规范

- Swift 6.0，Package 声明最低 macOS 14，macOS 15+ API 通过 `@available` 使用
- 使用 async/await 处理异步操作，避免回调
- 错误处理：定义明确的 Error enum，禁止 try! / force unwrap
- 命名遵循 Swift API Design Guidelines（驼峰命名）
- 每个公开 API 必须有简短文档注释（`///` 格式）

## 依赖管理

严格控制第三方依赖数量，优先使用系统框架：
- SQLite: GRDB.swift v6.29.x
- CLI 框架: swift-argument-parser
- STT: WhisperKit（Stage 2 启用）
- 向量推理: onnxruntime（Stage 3 启用）

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
