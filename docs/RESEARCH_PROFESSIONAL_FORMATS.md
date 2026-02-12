# 专业电影机格式研究报告

> 调研日期: 2026-02
> 目的: 评估 FindIt 对四大电影机厂商专业格式的支持现状，指导 SDK 集成优先级

---

## 一、四大厂商格式支持总览

| 厂商 | 标准格式 (FFmpeg 支持) | 专有 RAW 格式 | RAW SDK | FindIt 现状 |
|------|----------------------|-------------|---------|------------|
| **Blackmagic** | ProRes, DNxHD/HR | **BRAW** (.braw) | 公开下载，免费 | braw-tool 已集成 ✓ |
| **RED** | ProRes (外录) | **R3D** (.r3d) | 公开下载，免费 | r3d-tool 已集成 ✓ |
| **ARRI** | **ProRes**, DNxHD (机内) | **ARRIRAW** (.ari/.mxf) | 需申请 Partner Program | ProRes/DNxHD 已支持 ✓ |
| **Sony** | **XAVC/XAVC S/XAVC HS** (机内) | **X-OCN** (.mxf) | 需 NDA + 商务关系 | XAVC 已支持 ✓ |

### 关键洞察

**ARRI 和 Sony 的标准格式输出已覆盖绝大多数后期素材**:
- ARRI 大量输出 ProRes (MOV/MXF)，FFmpeg 完全支持
- Sony 大量输出 XAVC (H.264/H.265 in MXF)，FFmpeg 完全支持
- 只有 RED 和 Blackmagic 主要输出专有 RAW，必须 SDK 才能处理

---

## 二、ARRI 格式详情

### 2.1 机型与录制格式

| 机型 | 传感器 | 色彩科学 | 主要录制格式 |
|------|--------|---------|------------|
| **ALEXA 35** (Base/Premium) | ALEV4, 17 档 | LogC4/AWG4 (REVEAL) | MXF/ARRIRAW, MXF/ProRes, MXF/ARRICORE* |
| **ALEXA 35 Xtreme** (2025.7) | ALEV4, 17 档 | LogC4/AWG4 | + ARRICORE, 最高 660fps |
| **ALEXA Mini LF** | ALEV3 大画幅 | LogC3/AWG3 | MXF/ARRIRAW, MXF/ProRes |
| **ALEXA 265** (2024.12) | ALEV3X Rev.B, 6.5K | LogC3/AWG3 | MXF/ARRIRAW |
| **ALEXA Mini** (经典) | ALEV3 S35 | LogC3/AWG3 | MXF/ARRIRAW, MOV/ProRes |
| **AMIRA** | ALEV3 S35 | LogC3/AWG3 | MOV/ProRes, MXF/DNxHD |

*ARRICORE 需 Xtreme 硬件或升级

### 2.2 编码格式详解

| 格式 | 类型 | 文件扩展名 | 压缩方式 | 说明 |
|------|------|----------|---------|------|
| **ARRIRAW** | RAW Bayer | .ari (帧序列) / .mxf | 无压缩 | 12-bit (ALEV3) / 13-bit (ALEV4) |
| **ARRIRAW HDE** | RAW Bayer | .arx / .mxf | 无损 (~60% 原大小) | Codex 技术，bit-exact 还原 |
| **ARRICORE** (2025 新) | 机内去拜耳 RGB | .mxf | 有损 (~50% of RAW) | 非 RAW，但保留曝光/白平衡调整 |
| **ProRes** | 标准编码 | .mov (旧) / .mxf (新) | 有损 | 4444XQ / 4444 / 422HQ / 422 / LT / Proxy |
| **DNxHD** | 标准编码 | .mxf | 有损 | 仅旧机型 (ALEXA/AMIRA) |

**趋势**: 从 ALEXA Mini LF (2019) 起，新机型统一使用 MXF 容器。

### 2.3 色彩科学

| 版本 | Log 曲线 | 色彩空间 | 适用机型 | 特点 |
|------|---------|---------|---------|------|
| **经典** | LogC3 (EI-dependent, 10-bit) | AWG3 | ALEV3 全系 | 中灰 39%，曲线随 EI 变化 |
| **REVEAL** | LogC4 (EI-independent, 12-bit) | AWG4 | ALEXA 35 系列 | 中灰 32%，17 档，单一曲线 |

### 2.4 FindIt 支持评估

**已支持 (通过 FFmpeg):**
- ProRes 全系列 (MOV + MXF) — 覆盖 90%+ ARRI 后期素材
- DNxHD (MXF) — Avid 工作流
- ProRes RAW — FFmpeg 8.0 (2025.8) 新增

**不支持:**
- ARRIRAW (.ari / MXF 封装) — FFmpeg 无去拜耳解码器
- ARRIRAW HDE (.arx) — 需 ARRI SDK 或 HDE Transcoder
- ARRICORE — 2025 全新编码，无开源支持

**实际影响: 低** — ARRIRAW 在后期流程中通常由 DIT 转码为 ProRes，很少以原始 RAW 进入剪辑师硬盘。

---

## 三、Sony 格式详情

### 3.1 标准格式 (XAVC 系列 — FFmpeg 已支持)

| 格式 | 编码 | 容器 | 适用机型 | FFmpeg 支持 |
|------|------|------|---------|------------|
| **XAVC** | H.264 Intra/Long GOP | MXF | FX9, FS7, F5, F55 | ✓ 完全支持 |
| **XAVC S** | H.264 Long GOP | MP4 | FX3, FX30, A7S III | ✓ 完全支持 |
| **XAVC HS** | H.265 (HEVC) | MP4 | FX3, FX30, A7S III | ✓ 完全支持 |
| **XAVC S-I** | H.264 All-Intra | MP4 | FX6, FX3 | ✓ 完全支持 |

### 3.2 专有 RAW 格式

| 格式 | 编码 | 容器 | 适用机型 | FFmpeg 支持 |
|------|------|------|---------|------------|
| **X-OCN** (ST/LT/XT) | 16-bit wavelet RAW | MXF | VENICE, VENICE 2, BURANO | ✗ 无支持 |
| **Sony RAW** (旧) | 线性 RAW | — | F65, F55 | ✗ 无支持 |

### 3.3 X-OCN SDK 获取

**Sony 是四大厂商中最封闭的**:
- 无公开 SDK 下载
- 需 NDA + 商务合作关系
- 可能途径:
  1. **Sony 官方**: pro.sony/contact-us (Professional Solutions)
  2. **nablet GmbH**: 第三方合作伙伴，为 Avid 等开发 Sony 插件
  3. **Sony Ci Media Cloud API**: 云端 X-OCN 转码 (非本地 SDK)

### 3.4 FindIt 支持评估

**已支持**: XAVC / XAVC S / XAVC HS / XAVC S-I — 覆盖 Sony 大部分民用和专业机型 (FX3, FX6, FX9, FS7 等)

**不支持**: X-OCN (VENICE/BURANO) — 仅影响高端电影制作

---

## 四、FindIt 格式支持矩阵

### 已支持 (无需额外 SDK)

| 格式 | 来源 | 解码方式 |
|------|------|---------|
| H.264 / H.265 | 所有消费/专业级机型 | FFmpeg |
| ProRes 全系列 (MOV/MXF) | ARRI, Apple, Blackmagic (外录) | FFmpeg |
| DNxHD/DNxHR (MXF) | ARRI, Avid 工作流 | FFmpeg |
| XAVC / XAVC S / XAVC HS | Sony 全系列 | FFmpeg |
| ProRes RAW | ARRI, Atomos 等 | FFmpeg 8.0+ |
| MXF 容器 (标准编码) | 多厂商 | FFmpeg |

### 已支持 (通过 SDK 工具)

| 格式 | 来源 | 解码方式 |
|------|------|---------|
| **BRAW** | Blackmagic 全系列 | braw-tool (BRAW SDK) ✓ |
| **R3D** | RED 全系列 | r3d-tool (R3D SDK) ✓ |

### 不支持

| 格式 | 来源 | SDK 获取难度 | 实际需求 |
|------|------|------------|---------|
| **ARRIRAW** (.ari/.mxf) | ARRI 高端机型 | 中 (Partner Program, 免费) | 低 (ProRes 已覆盖) |
| **ARRIRAW HDE** (.arx) | ARRI 高端机型 | 中 | 低 |
| **ARRICORE** | ARRI 35 Xtreme | 中 | 极低 (2025 新格式) |
| **X-OCN** | Sony VENICE/BURANO | 高 (NDA + 商务关系) | 低 |
| **Sony RAW** (旧) | Sony F65/F55 | 高 | 极低 (已淘汰) |

---

## 五、SDK 获取指南

### Blackmagic BRAW SDK ✓ (已集成)

- **下载**: https://www.blackmagicdesign.com/developer/products/braw/sdk-and-software
- **费用**: 免费
- **流程**: 注册 → 接受条款 → 下载

### RED R3D SDK ✓ (已集成)

- **下载**: https://www.red.com/download/r3d-sdk
- **费用**: 免费 (免版税)
- **流程**: 注册 → 接受 license → 下载
- **联系**: RED-r3dsdk@nikon.com

### ARRI Image SDK (未申请)

- **申请**: 邮件至 **digitalworkflow@arri.de**
- **门户**: https://www.arri.com/en/company/the-arri-philosophy/arri-partner-program
- **费用**: Partner Program 免费，部分功能可能收费
- **有效期**: 5 年，可续期
- **SDK 组件**:
  - ARRI Image SDK v9.0 — ARRIRAW 去拜耳 + 色彩处理
  - ARRI MXF Library v4.4.5 — MXF 读写 (提供源码)
  - ARRI Metadata Bridge — 元数据提取
- **替代工具** (无需 SDK):
  - ARRI Reference Tool (ART): https://www.arri.com/en/learn-help/learn-help-camera-system/tools/arri-reference-tool
  - HDE Transcoder: https://www.arri.com/en/learn-help/learn-help-camera-system/tools/arriraw-hde-transcoder

### Sony X-OCN SDK (最难获取)

- **无公开下载入口**
- 途径 1: 联系 Sony Professional — pro.sony/contact-us
- 途径 2: 联系 nablet GmbH — 第三方合作伙伴
- 途径 3: Sony Ci Media Cloud API — 云端转码 (非本地 SDK)
- **需要**: NDA + 商务合作关系

---

## 六、测试素材来源

| 厂商 | 来源 | 格式 | 大小 |
|------|------|------|------|
| **ARRI** | https://www.arri.com/en/learn-help/learn-help-camera-system/camera-sample-footage-reference-image | ARRIRAW, HDE, ProRes | HD 数百 MB, 4.6K RAW 数 GB |
| **ARRI** (FTP) | ftp2.arri.de (ALEXA/samplefootage) | 同上 | 同上 |
| **RED** | https://www.red.com/sample-r3d-files | R3D | 数百 MB ~ 数 GB |
| **Blackmagic** | BRAW SDK 内附 | BRAW | 数百 MB |
| **Sony** | 无官方公开样片 (X-OCN) | — | — |

---

## 七、优先级建议

### 当前已完成

1. ✅ **Blackmagic BRAW** — braw-tool 已集成
2. ✅ **RED R3D** — r3d-tool 已集成
3. ✅ **ARRI ProRes/DNxHD** — FFmpeg 原生支持
4. ✅ **Sony XAVC 系列** — FFmpeg 原生支持

### 暂不需要

5. ⏸ **ARRI ARRIRAW** — 需求低 (ProRes 已覆盖 90%+)，SDK 需申请但免费
6. ⏸ **Sony X-OCN** — 需求低，SDK 最难获取

### 如未来需要完整 RAW 支持

- **ARRI**: 申请 Partner Program (免费) → 集成 Image SDK → 支持 ARRIRAW + HDE + ARRICORE
- **Sony**: 需建立商务关系 → 签 NDA → 获取 X-OCN SDK
- **时间线**: 仅在有明确用户需求时才推进
