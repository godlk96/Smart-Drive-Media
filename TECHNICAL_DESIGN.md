# 技术设计文档 (TDD) - 智驾影音 (Smart Drive Video)

| 字段 | 值 |
| --- | --- |
| **技术负责人** | @TechLead |
| **产品经理** | @ProductManager |
| **团队成员** | Frontend Dev, Mobile Dev |
| **关联文档** | [PRD (文档.md)](./文档.md), [UI/UX (DESIGN.md)](./DESIGN.md) |
| **状态** | 草稿 (Draft) |
| **创建日期** | 2026-03-06 |

---

## 1. 背景 (Context)

“智驾影音”是一款专为鸿蒙智行车主设计的视频剪辑工具，旨在解决车机行车记录仪视频碎片化、多视角难以同步预览及隐私泄露等痛点。目前，用户需要手动处理大量 1 分钟/段的视频文件，效率极低。本项目将通过自动化整理、多轨同步剪辑和隐私保护功能，提供一站式的移动端解决方案。

---

## 2. 问题定义与动机 (Problem Statement & Motivation)

### 我们解决的问题
1.  **碎片化文件管理难**：单次行程产生数百个视频文件，用户无法快速定位。
2.  **多视角预览缺失**：手机端缺乏同步播放 6 个视角的工具。
3.  **隐私泄露风险**：原视频包含敏感信息（车速、VIN 码），直接分享存在风险。

### 为什么现在做？
随着鸿蒙智行车型销量爆发，车主对视频分享的需求日益增长。HarmonyOS NEXT 的发布提供了原生开发的契机。

---

## 3. 范围 (Scope)

### ✅ 包含 (In Scope - MVP)
*   **被动式导入**：App 启动时自动扫描本地相册及 Huawei Share 目录。
*   **智能行程聚合**：基于文件名正则 (`DVR_LoopRecording_...`) 自动聚合行程。
*   **多轨同步预览**：支持 6 轨视频同步播放、拖拽进度。
*   **隐私打码**：一键遮挡车速、VIN 码、GPS。
*   **视频导出**：支持极速无损拼接（Stream Copy）和转码导出。

### ❌ 不包含 (Out of Scope)
*   云端存储与同步。
*   社交社区功能。
*   车机硬件控制。

---

## 4. 技术方案 (Technical Solution)

### 4.1 技术选型 (Technical Stack Selection)

*   **开发环境**: DevEco Studio 4.1+
*   **编程语言**: ArkTS (TypeScript 扩展) - 鸿蒙原生首选，类型安全。
*   **UI 框架**: ArkUI (Stage Model) - 声明式 UI，高性能渲染。
*   **状态管理**: AppStorage / LocalStorage (原生) - 简单场景足够，避免引入重型库。
*   **多媒体核心**:
    *   **播放器**: AVPlayer (System Native) - 硬件解码，低功耗。
    *   **视频处理**: FFmpeg 6.0 (C++ NAPI Port) - 强大的流处理能力，需交叉编译。
        *   **硬件加速**: 需在 C++ 层对接鸿蒙原生 AVCodec 框架 (及 iOS VideoToolbox, Android MediaCodec)，确保在多视角拼接与打码重编码时，调用底层 GPU/NPU 进行硬件加速，大幅降低功耗。
        *   **合规性说明**: 编译时需配置 `--disable-gpl` 及相关非自由库，严格遵循 LGPL 协议动态链接，以符合各大应用商店的上架合规要求。
*   **本地存储**: RelationalStore (SQLite) - 存储行程元数据 (`Trip` table)。
*   **异步处理**: TaskPool / Worker - 将文件扫描和视频转码放入后台线程，避免阻塞 UI 主线程。
*   **图片加载**: Image (System Native) - 支持 PixelMap 高效加载缩略图。

### 4.2 跨平台演进策略 (Cross-Platform Evolution Strategy)

当前的 **ArkTS + ArkUI** 选型是针对 **HarmonyOS NEXT** 的深度优化方案，**UI 层**并不直接兼容 Android/iOS。为支持后期跨平台，我们将采用 **"Core Logic Shared, UI Native" (核心逻辑共享，UI 原生)** 的架构策略：

1.  **Core Layer (C++ / Rust)**:
    *   **复用度**: 100%
    *   **内容**: FFmpeg 视频处理引擎、时间轴对齐算法、文件扫描正则解析。
    *   **实现**: 通过 NAPI (HarmonyOS), JNI (Android), FFI (iOS) 暴露统一接口。

2.  **Business Logic Layer (Logic Shared via C++)**:
    *   **复用度**: > 90%
    *   **内容**: 数据模型与调度层下沉。将行程模型 (Trip)、时间轴计算规则、正则匹配等强逻辑放入 C++/Rust 层。
    *   **实现**: 鸿蒙端通过 NAPI 调用，Android/iOS 端通过 JNI/FFI 调用，实现真正意义上的 100% 逻辑复用，各端仅保留极其轻薄的 ViewModel 负责 UI 状态映射。

3.  **UI Layer (Native)**:
    *   **复用度**: 0% (需针对各平台重写)
    *   **内容**: 播放器视图、时间轴交互、动画效果。
    *   **选型**:
        *   **HarmonyOS**: ArkUI (最佳性能，利用系统级动效)。
        *   **Android**: Jetpack Compose (声明式 UI，与 ArkUI 理念一致)。
        *   **iOS**: SwiftUI (声明式 UI，易于从 ArkUI 迁移概念)。

**决策理由**: 视频编辑属于**重计算、重渲染**场景。相比 Flutter/React Native 等跨平台框架，原生 UI (ArkUI/Compose/SwiftUI) 能提供更流畅的 4K 多路预览性能和更低的功耗，且能第一时间接入各平台的最新系统特性（如鸿蒙的实况窗、iOS 的灵动岛）。

### 4.3 架构概览 (Architecture Overview)

采用 **MVVM (Model-View-ViewModel)** 架构，确保 UI 与业务逻辑分离。

*   **View (UI Layer)**: 基于 HarmonyOS ArkUI (或 Flutter/React Native) 构建，遵循 `DESIGN.md` 规范。
*   **ViewModel (Logic Layer)**: 处理状态管理、行程聚合逻辑、视频播放控制。
*   **Model (Data Layer)**: 本地文件系统访问、FFmpeg 封装、配置存储。

```mermaid
graph TD
    UI[UI Layer (ArkUI/Flutter)] -->|Bind| VM[ViewModel]
    VM -->|Scan/Read| FS[File System Repository]
    VM -->|Process| FF[FFmpeg Engine]
    FS -->|Regex| Parser[Regex Parser]
    FF -->|Export| Output[Video File]
```

### 4.4 核心模块设计

#### 4.4.1 数据模型 (Data Models)

**Trip (行程)**
*   **Definition**: 一次连续的驾驶行为聚合。
*   **Fields**:
    *   `id`: UUID, 唯一标识。
    *   `startTime`: Timestamp, 行程开始时间。
    *   `endTime`: Timestamp, 行程结束时间。
    *   `duration`: Number, 时长(秒)。
    *   `videoTracks`: List<VideoTrack>, 包含的视频轨道。
    *   `thumbnailUrl`: String, 封面图路径。

**VideoTrack (视频轨道)**
*   **Definition**: 单个摄像头的连续视频流。
*   **Fields**:
    *   `cameraPosition`: Enum (Front, Back, Left, Right, LeftFront, RightFront).
    *   `segments`: List<VideoSegment>, 物理文件切片列表。
    *   `syncOffset`: Number, 相对主时钟的同步偏移量(ms)。

**VideoSegment (视频切片)**
*   **Definition**: 物理文件实体（1分钟一段）。
*   **Fields**:
    *   `filePath`: String, 本地绝对路径。
    *   `fileName`: String, 原始文件名。
    *   `startTime`: Timestamp, 文件开始时间。
    *   `duration`: Number, 文件时长。

#### 4.4.2 文件扫描与解析 (File Scanner & Parser)
*   **输入**：系统相册 URI / 本地目录路径。
*   **逻辑**：
    1.  遍历目标目录。
    2.  应用正则 `^DVR_LoopRecording_(\d{4}-\d{2}-\d{2})_(\d{2}-\d{2}-\d{2})_(.+)\.(mp4|ts|mov)$`。
    3.  提取 `Date`, `Time`, `CameraPos`。
    4.  按 `Time` 聚合并判断时间差（≤ 2分钟为同一行程）。
*   **输出**：`Trip` 对象列表。

#### 4.4.3 多轨播放器 (Multi-Track Player)
*   **技术选型**：系统原生播放器 (AVPlayer) 或 IJKPlayer。
*   **同步机制**：
    *   主时钟源：以前摄视频（Front Camera）当前播放时间为基准 (`MasterClock`)。
    *   从属轨道：监听 `MasterClock` 变化，若误差 > 100ms，触发 `seekTo` 进行校准。
*   **性能优化**：非主视角使用低分辨率流（如有）或仅在需要时解码。

#### 4.4.4 隐私打码与导出 (Privacy & Export)
*   **技术选型**：FFmpeg (移动端编译版)。
*   **打码实现**：使用 `delogo` 滤镜或 `overlay` 图片覆盖指定坐标。
*   **裁切实现**：使用 `crop=in_w:in_h*0.85:0:0` (相对比例) 移除底部敏感区域。
    *   **Constraint (CRITICAL)**: 严禁使用绝对像素值（如 `crop=3840:1800`），必须使用相对比例因子 (`in_w`, `in_h`) 以适配 M5/M7/M9 不同车型及 2K/4K 分辨率差异。
*   **极速模式**：检测无转码需求时，生成 `concat` 列表，执行 `-c copy`。

---

## 5. 风险 (Risks)

| 风险 | 影响 | 概率 | 缓解措施 |
| --- | --- | --- | --- |
| **文件访问权限限制** | 高 | 中 | 针对 Android 11+ / HarmonyOS 申请 Scoped Storage 权限，引导用户授权特定目录。 |
| **多路视频解码性能瓶颈** | 中 | 高 | 限制同时解码路数（如最多 3 路），其他路显示静态帧；使用硬解。 |
| **FFmpeg 导出速度慢** | 中 | 中 | 优先推荐“无损拼接”模式；转码模式下开启硬件加速 (MediaCodec/AVCodec)。 |
| **文件名规则变更** | 高 | 低 | 正则表达式配置化，支持云端下发更新规则。 |

---

## 6. 实施计划 (Implementation Plan)

| 阶段 | 任务 | 描述 | 负责人 | 预估耗时 |
| --- | --- | --- | --- | --- |
| **Phase 1: 基础架构** | 工程搭建 | 初始化项目，集成 FFmpeg 库，配置 CI/CD | Dev 1 | 2d |
| | 文件扫描器 | 实现本地文件读取与正则解析逻辑 | Dev 1 | 3d |
| **Phase 2: 核心功能** | 首页 UI | 实现行程库列表、空状态、权限引导 | Dev 2 | 3d |
| | 多轨播放器 | 实现 6 轨视频加载与同步控制逻辑 | Dev 1 | 5d |
| **Phase 3: 编辑与导出** | 剪辑 UI | 实现时间轴拖拽、视角切换、隐私开关 | Dev 2 | 4d |
| | 导出引擎 | 封装 FFmpeg 命令，实现拼接与打码导出 | Dev 1 | 4d |
| **Phase 4: 测试与优化** | 单元/集成测试 | 覆盖核心算法（扫描、同步） | Dev 1 | 2d |
| | 性能测试 | 4K 视频解码测试、内存泄漏检测 | QA | 3d |
| | UI 走查 | 对照 DESIGN.md 进行像素级还原 | Designer | 2d |

**总计预估**: 约 28 人日 (5.5 周)

---

## 7. 测试策略 (Testing Strategy)

### 7.1 单元测试 (Unit Tests)
*   **Target**: 核心算法模块 (> 90% 覆盖率)。
*   **Scope**:
    *   **ParserRegex**: 测试文件名正则匹配的准确性（涵盖 M5/M7/M9 不同命名变体）。
    *   **TimeAligner**: 验证切片群时间对齐算法，特别是跨天、跨小时边界的场景。
    *   **DurationCalc**: 验证行程时长计算逻辑（断点判定阈值 2分钟）。

### 7.2 集成测试 (Integration Tests)
*   **Target**: 数据流转与文件系统交互。
*   **Scope**:
    *   **ScannerService**: 模拟相册中有 1000+ 个视频文件时的扫描性能与内存占用。
    *   **FFmpegBuilder**: 验证生成的 FFmpeg 命令字符串是否符合预期（特别是 filter_complex 拼接逻辑）。

### 7.3 性能测试 (Performance Tests)
*   **Target**: 确保低端机型也能流畅运行。
*   **Scenarios**:
    *   **多轨解码压力**: 同时解码 6 路 4K 视频，监控 CPU/GPU 占用率（目标 < 80%）。
    *   **内存泄漏**: 连续进入/退出剪辑页面 20 次，检查内存是否回落。
    *   **导出速度**: 1 小时 4K 视频极速拼接耗时 < 10秒。

### 7.4 端到端测试 (E2E Tests)
*   **Target**: 关键用户路径 (Happy Path)。
*   **Tools**: Maestro / Appium (或手动测试脚本)。
*   **Flows**:
    *   启动 App -> 自动扫描 -> 点击首个行程 -> 拖动时间轴 -> 点击导出 -> 验证相册中生成新视频。

---

## 8. 监控与可观测性 (Monitoring & Observability)

*   **Crash 监控**：集成 Sentry 或 华为分析服务，捕获崩溃堆栈。
*   **业务埋点**：
    *   `scan_duration`: 扫描耗时。
    *   `export_success`: 导出成功率。
    *   `export_duration`: 导出耗时。
    *   `feature_usage`: 隐私开关使用率。

---

## 9. 安全注意事项 (Security Considerations)

*   **本地处理**：所有视频处理均在本地完成，严禁上传用户视频到云端。
*   **权限最小化**：仅申请必要的读取权限，导出完成后释放。
*   **隐私默认开启**：首次进入编辑页，默认勾选“隐藏敏感信息”。
