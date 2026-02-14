# FindIt AI 视频剪辑流水线 — 调研与架构方案

> 2026-02-09 | 综合调研报告

## 目录

1. [愿景与场景](#1-愿景与场景)
2. [行业调研：关键项目速查](#2-行业调研关键项目速查)
3. [FindIt 现有能力盘点](#3-findit-现有能力盘点)
4. [架构设计：三层模型](#4-架构设计三层模型)
5. [Phase A — FindIt MCP Server](#5-phase-a--findit-mcp-server)
6. [Phase B — Timeline Export (FCPXML / OTIO)](#6-phase-b--timeline-export)
7. [Phase C — 自然语言剪辑流水线](#7-phase-c--自然语言剪辑流水线)
8. [Phase D — Remotion 集成（可选）](#8-phase-d--remotion-集成可选)
9. [技术决策与权衡](#9-技术决策与权衡)
10. [实施路线图](#10-实施路线图)
11. [参考项目一览](#11-参考项目一览)

---

## 1. 愿景与场景

### 核心场景

用户对 Claude Code 说：

> "用昨天的素材，按顺序讲述一段和男朋友逛街、吃饭、以及晚上一起去跑步的故事，剪辑成 Vlog。"

Claude Code 的执行流程：

```
1. 调用 FindIt MCP → search_clips("逛街 商场 购物") → 获取候选片段
2. 调用 FindIt MCP → search_clips("吃饭 餐厅 美食") → 获取候选片段
3. 调用 FindIt MCP → search_clips("跑步 夜跑 运动") → 获取候选片段
4. LLM 根据搜索结果生成 JSON 编辑计划（脚本 + 时间线）
5. 调用 FindIt MCP → render_timeline(plan) → FFmpeg 渲染或导出 FCPXML
6. 用户在 FCPX/Resolve 中精调 → 或直接获得初剪 MP4
```

### 目标用户

- 视频创作者（Vlogger、自媒体）
- 有大量素材库但缺少剪辑经验的用户
- 希望用自然语言快速出初剪再精调的专业编辑

---

## 2. 行业调研：关键项目速查

### 2.1 AI 视频搜索

| 项目 | 类型 | 特点 | 与 FindIt 对比 |
|------|------|------|---------------|
| **Twelve Labs** | 云 API | 多模态视频搜索，时间定位 | FindIt 本地化，隐私优先 |
| **Google Video Intelligence** | 云 API | 标签/镜头/OCR/人脸检测 | FindIt 同类功能（本地） |
| **iconik** | 云 DAM | AI 标签+搜索，存储网关模式 | 架构相似（元数据云端，媒体本地） |
| **Muse.ai** | 云平台 | 视频内搜索+播放 | FindIt 已有同级搜索能力 |

**关键发现**：没有开源项目能同时做到本地场景检测+转录+视觉分析+语义搜索。FindIt 在这个组合上是独一无二的。

### 2.2 程序化视频编辑

| 项目 | Stars | 语言 | 核心能力 | 适合 FindIt 的点 |
|------|-------|------|---------|-----------------|
| **editly** (mifi) | ~4.5K | JS | JSON → FFmpeg → 视频 | **IR 格式设计参考** |
| **Remotion** | ~21K | TS/React | React 组件即视频 | 可选渲染后端 |
| **MoviePy** | ~12K | Python | 剪辑 API 设计标杆 | 操作词汇表参考 |
| **auto-editor** | ~5.5K | Python | 静音检测+多格式导出 | 分析→决策→渲染 模式 |
| **ffmpeg-python** | ~9K+ | Python | FFmpeg filter graph builder | 滤镜图生成参考 |
| **LosslessCut** (mifi) | ~27K | TS | 无损快速切割 | concat demuxer 参考 |

### 2.3 时间线格式

| 格式 | 维护者 | 特点 | 推荐用途 |
|------|--------|------|---------|
| **OTIO** (OpenTimelineIO) | Pixar/ASWF | JSON、多轨、跨 NLE | 通用交换格式 |
| **FCPXML** | Apple | XML、FCP 原生 | macOS 优先导出 |
| **CMX 3600 EDL** | 行业标准 | 最古老但兼容最广 | 兜底格式 |
| **editly JSON** | mifi | 极简 JSON | LLM 生成友好 |
| **Shotstack JSON** | Shotstack | 类似 editly 但更完整 | API 场景参考 |

### 2.4 MCP 生态

| 项目 | Stars | 相关度 | 说明 |
|------|-------|--------|------|
| **Swift MCP SDK** | ~1.2K | **核心** | 官方 Swift SDK，v0.10.0+ |
| **video-editing-mcp** | ~245 | **高** | 视频搜索+编辑 MCP，最接近竞品 |
| **davinci-resolve-mcp** | ~516 | 中 | DaVinci Resolve 控制 |
| **mcp-media-processor** | ~25 | 中 | FFmpeg 媒体处理 |
| **dbhub** | ~2.1K | 设计参考 | 极简 2-tool 数据库网关 |
| **awesome-mcp-servers** | ~80K | 生态 | MCP 服务器目录 |

---

## 3. FindIt 现有能力盘点

FindIt 已经构建了完整的**视频理解层**，这是自然语言剪辑的最难部分：

### 数据层

| 能力 | 实现 | 数据 |
|------|------|------|
| 场景检测 | SceneDetector (FFmpeg) | SceneSegment: startTime, endTime |
| 语音转录 | STTProcessor (WhisperKit/SpeechAnalyzer) | 字级时间戳, SRT |
| 视觉分析 | VisionAnalyzer (Gemini/LocalVLM/Apple Vision) | 9 字段: scene, subjects, actions, objects, mood, shotType, lighting, colors, description |
| 标签合成 | AnalysisResult.composeTags() | 自动去重标签 |
| 向量嵌入 | GeminiEmbedding / NLEmbedding | 768/512 维向量 |
| 混合搜索 | SearchEngine.hybridSearch() | FTS5 + 向量融合 |

### 搜索 API

```swift
SearchEngine.hybridSearch(
    query: String,              // 自然语言查询
    queryEmbedding: [Float]?,   // 可选向量
    mode: .auto,                // fts/vector/hybrid/auto
    folderPaths: Set<String>?,  // 文件夹过滤
    limit: 50
) -> [SearchResult]             // clipId, filePath, startTime, endTime,
                                // scene, description, tags, transcript,
                                // thumbnailPath, score...
```

### FFmpeg 基础设施

```swift
FFmpegBridge.run(arguments:config:)  // 已封装子进程调用
AudioExtractor.extractAudio()         // 16kHz WAV
SceneDetector.detectScenes()          // 场景切点
KeyframeExtractor.extractKeyframes()  // 缩略图提取
```

### CLI 命令（现有外部 API 面）

`search`, `index`, `embed`, `detect-scenes`, `extract-keyframes`, `transcribe`, `analyze` 等 13 个子命令。

---

## 4. 架构设计：三层模型

```
┌──────────────────────────────────────────────────────────┐
│  Layer 1: 自然语言接口                                      │
│  ┌──────────┐  ┌──────────────┐  ┌────────────────┐      │
│  │Claude Code│  │Claude Desktop│  │ 其他 MCP 客户端 │      │
│  └─────┬────┘  └──────┬───────┘  └───────┬────────┘      │
│        └──────────────┼──────────────────┘                │
│                       │ MCP (stdio / HTTP)                │
├───────────────────────┼──────────────────────────────────┤
│  Layer 2: FindIt MCP Server                               │
│  ┌────────────────────┴────────────────────┐              │
│  │  Tools:                                  │              │
│  │  • search_clips    (搜索片段)            │              │
│  │  • get_clip_details (片段详情)           │              │
│  │  • list_folders     (文件夹列表)         │              │
│  │  • get_video_info   (视频信息)           │              │
│  │  • export_timeline  (导出时间线)         │              │
│  │  • render_assembly  (渲染拼接)           │              │
│  └────────────────────┬────────────────────┘              │
│                       │                                    │
├───────────────────────┼──────────────────────────────────┤
│  Layer 3: FindIt Core (已有)                               │
│  ┌────────────┬───────┴──────┬─────────────┐              │
│  │SearchEngine│ FFmpegBridge │PipelineManager│             │
│  │ VectorStore│ SceneDetector│ SyncEngine    │             │
│  │ FilterEngine│AudioExtract │ DatabaseMgr   │             │
│  └────────────┴──────────────┴──────────────┘              │
│                       │                                    │
│              ┌────────┴────────┐                           │
│              │  双层 SQLite    │                            │
│              │  文件夹库 + 全局库│                           │
│              └─────────────────┘                           │
└──────────────────────────────────────────────────────────┘
```

---

## 5. Phase A — FindIt MCP Server

**目标**：让 Claude Code 能搜索和浏览 FindIt 索引的视频库。

### 5.1 技术选型

| 方案 | 优点 | 缺点 | 推荐 |
|------|------|------|------|
| **Swift MCP Server** (官方 SDK) | 原生集成 FindItCore, GRDB 直连 | 需 swift-tools-version 6.0+ | **长期方案** |
| **Python FastMCP** | 快速原型，成熟 SDK | 需 SQLite 桥接，无法调 FindItCore | 原型验证 |
| **独立 CLI wrapper** | 零 SDK 依赖 | 需手写 JSON-RPC | 不推荐 |

**推荐**: Swift MCP Server 作为独立 Package（`FindItMCP`），依赖 `FindItCore`。

### 5.2 Package 结构

```
Sources/
  FindItCore/          # 现有核心库
  FindItCLI/           # 现有 CLI
  FindItApp/           # 现有 SwiftUI App
  FindItMCP/           # 新增: MCP Server
    main.swift         # Entry point
    MCPToolHandlers.swift
    ResultFormatter.swift
```

### 5.3 Tool 设计（6 个 Tools）

```swift
// Tool 1: search_clips (只读)
// 搜索视频片段
Input:  query: String, mode: "auto", limit: 20, folder: String?
Output: 格式化文本 (紧凑版: clipId, 视频名, 时间码, 分数, 标签, 描述摘要)

// Tool 2: get_clip_details (只读)
// 获取片段完整元数据
Input:  clipId: Int64
Output: 全部 9 个视觉字段 + 转录 + 标签 + 评分 + 文件路径

// Tool 3: list_folders (只读)
// 列出所有索引文件夹
Input:  无
Output: 文件夹路径, 视频数, 片段数, 索引状态

// Tool 4: get_video_info (只读)
// 获取视频级信息
Input:  videoPath: String 或 videoId: Int64
Output: 时长, 场景数, 索引状态, 文件大小

// Tool 5: export_timeline (只读)
// 从片段列表生成时间线文件
Input:  clips: [{clipId, inPoint?, outPoint?, speed?}],
        format: "fcpxml" | "otio" | "edl",
        transitions: "cut" | "crossfade"
Output: 文件路径

// Tool 6: render_assembly (副作用)
// 用 FFmpeg 渲染拼接视频
Input:  clips: [{clipId, inPoint?, outPoint?}],
        output: String (路径),
        transition: "cut" | "crossfade",
        transitionDuration: 0.5
Output: 输出文件路径 + 时长
```

### 5.4 MCP Resource (可选)

```
findit://folders          → 文件夹列表 JSON
findit://clip/{id}        → 片段元数据 JSON
findit://clip/{id}/thumb  → Base64 JPEG 缩略图
```

### 5.5 Claude Code 配置

```json
// .mcp.json (项目级) 或 ~/.claude.json (用户级)
{
  "mcpServers": {
    "findit": {
      "command": "/path/to/findit-mcp",
      "args": [],
      "env": {}
    }
  }
}
```

用户交互示例：

```
用户: 帮我找一些关于海边日落的镜头
Claude Code: [调用 findit.search_clips("海边 日落 金色时刻")]
→ 返回 5 个候选片段，附带时间码和描述

用户: 第 2 和第 4 个看起来不错，告诉我更多细节
Claude Code: [调用 findit.get_clip_details(clipId: 1234)]
→ 返回完整元数据
```

### 5.6 swift-tools-version 兼容方案

FindIt 主 Package 使用 5.9，而 Swift MCP SDK 需要 6.0+。两种方案：

**方案 A**: FindItMCP 作为独立 Package，通过 `FindItCore` library 依赖：
```swift
// Package.swift (FindItMCP 独立仓库或 workspace)
// swift-tools-version: 6.0
dependencies: [
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.0"),
    .package(path: "../Findit_app"),  // FindItCore
]
```

**方案 B**: 升级主 Package 的 swift-tools-version 到 6.0（如果 GRDB v6.29 兼容）。

**推荐 A**，风险更低。

---

## 6. Phase B — Timeline Export

**目标**：从搜索结果生成可导入 NLE 的时间线。

### 6.1 FCPXML 导出（macOS 优先）

FCPXML 是 Apple 的 XML 时间线格式，可直接导入 Final Cut Pro、DaVinci Resolve。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fcpxml>
<fcpxml version="1.11">
  <resources>
    <asset id="r1" src="file:///path/to/video1.mp4"
           start="0s" duration="120s" hasVideo="1" hasAudio="1"/>
  </resources>
  <library>
    <event name="FindIt Export">
      <project name="Vlog 初剪">
        <sequence format="r0" duration="30s">
          <spine>
            <asset-clip ref="r1" offset="0s"
                       start="15s" duration="10s" name="逛街片段"/>
            <asset-clip ref="r1" offset="10s"
                       start="45s" duration="8s" name="吃饭片段"/>
          </spine>
        </sequence>
      </project>
    </event>
  </library>
</fcpxml>
```

**实现方案**: Swift `XMLDocument` 或字符串模板生成。参考 `FCPXMLCodable` 开源库。

### 6.2 OTIO 导出（跨 NLE）

OpenTimelineIO 的 JSON 格式，可通过适配器导出到 Premiere、Resolve、Avid。

```json
{
  "OTIO_SCHEMA": "Timeline.1",
  "name": "FindIt Export",
  "tracks": {
    "OTIO_SCHEMA": "Stack.1",
    "children": [{
      "OTIO_SCHEMA": "Track.1",
      "kind": "Video",
      "children": [{
        "OTIO_SCHEMA": "Clip.1",
        "name": "逛街片段",
        "source_range": {
          "start_time": {"value": 450, "rate": 30},
          "duration": {"value": 300, "rate": 30}
        },
        "media_reference": {
          "OTIO_SCHEMA": "ExternalReference.1",
          "target_url": "file:///path/to/video1.mp4"
        }
      }]
    }]
  }
}
```

### 6.3 FFmpeg 快速渲染

无需 NLE，直接用 FFmpeg 渲染初剪：

```bash
# 无损拼接（同编码格式，最快）
ffmpeg -f concat -safe 0 -i concat_list.txt -c copy output.mp4

# concat_list.txt:
# file '/path/to/video1.mp4'
# inpoint 15.0
# outpoint 25.0
# file '/path/to/video2.mp4'
# inpoint 0
# outpoint 10.0
```

```bash
# 带转场（需重编码）
ffmpeg -i clip1.mp4 -i clip2.mp4 -filter_complex \
  "[0:v][1:v]xfade=transition=fade:duration=0.5:offset=9.5[v]; \
   [0:a][1:a]acrossfade=d=0.5[a]" \
  -map "[v]" -map "[a]" output.mp4
```

**FindIt 已有 FFmpegBridge**，可直接复用。

---

## 7. Phase C — 自然语言剪辑流水线

**目标**：用户用自然语言描述故事，AI 自动搜索匹配素材并组装时间线。

### 7.1 流水线架构

```
用户故事大纲（自然语言）
    │
    ▼
┌─────────────────────┐
│ Step 1: 故事解析      │  LLM (Gemini/Claude)
│ "逛街→吃饭→跑步"      │  → 结构化段落
│ → [{                 │     [{segment: "逛街",
│      searchQuery,    │       searchQuery: "商场 购物 逛街",
│      duration,       │       targetDuration: 8,
│      mood,           │       mood: "轻松愉快",
│      transition      │       transition: "crossfade"}]
│   }]                 │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│ Step 2: 素材检索      │  FindIt SearchEngine
│ 每段 → search_clips  │  → 候选片段列表
│ → 按相关性排序        │
│ → 选取 top-K         │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│ Step 3: 智能选片      │  LLM 评估 + 规则
│ • 视觉多样性          │  避免连续选同一视频
│ • 时间连贯性          │  优先时间顺序
│ • 节奏控制            │  短-长-短 节奏
│ • 去重               │  同一 clip 不重复
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│ Step 4: 时间线生成    │  JSON Edit Plan
│ [{                   │
│   source: "/path",   │
│   in: 15.0,          │
│   out: 23.0,         │
│   speed: 1.0,        │
│   transition: "fade" │
│ }]                   │
└─────────┬───────────┘
          │
          ├──→ FCPXML (导入 NLE 精调)
          ├──→ OTIO (跨平台导出)
          └──→ FFmpeg (直接渲染 MP4)
```

### 7.2 编辑操作词汇表

LLM 需要生成的操作集（约 10 个原语）：

| 操作 | 参数 | FFmpeg 映射 |
|------|------|------------|
| `trim` | source, in, out | `-ss -to` 或 `trim` filter |
| `concat` | clips[] | concat demuxer / filter |
| `crossfade` | duration | `xfade` + `acrossfade` |
| `speed` | factor | `setpts=PTS*factor` |
| `text_overlay` | text, position, duration | `drawtext` filter |
| `scale` | width, height | `scale` filter |
| `crop` | x, y, w, h | `crop` filter |
| `audio_mix` | sources[], volumes[] | `amix` filter |
| `fade_in/out` | duration | `fade` filter |
| `pip` | main, overlay, position, size | `overlay` filter |

### 7.3 FindIt JSON Edit Plan 格式

受 editly 和 Shotstack 启发设计的中间表示（IR）：

```json
{
  "version": "1.0",
  "output": {
    "width": 1920,
    "height": 1080,
    "fps": 30,
    "format": "mp4"
  },
  "segments": [
    {
      "name": "逛街",
      "clips": [
        {
          "clipId": 1234,
          "source": "/Volumes/SSD/footage/vlog_0208.mp4",
          "in": 15.0,
          "out": 23.0,
          "speed": 1.0
        }
      ],
      "transition": {
        "type": "crossfade",
        "duration": 0.5
      }
    },
    {
      "name": "吃饭",
      "clips": [
        {
          "clipId": 5678,
          "source": "/Volumes/SSD/footage/vlog_0208.mp4",
          "in": 120.0,
          "out": 135.0
        }
      ],
      "transition": {
        "type": "crossfade",
        "duration": 0.5
      }
    }
  ]
}
```

### 7.4 Gemini 结构化输出生成 Edit Plan

复用 FindIt 已有的 Gemini 结构化输出模式：

```swift
// response_mime_type: "application/json" + response_schema
// 输入: 用户故事大纲 + 搜索结果摘要
// 输出: 结构化 Edit Plan JSON
```

---

## 8. Phase D — Remotion 集成（可选）

### 为什么考虑 Remotion

- 用户可以在浏览器中**实时预览**时间线
- React 组件模型适合做**版本控制**（git diff 友好）
- 支持文字动画、字幕、Logo 叠加等**图形化元素**
- Lambda 渲染支持云端批量输出

### 集成方案

```
FindIt MCP Server
    │
    ▼ (生成 Edit Plan JSON)
    │
Remotion Project (TypeScript)
    │
    ├── src/Video.tsx          ← 读取 Edit Plan, 渲染视频
    ├── src/compositions.ts    ← 注册 Composition
    └── remotion.config.ts     ← 配置
```

```tsx
// 示例: 从 FindIt Edit Plan 渲染
const MyVideo: React.FC<{plan: EditPlan}> = ({plan}) => {
  let offset = 0;
  return (
    <>
      {plan.segments.map((seg, i) => {
        const clip = seg.clips[0];
        const duration = (clip.out - clip.in) * 30; // frames
        const el = (
          <Sequence key={i} from={offset} durationInFrames={duration}>
            <OffthreadVideo src={clip.source} startFrom={clip.in * 30} />
          </Sequence>
        );
        offset += duration;
        return el;
      })}
    </>
  );
};
```

### 何时需要 Remotion

- 需要复杂图形/字幕叠加时
- 需要跨平台 Web 预览时
- 需要版本化编辑（git + React）时

**大多数初剪场景 FFmpeg 足够**，Remotion 作为高级选项。

---

## 9. 技术决策与权衡

### 决策 1: MCP Server 语言

| | Swift (官方 SDK) | Python (FastMCP) |
|--|--|--|
| 集成度 | 直接调用 FindItCore | 需 SQLite 桥接 |
| 性能 | 原生二进制 | 解释器开销 |
| 开发速度 | 中等 | 快 |
| 依赖 | swift-tools-version 6.0 | Python 3.10+ |
| **推荐** | **Phase A 正式版** | 快速原型验证 |

### 决策 2: 时间线格式

| | FCPXML | OTIO | FFmpeg concat |
|--|--|--|--|
| NLE 支持 | FCP + Resolve | 全部 | 无 |
| 生成难度 | 中（XML 模板） | 低（JSON） | 低 |
| 精度 | 帧级 | 帧级 | 秒级 |
| 需要安装 | 无 | otio-python | 无 |
| **推荐** | macOS 主输出 | 跨平台补充 | 快速预览 |

### 决策 3: LLM 编辑计划生成

| | Gemini | Claude (via MCP sampling) |
|--|--|--|
| 结构化输出 | response_schema 强制 JSON | 需 prompt 引导 |
| 成本 | FindIt 已集成，免费额度 | MCP sampling 需客户端支持 |
| 延迟 | ~1-3s | ~2-5s |
| **推荐** | **Step 1 故事解析用 Gemini** | Claude Code 自身已经是 LLM |

**关键洞察**: 在 MCP 架构中，Claude Code 本身就是 LLM，可以直接做 Step 1（故事解析）和 Step 3（智能选片）。FindIt MCP Server 只需暴露搜索和渲染能力。

### 决策 4: Remotion vs FFmpeg

| | FFmpeg (直接渲染) | Remotion |
|--|--|--|
| 安装依赖 | 已有 (~/.local/bin/ffmpeg) | Node.js + npm |
| 图形能力 | drawtext + overlay | 完整 React UI |
| 预览 | 无（渲染后才能看） | 浏览器实时预览 |
| 版本控制 | JSON plan 可 diff | React 代码可 diff |
| **推荐** | Phase A-C 默认渲染 | Phase D 可选升级 |

---

## 10. 实施路线图

### Phase A: FindIt MCP Server（核心，2-3 周）

```
Week 1:
  ☐ 创建 FindItMCP 独立 Package (swift-tools-version 6.0)
  ☐ 实现 search_clips tool (接入 SearchEngine.hybridSearch)
  ☐ 实现 get_clip_details tool
  ☐ 实现 list_folders tool
  ☐ StdioTransport 启动 + Claude Code 配置测试

Week 2:
  ☐ 实现 get_video_info tool
  ☐ 结果格式化 (token-efficient 紧凑文本)
  ☐ 错误处理 + 超时保护
  ☐ 集成测试：Claude Code 端到端搜索素材
  ☐ README + 安装说明

Week 3 (buffer):
  ☐ Tool annotations (readOnlyHint)
  ☐ 缩略图 base64 返回 (可选)
  ☐ Skill 定义 (.claude/skills/video-search/SKILL.md)
```

### Phase B: Timeline Export（1-2 周）

```
Week 4:
  ☐ FCPXML 生成器 (TimelineExporter.swift in FindItCore)
  ☐ FFmpeg concat 渲染器 (AssemblyRenderer.swift in FindItCore)
  ☐ export_timeline MCP tool
  ☐ render_assembly MCP tool

Week 5:
  ☐ OTIO JSON 生成器 (可选)
  ☐ Claude Code 端到端: 搜索 → 选片 → 导出
  ☐ FCPXML 导入 FCP/Resolve 验证
```

### Phase C: 自然语言剪辑（1-2 周）

```
Week 6:
  ☐ Edit Plan JSON 格式定义
  ☐ Claude Code Skill: /edit-video
     (story outline → search → select → export)
  ☐ FFmpeg 渲染器支持 xfade 转场

Week 7:
  ☐ 端到端测试: 自然语言 → 初剪视频
  ☐ 多段故事拼接验证
  ☐ 文档更新
```

### Phase D: Remotion（可选，2+ 周）

```
Week 8+:
  ☐ Remotion 项目脚手架
  ☐ Edit Plan → React Composition 转换
  ☐ 浏览器预览集成
  ☐ Claude Code + Remotion 工作流
```

---

## 11. 参考项目一览

### 必读参考

| 项目 | URL | 参考价值 |
|------|-----|---------|
| **Swift MCP SDK** | https://github.com/modelcontextprotocol/swift-sdk | MCP Server Swift 实现基础 |
| **video-editing-mcp** | https://github.com/burningion/video-editing-mcp | 最接近竞品，`vj://` URI 设计 |
| **editly** | https://github.com/mifi/editly | JSON → FFmpeg 视频生成，IR 格式设计 |
| **OpenTimelineIO** | https://github.com/AcademySoftwareFoundation/OpenTimelineIO | 时间线交换标准 |
| **FCPXML Reference** | https://developer.apple.com/documentation/professional-video-applications/fcpxml-reference | Apple 时间线格式 |
| **dbhub** | https://github.com/nicholasgasior/dbhub | MCP 极简工具设计范例 |

### 深度参考

| 项目 | URL | 参考价值 |
|------|-----|---------|
| **Remotion** | https://remotion.dev | React 视频渲染框架 |
| **Shotstack API** | https://shotstack.io/docs/api | JSON 时间线 → 渲染 API 设计 |
| **ffmpeg-python** | https://github.com/kkroening/ffmpeg-python | 程序化 filter graph 构建 |
| **auto-editor** | https://github.com/WyattBlue/auto-editor | 分析→决策→渲染 管线模式 |
| **LosslessCut** | https://github.com/mifi/lossless-cut | 无损切割 UX 参考 |
| **MoviePy** | https://github.com/Zulko/moviepy | 视频编辑 API 设计标杆 |
| **Twelve Labs** | https://twelvelabs.io | 视频搜索 API 设计参考 |

### 竞争格局

| 能力 | FindIt | Twelve Labs | Descript | 开源方案 |
|------|--------|-------------|----------|---------|
| 场景检测 | 本地 (FFmpeg) | 云端 | 无 | PySceneDetect |
| 转录 | 本地 (WhisperKit) | 云端 | 云端 | Whisper |
| 视觉分析 | Gemini + 本地 | 云端 | 无 | 无成熟方案 |
| 语义搜索 | 混合 (FTS5+向量) | 云端 | 仅转录 | 无 |
| 文本剪辑 | 无 | 无 | **有** | 无 |
| 故事驱动拼接 | **规划中** | 无 | 无 | **无** |
| 本地运行 | **是** | 否 | 部分 | 各异 |
| NLE 导出 | **规划中** | 否 | 有 | editly (渲染) |

**FindIt 的独特定位**: 本地化、隐私优先、AI 视频搜索 + 故事驱动拼接。这个组合在开源和商业产品中都是空白。

---

## 附录 A: video-editing-mcp 详细分析

[video-editing-mcp](https://github.com/burningion/video-editing-mcp) 是目前最接近的参考实现：

- **技术栈**: Python + FastMCP
- **搜索**: 使用 embedding 向量 + 关键词混合搜索
- **编辑**: 生成 DaVinci Resolve 可导入的 OTIO 时间线
- **URI**: 自定义 `vj://` 协议引用视频资源
- **工具集**: search-videos, add-video, generate-edit-from-videos, edit-locally

与 FindIt 的差异：
1. 它依赖云服务（Video Jungle），FindIt 完全本地
2. 它没有场景级检测，FindIt 有完整的场景分析管线
3. 它的搜索粒度是视频级，FindIt 是片段（clip）级

## 附录 B: Swift MCP Server 最小示例

```swift
import MCP

@main
struct FindItMCPServer {
    static func main() async throws {
        let server = Server(
            name: "FindIt",
            version: "1.0.0",
            capabilities: .init(
                tools: .init(listChanged: false)
            )
        )

        // 注册工具列表
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [
                Tool(
                    name: "search_clips",
                    description: "Search video clips by natural language query",
                    inputSchema: .object([
                        "properties": .object([
                            "query": .string("Natural language search query"),
                            "limit": .string("Max results (default 20)")
                        ])
                    ])
                )
            ])
        }

        // 处理工具调用
        await server.withMethodHandler(CallTool.self) { params in
            switch params.name {
            case "search_clips":
                let query = params.arguments?["query"]?.stringValue ?? ""
                let results = try SearchEngine.search(
                    query: query, in: globalDB, limit: 20
                )
                return .init(
                    content: [.text(formatResults(results))],
                    isError: false
                )
            default:
                return .init(
                    content: [.text("Unknown tool")],
                    isError: true
                )
            }
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
    }
}
```
