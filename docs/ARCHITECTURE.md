# FindIt 技术架构

## 分层架构

```
┌─────────────────────────────────────────────┐
│           macOS App (SwiftUI)               │  ← Stage 4
│          搜索框 · 网格 · 侧边栏 · 预览       │
├─────────────────────────────────────────────┤
│           FindItCLI (验证层)                 │  ← Stage 0-3
│          子命令入口 · 结果格式化               │
├─────────────────────────────────────────────┤
│           FindItCore (核心库)                │
│                                             │
│   ┌────────────┐  ┌───────────────────┐    │
│   │SearchEngine │  │  PipelineManager  │    │
│   │ FTS5+向量   │  │  调度 STT/视觉管线 │    │
│   └──────┬─────┘  └─────────┬─────────┘    │
│          │                   │               │
│   ┌──────┴─────┐  ┌─────────┴──────────┐   │
│   │  Database   │  │  FFmpegBridge      │   │
│   │  GRDB/FTS5  │  │  STTProcessor      │   │
│   │  向量 BLOB  │  │  VisionAnalyzer    │   │
│   └────────────┘  └────────────────────┘   │
│                                             │
│   ┌────────────┐  ┌────────────────────┐   │
│   │VolumeManager│  │  Exporters         │   │
│   │ 卷监听/离线  │  │  EDL / FCPXML      │   │
│   └────────────┘  └────────────────────┘   │
├─────────────────────────────────────────────┤
│   SQLite 单文件 (.clip-index/index.sqlite)   │
└─────────────────────────────────────────────┘
```

## 源码目录结构

```
Sources/FindItCore/
├── Database/
│   ├── DatabaseManager.swift       # 连接管理 + WAL 模式
│   ├── Models.swift                # WatchedFolder, Video, Clip 数据模型
│   ├── Migrations.swift            # 版本化建表迁移
│   └── SearchEngine.swift          # FTS5 + 向量混合搜索
├── Pipeline/
│   ├── PipelineManager.swift       # 统一管线调度 + 状态机
│   ├── FFmpegBridge.swift          # FFmpeg 子进程调用封装
│   ├── STTProcessor.swift          # WhisperKit 封装
│   └── VisionAnalyzer.swift        # Gemini REST API 调用
├── Volume/
│   └── VolumeManager.swift         # DiskArbitration 卷监听
└── Export/
    ├── EDLExporter.swift           # CMX 3600 EDL 生成
    └── FCPXMLExporter.swift        # FCPXML 1.11 生成
```

## 模块职责

| 模块 | 职责 | 外部依赖 |
|------|------|---------|
| **Database** | 连接管理、建表迁移、CRUD、事务 | GRDB.swift |
| **SearchEngine** | FTS5 搜索、向量余弦相似度、融合排序 | Database |
| **FFmpegBridge** | 构建 FFmpeg/FFprobe 命令、解析输出、临时文件管理 | Foundation (Process) |
| **STTProcessor** | WhisperKit 初始化/转录、SRT 生成 | WhisperKit |
| **VisionAnalyzer** | Gemini API 调用、图片 Base64 编码、JSON 解析 | Foundation (URLSession) |
| **PipelineManager** | 管线调度、状态机管理、断点续传、并发控制 | 上述所有模块 |
| **VolumeManager** | DiskArbitration 监听、卷 UUID 匹配、离线/恢复 | DiskArbitration |
| **EDLExporter** | CMX 3600 EDL 格式文本生成 | Database |
| **FCPXMLExporter** | FCPXML 1.11 XML 生成 | Database |

## 数据流

```
视频文件
    │
    ├──→ FFmpegBridge: 提取音频 (16kHz WAV)
    │         │
    │         └──→ STTProcessor (WhisperKit)
    │                   │
    │                   └──→ 转录文本 + 时间戳 → SRT 文件
    │
    └──→ FFmpegBridge: 场景检测 + 关键帧抽取
              │
              └──→ VisionAnalyzer (Gemini Flash)
                        │
                        └──→ JSON 描述 (scene, subjects, actions...)
                                  │
                                  ▼
                           Database (SQLite)
                      ┌─────────────────────┐
                      │ clips 表 + FTS5 索引  │
                      │ + 向量 BLOB (BGE-M3)  │
                      └──────────┬──────────┘
                                 │
                           SearchEngine
                      (FTS5 关键词 + 向量语义)
                                 │
                                 ▼
                           搜索结果列表
```

## 数据库 Schema

详见产品说明书 v0.2 第四章。核心表：

- **watched_folders**: 监控文件夹，含卷 UUID、在线状态
- **videos**: 视频文件元数据，含索引状态机 (pending → completed)
- **clips**: 片段（搜索对象），含场景描述、标签、台词、向量
- **clips_fts**: FTS5 虚拟表，索引 tags + description + transcript
