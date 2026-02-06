# 🎬 视频素材自然语言搜索 — 技术方案 v0.2

> 一款极简 macOS App，通过自然语言描述即可在海量视频文件中精准定位素材。

---

## 一、产品概述

### 1.1 核心价值

帮助视频制作者摆脱"靠记忆翻找"的低效工作方式：

- **语义搜索**：输入"夕阳下的海滩"即可定位对应片段
- **台词检索**：搜台词直接跳转时间码
- **NLE 衔接**：结果可导出为 FCPXML / EDL，或直接拖拽到时间线

### 1.2 目标用户

覆盖两类群体：

- **独立创作者 / UP 主**：成本敏感，素材量中等，在本地模式零成本即可用
- **专业剪辑师 / 制作公司**：对检索精度要求高，愿意为质量付费（云端 API 模式）

### 1.3 产品形态

- macOS 桌面 App（Swift / SwiftUI 原生）
- UI 风格对标 Downie、Permute — 极简、原生、高性能
- 运行后常驻后台，用户指定文件夹路径 → 自动递归扫描并解析
- 支持外接硬盘 / NAS 挂载卷，离线状态下索引数据仍可搜索

---

## 二、整体架构

```
┌─────────────────────────────────────────────┐
│             macOS App (Swift/SwiftUI)         │
├─────────────────────────────────────────────┤
│               统一管线调度层                    │
│                                               │
│   ┌────────────────┐       ┌────────────────┐│
│   │  STT 管线       │       │  视觉分析管线    ││
│   │  本地优先        │       │  可切换模式      ││
│   └───────┬────────┘       └────────┬───────┘│
│           │                        │          │
│   ┌───────┴────────┐    ┌─────────┴────────┐│
│   │ WhisperKit      │    │ 本地模型 | 云 API  ││
│   │ (Swift原生)      │    │ (免费)  |(自带Key) ││
│   └────────────────┘    └──────────────────┘│
│                                               │
├─────────────────────────────────────────────┤
│           SQLite 本地存储 + 混合搜索引擎        │
│         (FTS5 全文索引 + BGE-M3 向量搜索)      │
├─────────────────────────────────────────────┤
│    后台任务管理 · 卷状态监控 · 增量索引引擎      │
└─────────────────────────────────────────────┘
```

### 架构设计原则

| 原则 | 说明 |
|------|------|
| Swift 原生 | 所有核心组件优先选择 Swift 的原生方案，减少桥接开销 |
| 本地优先 | STT 全部本地，视觉分析提供免费本地模式 |
| 零运营成本 | 云端 API 由用户自带 Key，App 不承担计算费用 |
| 单文件存储 | 所有索引数据存储在 SQLite 文件中，便于备份/迁移 |
| 离线韧性 | 外接硬盘断开时索引数据保留，搜索可用，重新连接自动恢复 |

---

## 三、核心管线详细设计

### 3.1 管线 A：语音转文字（STT）

#### 选型决策

| 方案 | 结论 |
|------|------|
| MVP 首选 | **WhisperKit** — Swift 原生 SPM 包，CoreML + ANE 加速 |
| 后续加强 | SenseVoice（中文精度更高，待评估迁移方式） |

#### 选择 WhisperKit 的理由

- **Swift 原生**：通过 SPM 集成，两行代码初始化，无需桥接 Python / C++
- **Apple Silicon 深度优化**：CoreML + ANE 加速，比纯 CPU 快 2-3 倍
- **Word-level 时间戳**：原生支持，可直接转换为 SRT 格式
- **多模型可选**：tiny（~30MB）到 large-v3（~1.5GB），用户可按机器配置选择
- **large-v3 中文能力**：足够 MVP 验证，覆盖大部分中文识别场景

#### SRT 生成流程

```
视频文件
  │
FFmpeg 提取音轨 → 16kHz mono WAV
  │
WhisperKit 转录（word-level timestamps）
  │
时间码 + 文本 → 生成 SRT 字幕文件
  │
台词文本写入 SQLite clips.transcript 字段
```

#### 推荐模型配置

| 用户场景 | 推荐模型 | 体积 | 说明 |
|---------|---------|------|------|
| 快速预览 | small.en / small | ~460MB | 速度快，适合英文为主 |
| 通用场景 | base / small | ~142MB / ~460MB | 平衡速度与精度 |
| 高精度需求 | large-v3 | ~1.5GB | 中英文精度最高 |

---

### 3.2 管线 B：视觉分析

#### 3.2.1 抽帧策略

**方案：FFmpeg scene filter + 长镜头均分补帧**

选择 FFmpeg 而非 PySceneDetect 的理由：App 本身已依赖 FFmpeg（用于音频提取、抽帧），无需引入 Python 运行时，最终体积和整体复杂度更低。

##### 核心命令

```bash
# 场景检测 + 关键帧导出
ffmpeg -i input.mp4 \
  -vf "select='gt(scene,0.3)',showinfo" \
  -vsync vfn \
  frame_%04d.jpg

# 获取切换点时间码（不导出帧）
ffprobe -show_frames -of compact=p=0 \
  -f lavfi "movie=input.mp4,select=gt(scene\,0.3)"
```

##### 补偿策略

FFmpeg scene filter 只能检测硬切，对渐变转场和运动镜头有局限，通过以下机制补偿：

1. **双阈值动态扫描**：先用低阈值（0.15）获取候选切点，过滤间距 < 2s 的短脉冲（闪光/运动误报）
2. **长镜头均分**：场景 > 30s 无切点时，按 15s 间隔补充抽帧
3. **短镜头合并**：< 2s 的片段与相邻片段合并，避免碎片化

##### 每个片段的抽帧数量

```
帧数 = max(1, min(5, 场景时长 ÷ 5s))

示例：
- 3s 的镜头  → 1 帧
- 15s 的镜头 → 3 帧
- 45s 的镜头 → 5 帧（长镜头已被均分分割为 30s 以内）
```

#### 3.2.2 视觉模型

**双模式设计：**

| 模式 | 模型 | 成本 | 质量 | 适用场景 |
|------|------|------|------|---------|
| 精细模式（云端） | **Gemini Flash** | 用户自带 API Key | ⭐ 高 | 对精度要求高的专业用户 |
| 快速模式（本地） | 待定（MiniCPM-V / Moondream） | 免费 | 一般 | 预算敏感 / 离线场景 |

选择 Gemini Flash 作为云端首选的理由：性价比最高，视觉能力强，支持多图输入，批量帧描述天然适合多模态上下文窗口。

#### 3.2.3 帧输入方式

**批量帧描述**（每个片段的多帧组成一次请求）：

- 模型能理解片段级别的动作和故事，不只是静态画面描述
- 减少 API 调用次数，降低成本
- 每次请求对应一个时间段，搜索结果自然映射完整片段

#### 3.2.4 图片压缩

```bash
# 缩放到短边 512px，JPEG 质量 80
ffmpeg -i frame.jpg -vf "scale=512:-1" -q:v 5 frame_compressed.jpg
```

#### 3.2.5 Prompt 设计（MVP 版本）

```
你是一个视频素材分析助手。分析以下视频片段的关键帧（按时间顺序排列）：
返回 JSON 格式的描述：

{
  "scene": "场景描述（如：室内办公室、户外海滩）",
  "subjects": ["主体1", "主体2"],
  "actions": ["动作1", "动作2"],
  "objects": ["道具/物体1", "道具/物体2"],
  "mood": "整体氛围/情绪",
  "shot_type": "镜头类型（如：特写、中景、全景、航拍）",
  "lighting": "光线条件",
  "colors": "主要色调",
  "description": "用 1-2 句自然语言总结这个片段"
}
```

#### 3.2.6 API Key 管理

- 用户在 App 设置页面填入 API Key
- 支持 Gemini API Key（MVP 首选），预留 Claude / OpenAI 接口
- Key 存储在 macOS Keychain 中，安全可靠
- 零运营成本：App 不需要后端服务器

---

### 3.3 完整处理管线

```
用户指定文件夹
       │
  递归扫描视频文件（.mp4 .mov .mxf .avi ...）
       │
  ┌────┴─────┐
  │         │
管线A      管线B
(并行)     (并行)
  │         │
FFmpeg     FFmpeg scene filter
提取音轨    → 场景列表 + 关键帧
  │         │
WhisperKit  图片压缩
  │         │
SRT 字幕    批量送 Gemini Flash
+ 台词文本   │
  │        JSON 描述 + 标签
  │         │
  └────┬────┘
       │
  写入 SQLite
  (原数据 + FTS5 索引 + BGE-M3 向量嵌入)
       │
  生成 SRT 文件（保存到视频同目录）
```

---

## 四、索引与搜索方案

### 4.1 存储方案：SQLite 单文件

```
/素材文件夹/
├── 视频1.mp4
├── 视频1.srt          ← 生成的字幕文件
├── 视频2.mov
├── 视频2.srt
├── .clip-index/
    └── index.sqlite   ← 索引数据库（单文件）
```

### 4.2 数据库表结构

```sql
-- 监控文件夹表
CREATE TABLE watched_folders (
    folder_id       INTEGER PRIMARY KEY,
    folder_path     TEXT NOT NULL,
    volume_name     TEXT,                    -- 卷名（如 "素材盘A"）
    volume_uuid     TEXT,                    -- 卷 UUID（唯一标识，不随挂载点变化）
    is_available    INTEGER DEFAULT 1,       -- 当前是否可访问
    last_seen_at    TEXT,                    -- 上次可访问时间
    total_files     INTEGER DEFAULT 0,
    indexed_files   INTEGER DEFAULT 0
);

-- 视频文件表
CREATE TABLE videos (
    video_id        INTEGER PRIMARY KEY,
    folder_id       INTEGER REFERENCES watched_folders(folder_id),
    file_path       TEXT UNIQUE NOT NULL,
    file_name       TEXT NOT NULL,
    duration        REAL,                    -- 视频总时长（秒）
    file_size       INTEGER,                 -- 文件大小（字节）
    file_hash       TEXT,                    -- 快速哈希（头尾各 1MB SHA256）
    file_modified   TEXT,                    -- 文件修改时间
    created_at      TEXT,
    indexed_at      TEXT,
    index_status    TEXT DEFAULT 'pending',  -- pending / stt_running / stt_done
                                             -- / vision_running / completed
                                             -- / failed / orphaned
    index_error     TEXT,                    -- 失败原因
    orphaned_at     TEXT,                    -- 标记为 orphaned 的时间
    priority        INTEGER DEFAULT 0,       -- 用户可调优先级
    last_processed_clip INTEGER              -- 视觉分析断点（恢复用）
);

-- 片段表（核心）
CREATE TABLE clips (
    clip_id         INTEGER PRIMARY KEY,
    video_id        INTEGER REFERENCES videos(video_id),
    start_time      REAL NOT NULL,           -- 起始时间码（秒）
    end_time        REAL NOT NULL,           -- 结束时间码（秒）
    thumbnail_path  TEXT,                    -- 缩略图缓存路径
    scene           TEXT,                    -- 场景描述
    subjects        TEXT,                    -- 主体（JSON 数组）
    actions         TEXT,                    -- 动作（JSON 数组）
    objects         TEXT,                    -- 道具/物体（JSON 数组）
    mood            TEXT,                    -- 氛围/情绪
    shot_type       TEXT,                    -- 镜头类型
    lighting        TEXT,                    -- 光线
    colors          TEXT,                    -- 色调
    description     TEXT,                    -- 自然语言描述
    tags            TEXT,                    -- 所有标签（JSON 数组，供 FTS 搜索）
    transcript      TEXT,                    -- 该时间段内的台词
    embedding       BLOB                     -- BGE-M3 向量（1024维 float32）
);

-- FTS5 全文搜索虚拟表
CREATE VIRTUAL TABLE clips_fts USING fts5(
    tags,
    description,
    transcript,
    content='clips',
    content_rowid='clip_id'
);
```

### 4.3 搜索引擎：混合搜索

#### 分层搜索架构

```
用户输入："海边 夕阳 女生走路"
              │
    ┌─────────┴──────────┐
    │                   │
 关键词匹配层         语义搜索层
 (SQLite FTS5)      (BGE-M3 向量)
    │                   │
    └─────────┬──────────┘
              │
         融合排序 → 结果列表
```

#### 关键词匹配层（SQLite FTS5）

```sql
SELECT clip_id, rank FROM clips_fts
WHERE clips_fts MATCH '海边 OR 海滩 OR 沙滩'
ORDER BY rank LIMIT 50;
```

#### 语义搜索层（BGE-M3）

| 配置项 | 方案 |
|--------|------|
| 嵌入模型 | **BGE-M3**（ONNX 格式，~100MB） |
| 向量维度 | 1024 维 float32 |
| 存储方式 | SQLite BLOB 字段 |
| 检索方式 | 全量扫描余弦相似度 |
| 中英双语 | ⭐ BGE-M3 原生支持 |

性能估算：20,000 条记录全量扫描搜索 → 几毫秒（Apple Silicon）。

#### 融合排序

```
最终得分 = α × FTS5_score(归一化) + β × cosine_similarity

默认：α = 0.4, β = 0.6（语义优先）
带引号精确搜索：α = 0.9, β = 0.1（精确匹配优先）
长描述性语句（>10字）：α = 0.2, β = 0.8（语义主导）
```

---

## 五、产品交互设计

### 5.1 搜索栏

#### 快捷键体系

| 快捷键 | 功能 |
|--------|------|
| ⌘K 或 ⌘F | 聚焦搜索栏（App 内任何位置） |
| ⌘⇧F | 全局唤起（App 在后台时也能唤出，类似 Spotlight） |
| ESC | 清空搜索栏 / 收起 App（连按两次） |
| ↑ ↓ | 在结果间导航 |
| Space | Quick Look 预览选中项 |
| Enter | 在 Finder 中显示选中项 |

#### 实时搜索分层触发

```
每次按键（0ms 延迟）
  → FTS5 前缀匹配（< 5ms）→ 立刻展示关键词命中结果

停止输入 300ms 后
  → 触发 BGE-M3 embedding 计算（~50ms）
  → 执行向量搜索 → 补充语义匹配结果（淡入动画 或 插入）

停止输入 800ms 后
  → 台词同义词扩展搜索（"海边" → "海滩" "沙滩" "海岸"）
```

视觉上不需要 loading 状态 — FTS5 结果先即时反馈，向量搜索结果是"无感补充"。

#### 搜索空状态

```
┌─────────────────────────────────────────┐
│  🔍  搜索场景、动作、台词...        ⌘K  │
├─────────────────────────────────────────┤
│  最近搜索                    [清除全部]  │
│  🕐 海边 夕阳                           │
│  🕐 访谈 办公室                          │
│  🕐 "我想在这里多待一会儿"               │
│                                         │
│  热门标签（从素材库统计高频词）            │
│  📷 户外  📷 室内  📷 访谈  📷 航拍      │
│  📷 特写  📷 全景  📷 夜景  📷 人物      │
└─────────────────────────────────────────┘
```

- 最近 20 条搜索历史，点击直接执行
- 热门标签从当前素材库 tags 统计高频词（相当于"素材库概览"）

#### 搜索语法

```
普通搜索：海边 夕阳         → 搜画面描述和标签
台词搜索："具体台词内容"     → 精确匹配台词（引号触发）
排除词：  海边 -夜景         → 包含海边，排除夜景
```

### 5.2 搜索结果：缩略图网格

#### 卡片布局

```
┌──────────────────────┐
│                      │
│      缩略图区域       │  16:9 比例，圆角
│      (224×126px)     │
│                      │
│  🎬 ─────────── 0:35 │  左下：匹配类型 / 右下：片段时长
├──────────────────────┤
│  海滩日落·女生行走     │  描述摘要（单行截断）
│  项目A.mp4  03:20    │  文件名 + 起始时间码
└──────────────────────┘
```

#### 卡片元素规则

| 元素 | 规则 |
|------|------|
| 缩略图 | 取片段中间帧（`start_time + duration/2`），16:9 裁切，缓存 JPEG 长边 448px（Retina 2x） |
| 匹配类型角标 | 左下角半透明背景：🎬 画面匹配 / 🔊 台词匹配 / 🎬🔊 双重匹配 |
| 片段时长 | 右下角半透明黑底白字：< 60s 显示 `0:35`，≥ 60s 显示 `1:20` |
| 描述摘要 | description 前 10 字截断，台词匹配时显示台词片段并高亮关键词 |
| 文件名 | 截断到 12 字符 + `...` |
| 时间码 | 片段在源视频中的起始时间 |

#### 离线状态卡片

源文件所在卷不可用时：
- 缩略图加载半透明灰色蒙层 + ⛅️🔥 离线图标
- 搜索仍可命中（索引在本地 SQLite），但不可预览/导出
- 文件名行显示卷名：`素材盘A:项目A`

#### 网格响应式布局

```
窗口宽度       每行列数
< 600px        2 列
600-900px      3 列
900-1200px     4 列
> 1200px       5-6 列

卡片间距 12px，外边距 16px
SwiftUI: LazyVGrid + adaptive(minimum: 200)
```

#### 选中与多选

- 单击选中：蓝色 2px 描边
- ⌘ + 点击：多选（可批量导出）
- 选中后空格键触发 Quick Look

### 5.3 筛选与排序

#### Filter Bar（搜索栏下方固定）

```
[全部 ←] [🎬 画面] [🔊 台词]  →  来源：[所有文件夹 ▼]  →  排序：[相关度 ▼]
                                                         找到 47 个片段
```

#### 匹配类型筛选（三选 tab）

| 选项 | 逻辑 |
|------|------|
| 全部 | FTS5 + 向量搜索所有结果 |
| 🎬 画面 | 只看 tags + description 的命中 |
| 🔊 台词 | 只看 transcript 的命中 |

#### 来源筛选

下拉菜单按 watched_folders 文件夹结构展示，可限定搜索范围。

#### 排序方式

| 排序选项 | 逻辑 |
|---------|------|
| 相关度（默认） | 混合搜索融合得分 |
| 时间码 | 按源视频 start_time 正序 |
| 文件名 | 按文件名字母序，同文件内按时间码 |
| 文件修改时间 | 最近修改的视频优先 |
| 片段时长 | 最长/最短优先（可切换正/倒序） |

### 5.4 片段预览

**方案：macOS 原生 Quick Look（`QLPreviewPanel`）**

- 选中卡片 + 空格键触发，与 Finder 操作一致
- 零开发成本：原生支持视频播放、进度拖拽、全屏
- 预览打开时按 ↑↓ 切换到上/下一个结果

> 📌 **后续迭代项**：Quick Look 预览增加 "自动定位到片段起始时间码"功能，可通过自定义 QLPreviewPanel 插件或自建轻量播放器实现

#### 右键菜单

| 菜单项 | 功能 | 快捷键 |
|--------|------|--------|
| 📋 复制时间码 | `00:03:20` 复制到剪贴板 | ⌘C |
| 📂 在 Finder 中显示 | 打开源文件所在文件夹并选中 | ⌘⇧R |
| ⬇️ 导出片段 | FFmpeg 按时间码裁切为独立文件 | ⌘E |
| 🏷 查看详细标签 | 展示完整描述、标签、台词 | ⌥↩ |

### 5.5 侧边栏：素材库管理

```
── 素材库 ─────────────────────────┐
│                                │
│  🟢 本机 ~/Movies/项目A        │  在线
│     50 个视频 · 628 个片段      │
│                                │
│  🟢 素材盘A /项目B              │  在线（外接）
│     23 个视频 · 312 个片段      │
│                                │
│  🔴 NAS_Media /归档素材         │  离线
│     105 个视频 · 1,420 个片段   │
│     上次在线：2 天前             │
│                                │
│  [+ 添加文件夹]                 │
└────────────────────────────────┘
```

🟢 / 🔴 一目了然。离线文件夹的索引数据仍可搜索，只是不能预览和导出。

---

## 六、NLE 集成

### 6.1 MVP 支持的三种集成方式

| 方式 | 说明 | 导出粒度 |
|------|------|---------|
| **拖拽文件到 NLE** | SwiftUI `.onDrag` + `NSItemProvider` | 整个源文件 |
| **EDL 导出**（CMX 3600） | 纯文本，所有 NLE 通用 | 单个/批量片段 |
| **FCPXML 导出** | FCP 原生格式，片段已按时间范围裁好 | 单个/批量片段 |

### 6.2 EDL 导出格式

```
TITLE: 搜索结果 - 海边夕阳
FCM: NON-DROP FRAME

001  项目A    V     C        01:00:03:20 01:00:03:45 01:00:00:00 01:00:00:25
002  素材B    V     C        01:00:15:42 01:00:16:10 01:00:00:25 01:00:00:53
```

每行一个剪辑点：源文件 reel name、入点、出点、在时间线上的位置。兼容 DaVinci Resolve、Final Cut Pro、Premiere、Avid。

### 6.3 FCPXML 导出格式

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fcpxml>
<fcpxml version="1.11">
  <resources>
    <asset id="r1" src="file:///素材/项目A.mp4"
           start="0s" duration="1800s" hasVideo="1" hasAudio="1">
      <media-rep kind="original-media" src="file:///素材/项目A.mp4"/>
    </asset>
  </resources>
  <library>
    <event name="搜索结果 - 海边夕阳">
      <project name="搜索导出">
        <sequence>
          <spine>
            <asset-clip ref="r1" offset="0s"
                        start="200s" duration="25s"
                        name="海滩日落·女生行走"/>
          </spine>
        </sequence>
      </project>
    </event>
  </library>
</fcpxml>
```

FCP 导入后片段直接出现在事件浏览器，已按时间范围裁好，携带名称和数据。

### 6.4 导出交互

- **单个片段**：右键菜单 → 导出为 EDL / FCPXML
- **批量导出**：⌘ 多选片段 → 工具栏导出按钮 → 选择格式 → 保存
- **拖拽**：从卡片直接拖出文件到 NLE 窗口

### 6.5 后续迭代

> 📌 DaVinci Resolve 元数据写入（XMP / sidecar），让 DaVinci 媒体池可直接按标签筛选

---

## 七、后台任务管理

### 7.1 任务状态机

每个视频文件的索引任务独立管理：

```
pending → stt_running → stt_done → vision_running → completed
   │                                                    │
   ├─────────── failed ←────────（任何环节出错）───────────┘
                   │
              (用户重试)
```

**关键设计**：STT 和视觉分析是两个独立子状态。STT 完成后即使视觉分析失败，STT 结果不丢，重试时只需跑视觉部分。

### 7.2 进度展示

```
┌─────────────────────────────────────────────────┐
│  素材索引                                  ⏸ ✕  │
├─────────────────────────────────────────────────┤
│  整体进度：12 / 50 个文件                         │
│  [████████████░░░░░░░░░░░░░░] 24%               │
│  预计剩余：约 2 小时 40 分                         │
│                                                  │
│  ── 当前处理 ────────────────────────────         │
│  🎬 A_访谈_02.mp4                                │
│     🎤 语音转录中... 68%                          │
│     🖼 视觉分析等待中                              │
│                                                  │
│  ── 已完成 ────────────────────── 12 个文件         │
│  ✅ A_访谈_01.mp4     32 个片段  46 条台词         │
│  ✅ C_产品特写.mp4     8 个片段   0 条台词          │
│                                                  │
│  ── 排队中 ────────────────────── 38 个文件         │
│  ⏳ DJI_005.mov                                  │
│  ⏳ DJI_006.mov                                  │
└─────────────────────────────────────────────────┘
```

预计剩余时间基于已完成文件的平均处理速度动态计算。

### 7.3 控制能力（MVP）

| 功能 | 实现方式 |
|------|---------|
| **暂停/恢复** | 暂停 = 不再开始新子任务，当前任务跑完再停。恢复时根据 `index_status` 从断点继续 |
| **取消** | 停止所有任务，保留已完成数据 |
| **失败重试** | 一键重试所有 `status = failed` 的文件 |
| **优先级调整** | 拖拽文件到队列顶部优先处理，写入 `videos.priority` 字段 |

#### 暂停粒度

| 正在运行的任务 | 暂停行为 |
|---------------|---------|
| WhisperKit 处理中 | 让当前文件跑完，不开始下一个 |
| Gemini API 调用中 | 让当前片段请求完成，记录 `last_processed_clip`，恢复时续传 |
| FFmpeg 场景检测/抽帧 | 等待完成（通常几秒到几十秒） |

核心原则：**"不再开始新的子任务"而非强制中断当前任务**。

#### 恢复逻辑

```swift
func resumeIndexing() {
    let pendingVideos = db.query("""
        SELECT * FROM videos
        WHERE index_status NOT IN ('completed', 'orphaned')
        AND folder_id IN (SELECT folder_id FROM watched_folders WHERE is_available = 1)
        ORDER BY priority DESC, rowid ASC
    """)
    for video in pendingVideos {
        switch video.index_status {
        case "pending":      startFullPipeline(video)
        case "stt_done":     startVisionPipeline(video)
        case "vision_running": resumeVisionPipeline(video, from: video.lastProcessedClip)
        case "failed":       continue  // 等用户手动重试
        }
    }
}
```

### 7.4 资源管理

| 策略 | 实现 |
|------|------|
| CPU 优先级 | QoS `.utility` 级别，系统自动降优先级 |
| 并发控制 | 同时处理 1-2 个文件，STT + 视觉分析管线可并行 |
| 内存控制 | 处理完一个文件立即释放帧缓存 |
| 磁盘空间 | 临时文件（抽帧图片）处理完即删，只保留 SQLite 索引 |
| 温度监控 | `ProcessInfo.thermalState` 过热时自动降速/暂停 |

### 7.5 系统通知

通过 `UNUserNotificationCenter` 推送 macOS 通知：

- 索引完成：`已索引 50 个视频，628 个片段`
- 索引失败：`3 个文件索引失败 → API 限流，请稍后重试`
- 硬盘恢复：`"素材盘A" 已重新连接，3 个文件将继续索引`

---

## 八、外接硬盘与卷管理

### 8.1 设计原则

视频制作者的素材通常在外接 SSD、移动硬盘、NAS 等可移除设备上。核心原则：**索引数据永远保留在本地，卷离线时搜索仍可用**。

### 8.2 卷标识

不仅存储路径，同时存储卷的 UUID — macOS 给每个卷分配的唯一标识，不随挂载点变化：

```swift
let values = try URL(fileURLWithPath: "/Volumes/素材盘A")
    .resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey])
let uuid = values.volumeUUIDString   // 唯一不变
let name = values.volumeName          // "素材盘A"
```

### 8.3 三种状态处理

| 状态 | 处理 |
|------|------|
| **硬盘在，正常** | `is_available = 1`，全功能可用 |
| **索引过程中被拔出** | 捕获 I/O 错误 → 暂停该文件夹任务 → `is_available = 0` → 保留已完成数据 → 通知用户 |
| **索引完成后被拔出** | 搜索仍可用 → 卡片显示离线蒙层 → 预览/导出提示不可用 → 重新接入自动恢复 |

#### 卷重新接入时

- 通过 UUID 匹配（即使挂载点变了也能识别）
- 自动更新 `folder_path`（如果挂载点变化）
- 恢复 `is_available = 1`
- 未完成的索引任务自动继续
- 通知用户

### 8.4 卷监听

通过 `DiskArbitration` 框架实时监听卷挂载/卸载事件：

```swift
import DiskArbitration

let session = DASessionCreate(kCFAllocatorDefault)!

DARegisterDiskDisappearedCallback(session, nil, queue) { disk in
    // 卷卸载 → 检查是否为监控文件夹所在卷 → is_available = 0
}

DARegisterDiskAppearedCallback(session, nil, queue) { disk in
    // 新卷挂载 → UUID 匹配已知文件夹 → 恢复 is_available = 1 → 更新路径
}
```

---

## 九、增量索引

### 9.1 触发时机

- App 启动时自动扫描所有 `is_available = 1` 的 watched_folders
- 用户手动点击刷新
- 外接硬盘重新连接时

> 📌 **后续迭代项**：FSEvents 实时文件监听

### 9.2 变更检测逻辑

| 变化类型 | 检测方式 | 处理 |
|---------|---------|------|
| 新增文件 | 磁盘有、数据库无 | 加入队列，`status = pending` |
| 文件修改 | 路径相同，`file_modified` 时间戳变化 | 删旧索引，重新 pending |
| 文件删除 | 数据库有、磁盘无 | soft delete → `status = orphaned`（30 天后清理） |
| 文件移动/重命名 | 新文件 `quick_hash` 匹配某个 orphaned 记录 | 更新路径，不重新索引 |

### 9.3 文件快速哈希

取头尾各 1MB 计算 SHA256，避免全文件 hash 的性能开销：

```swift
func quickFileHash(url: URL) -> String {
    let handle = try FileHandle(forReadingFrom: url)
    let head = handle.readData(ofLength: 1_048_576)         // 前 1MB
    handle.seekToEndOfFile()
    let tailOffset = max(0, handle.offsetInFile - 1_048_576)
    handle.seek(toFileOffset: tailOffset)
    let tail = handle.readData(ofLength: 1_048_576)          // 后 1MB
    return SHA256(head + tail)
}
```

### 9.4 Orphaned 文件策略

```sql
-- 文件消失时 soft delete
UPDATE videos SET index_status = 'orphaned', orphaned_at = datetime('now')
WHERE file_path = ?;

-- 30 天后清理（可在 App 设置中调整）
DELETE FROM videos WHERE index_status = 'orphaned'
AND orphaned_at < datetime('now', '-30 days');

-- 文件重新出现时恢复（通过 hash 匹配）
UPDATE videos SET index_status = 'completed', orphaned_at = NULL,
    file_path = ?   -- 更新为新路径
WHERE file_hash = ? AND index_status = 'orphaned';
```

---

## 十、技术栈总览

| 组件 | 技术选型 | 说明 |
|------|---------|------|
| 语言 & 框架 | Swift / SwiftUI | macOS 原生 |
| STT 模型 | WhisperKit (SPM) | CoreML + ANE 加速 |
| 视觉分析（云端） | Gemini Flash API | 用户自带 Key，性价比最高 |
| 视觉分析（本地） | 待定 | MiniCPM-V / Moondream 候选 |
| 视频处理 | FFmpeg | 音频提取 + 场景检测 + 抽帧 + 片段导出 |
| 全文搜索 | SQLite FTS5 | 系统自带，零依赖 |
| 向量嵌入 | BGE-M3 (ONNX) | 中英双语，~100MB |
| 向量检索 | SQLite BLOB + 暴力搜索 | 数据量 < 10 万条，无需向量数据库 |
| 存储 | SQLite | 单文件，跟随素材文件夹 |
| Key 存储 | macOS Keychain | 安全存储 API Key |
| 片段预览 | QLPreviewPanel | macOS 原生 Quick Look |
| 卷监听 | DiskArbitration | 外接硬盘挂载/卸载事件 |
| 系统通知 | UNUserNotificationCenter | 索引完成/失败/硬盘恢复通知 |
| NLE 导出 | 自建 | EDL (CMX 3600) + FCPXML |

---

## 十一、MVP 范围界定

### ✅ MVP 包含

- 指定文件夹 → 自动扫描视频文件
- 外接硬盘支持（卷 UUID 识别 + 离线状态 + 自动恢复）
- FFmpeg 场景检测 + 抽帧（含长镜头均分 + 短镜头合并）
- WhisperKit 语音转文字 → SRT 生成
- Gemini Flash 视觉分析（云端精细模式，用户自带 Key）
- SQLite FTS5 关键词搜索 + BGE-M3 向量语义搜索 + 混合排序
- 实时搜索（FTS5 即时 + 向量 300ms debounce）
- 搜索历史 + 热门标签
- 搜索语法（引号精确匹配、排除词）
- 缩略图网格结果展示（匹配类型角标、离线状态）
- 筛选（匹配类型 + 来源文件夹）与排序（相关度/时间码/文件名等）
- macOS 原生 Quick Look 预览（空格键触发）
- 右键菜单（复制时间码、Finder 中显示、导出片段、查看标签）
- NLE 集成（拖拽 + EDL 导出 + FCPXML 导出，单个/批量）
- 后台任务管理（进度展示、暂停/恢复/取消、失败重试、优先级调整）
- 增量索引（启动扫描 + 手动刷新 + 硬盘重连触发）
- 侧边栏素材库管理（文件夹状态一览）
- ⌘⇧F 全局唤起搜索

### ⏳ 后续迭代

- 本地视觉模型（快速模式）
- SenseVoice 中文加强
- Quick Look 自动定位到片段起始时间码
- Hover scrub（悬浮拖擦预览）
- DaVinci Resolve 元数据写入（XMP / sidecar）
- FSEvents 实时文件夹监听
- 多 API 提供商切换（Claude / OpenAI）
- 同义词自动扩展搜索

---

## 十二、参考项目

| 项目 | 地址 | 参考价值 |
|------|------|---------|
| EditMind | https://github.com/IliasHad/edit-mind | 整体思路参考 |
| Video Analysis | https://github.com/Ga0512/video-analysis | 视觉分析流程 |
| AI Video Analyzer | https://github.com/arashsajjadi/ai-powered-video-analyzer | 待调研 |
| WhisperKit | https://github.com/argmaxinc/WhisperKit | STT 集成 |
| PySceneDetect | https://github.com/Breakthrough/PySceneDetect | 场景检测算法参考 |
| mac-whisper-speedtest | https://github.com/anvanvan/mac-whisper-speedtest | Apple Silicon STT benchmark |

---

*文档版本：v0.2 | 更新时间：2025-02-06 | 状态：全栈架构设计完成，可进入开发阶段*
