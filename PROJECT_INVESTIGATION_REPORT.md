# Smart-Drive-Media 深度技术调查与代码审计报告

> **报告生成日期**：2026-10-12  
> **审计对象**：`Smart-Drive-Media` 智驾行车记录仪多路视频聚合与编辑系统  
> **审计范围**：应用架构（ArkTS / Stage 模型）、底层原生能力（C++ / NAPI / FFmpeg）、测试套件、工程配置及历史原型实现

---

## 一、 项目定位与全局背景

### 1.1 项目定位
`Smart-Drive-Media` 是一款面向 **OpenHarmony NEXT (API 12 / Stage 模型)** 的车载行车记录仪多视角视频处理应用。其核心定位是解决多摄行车记录仪（前视、后视、左侧视、右侧视、车内、广角等机位）生成的大量周期性循环录像（通常为 60s/段）在移动设备或智能座舱大屏上的**多路同屏同步播放、智能排版拼贴（Templates）、时间轴多轨微调与合并导出**需求。

### 1.2 架构割裂：双代码库与历史断代
在深入源码后发现，本项目存在非常典型的**两阶段演进断代**与**双代码库割裂**现象：
1. **历史原型层（Node.js / JS，位于 `/src` 目录）**：
   - 包含逻辑控制器、Mock 模型与一套完备的业务策略（如 `tripAggregator.js` 连续行程聚合、`StorageGuard.js` 存储警戒线保护、`CrashReporter.js` 崩溃上报、`VirtualClip.js` 虚拟切片等）。
2. **实际工程层（OpenHarmony ArkTS / C++，位于 `/entry` 目录）**：
   - 这是真实运行在鸿蒙设备上的生产应用，采用 ArkTS + ArkUI V2（`@ComponentV2` / `@ObservedV2`）以及 NAPI C++ 模块（`entry/src/main/cpp`）。
3. **断代矛盾**：
   - `/src` 中的大量防御性架构（如存储监控、崩溃恢复、指标埋点、安全审计）**根本没有接入 ArkTS 运行时**，完全被闲置。
   - 工程现有的 80 个测试用例中，绝大多数是在 Node.js 环境下测试 `/src` 原型，或针对 ArkTS/C++ 源码进行**静态文件文本正则匹配（Fake Guard Tests）**，造成了“测试全部通过”但实际存在诸多未跑通逻辑的虚假安全感。

---

## 二、 功能清单与实现状态矩阵

通过对 UI 组件、状态机、多媒体播放管线以及 C++ 导出内核的逐行代码审计，项目功能完成度分布如下：

| 功能模块 | 规划特性 | 真实代码实现状态 | 关键代码位置 | 状态判定 |
| :--- | :--- | :--- | :--- | :---: |
| **视频采集与发现** | 华为分享/相册目录遍历扫描 | 已实现，利用 `PhotoAccessHelper` 和 `fs.listFile` 扫描 | `HuaweiShareScanner.ets`<br>`MediaLibraryScanner.ets` |  **已实现** |
| | DVR 循环录像文件名解析 | 已实现，正则精准提取时间戳与机位标识 | `HuaweiShareScanner.ets:10-25` |  **已实现** |
| | 连续行程自动聚合算法 | 未启用，`tripAggregator.js` 未接入，每个 60s 录像生成一个独立行程 | `CoreBridge.ets:51-68` |  **降级/半成品** |
| **首页管理与多选** | 多行程网格列表渲染 | 已实现，基于瀑布流卡片展示多机位状态 | `Index.ets:70-135` |  **已实现** |
| | 视频真实封面帧提取 | **桩代码（Stub）**，直接返回视频 URI，引发并发播放 | `CoreBridge.ets:11-20` | ⚠️ **假实现/缺陷** |
| | 多行程手动批量合并 | 已实现，弹窗勾选并调用时间轴重构 | `TripMergeModal.ets` |  **已实现** |
| **多视角画布布局** | 5 种预设模板 (T1~T5) | 已实现双拼、倒三角、左右并列、三屏环绕、单路 | `TemplateEngine.ets:5-65` |  **已实现** |
| | 模板机位缺失合规校验 | 已实现，机位不满足时降级或禁用 | `TemplateEngine.ets:68-105` |  **已实现** |
| | 实时画布前视遮罩打码 | 预览算法已实现，支持黑边与打码区域映射 | `PrivacyMaskHelper.ets:1-70` |  **已实现** |
| **多轨播放与同步** | 双 AVPlayer A/B 乒乓无缝切换 | 已实现双 Slot 预加载交替无黑屏连播 | `PingPongTrackController.ets` |  **已实现** |
| | 多路机位绝对时钟同步 | 已实现主从机位时钟校准与追赶机制 | `GlobalTimelineManager.ets` |  **已实现** |
| | 三阶段手势时间轴 Seek | 已实现平移、微调、吸附防抖与状态屏障 | `Editor.ets:180-260` |  **已实现** |
| **剪辑与隐私控制** | 时间轴起止点裁剪（Trim） | **重大缺陷**：UI 裁剪参数未传递至导出引擎，仅保留跨度 | `Editor.ets` / `ExportManager.ets` | ⚠️ **重大缺陷** |
| | UI 隐私开关双向绑定 | **失效代码**：界面开关仅修改临时变量，未更新核心状态 | `Editor.ets:226-235` | ⚠️ **未生效** |
| **渲染与合成导出** | C++ FFmpeg 合成引擎 | 已实现，解析轨道与模板，通过 swscale 贴图合成 | `export_engine.cpp:115-280` |  **已实现** |
| | 鸿蒙 NDK 硬件编码加速 (VENC) | **未实现**，虽有预热探测，实际全部降级至 CPU MPEG-4 软编 | `export_engine.cpp:33-48` | ❌ **未实现** |
| | 真实导出进度回调 | **假实现**，C++ 未发事件，前端采用 `setInterval` 伪造 | `Editor.ets:295-315` | ⚠️ **伪造进度** |
| | 独立导出进度页 (`Export.ets`) | **孤岛页面**，完整实现却无路由跳转入口 | `pages/Export.ets` | ⚠️ **死代码** |
| | 水印与仪表盘遥测叠加 | 纯占位符，未接入 libavfilter 绘制 | `export_engine.cpp:138` | ❌ **未实现** |

---

## 三、 技术栈与架构全景

### 3.1 核心技术栈
- **应用框架**：OpenHarmony SDK API 12（Stage 模型，`UIAbility`）。
- **状态管理**：ArkUI V2 响应式体系（`@ComponentV2`、`@ObservedV2`、`@Trace`）。
- **多媒体播放**：`@ohos.multimedia.media.AVPlayer` 原生播放器能力。
- **文件与相册 I/O**：`@ohos.file.photoAccessHelper`、`@ohos.file.fs`。
- **跨语言通信**：OpenHarmony Node-API (NAPI)。
- **原生音视频处理**：C++ 17、FFmpeg 静态库（`libavformat`, `libavcodec`, `libswscale`, `libavutil`）。

### 3.2 运行时端到端架构链路

```
[ 行车记录仪 TF卡 / 华为分享相册 ]
               │
               ▼
   [ MediaLibraryScanner / HuaweiShareScanner ] (正则解析时间戳、机位)
               │
               ▼
   [ CoreBridge / AppStorage ] (生成行程数据，进入首页 Index)
               │
               ▼
   [ Editor (ArkUI V2) ] ◄───► [ GlobalTimelineManager / PingPongTrackController ]
     ├── 5种模板切分画布                ├── 双 AVPlayer (Slot A / Slot B)
     ├── 时间轴手势平移/微调            ├── 主从时钟对齐与漂移校准 (50ms 阈值)
     └── 前视隐私遮罩实时计算           └── 循环片段无缝换轨切换
               │
               ▼ (触发导出)
   [ ExportManager (ArkTS) ]
               │ (物化沙箱文件，组装轨道 Payload)
               ▼
   [ NAPI Bridge (entry.cpp) ]
               │ (通过 NAPI 传递 JSON / 参数结构)
               ▼
   [ export_engine.cpp (C++) ]
     ├── FFmpeg 多路解码 (libavcodec)
     ├── 画面布局重采样与网格拼贴 (swscale)
     ├── [缺失] OHOS 硬件编码加速 (降级为 FFmpeg mpeg4 软编)
     └── 合成写出目标 MP4
               │
               ▼
   [ PhotoAccessHelper ] ──► 回写到系统相册
```

---

## 四、 深度代码审计：高危缺陷与逻辑漏洞

通过阅读底层实现代码，发现以下数个严重影响功能正确性的致命缺陷：

### 4.1 【重大缺陷】时间轴裁剪起止点丢失（导出的视频内容错误）
- **代码位置**：
  - `entry/src/main/ets/pages/Editor.ets`
  - `entry/src/main/ets/services/ExportManager.ets:105-135`
  - `entry/src/main/cpp/export_engine.cpp:80-120`
- **缺陷剖析**：
  在 `Editor.ets` 中，用户拖拽时间轴裁剪手柄，选定了区间 `selectionStartSec` 到 `selectionEndSec`（例如原片共 60 秒，裁剪选择第 20 秒至第 40 秒）。
  但是在转交导出参数时：
  ```typescript
  // ExportManager.ets
  const clipDurationMs = endMs - startMs; // 20000ms
  // ... 仅把 expectedDurationSec = 20 秒作为总时长传给 C++
  // startMs (20000) 从未传递给 C++ 的 ExportTrack 结构体！
  ```
  在 C++ `export_engine.cpp` 中，解码器只认 `expected_duration_sec`，始终从每一轨视频的 **`00:00:00` 开始解码前 20 秒**。
- **后果**：无论用户在前端怎么裁切，导出的视频永远都是各路视频的**前 N 秒**，导致裁剪功能完全不可用。

### 4.2 【逻辑缺陷】UI 隐私打码开关状态脱节与死代码
- **代码位置**：`entry/src/main/ets/pages/Editor.ets:226-235`
- **缺陷剖析**：
  UI 层的车速、经纬度遮罩开关绑定如下：
  ```typescript
  Toggle({ type: ToggleType.Switch, isOn: this.mosaicEnabledUi })
    .onChange((isOn: boolean) => {
      this.mosaicEnabledUi = isOn;
      this.hasUnsavedChanges = true;
    })
  ```
  界面只改了 `mosaicEnabledUi` 这个本地临时变量。负责真正修改状态的 `togglePrivacy()` 方法在整个类中**没有任何地方调用**。
- **后果**：无论用户在界面上开启还是关闭隐私遮罩，底层的 `state.hideSpeed`、`state.hideGps` 永远保持初始值，UI 开关形同虚设。

### 4.3 【性能/设计缺陷】封面图桩代码引发全网格并发解码雪崩
- **代码位置**：`entry/src/main/ets/services/CoreBridge.ets:11-18`
- **缺陷剖析**：
  ```typescript
  public static async extractFirstFrameByService(sourceUri: string): Promise<string> {
    // 桩代码：直接返回视频文件本身的 URI
    return sourceUri;
  }
  ```
  在 `entry/src/main/ets/pages/Index.ets` 中，卡片布局把这个 URI 传给了 `<Video>` 组件并设置为静音自动加载。
- **后果**：当相册中有数十个行程视频时，首页一次性初始化数十个底层的硬解/软解播放实例，造成内存暴涨、主线程卡顿甚至播放器内核直接崩溃（Out of Player Instances）。

### 4.4 【体验缺陷】假定时器伪造导出进度
- **代码位置**：`entry/src/main/ets/pages/Editor.ets:295-315`
- **缺陷剖析**：
  C++ 层的 `ExportPipeline` 没有实现向 ArkTS 层的进度回调或 EventHub 通知。ArkTS 通过如下方式显示进度：
  ```typescript
  this.exportProgressTimer = setInterval(() => {
    if (this.exportProgress < 0.9) {
      this.exportProgress += 0.05;
    }
  }, 120);
  ```
- **后果**：如果底层合成遭遇大视频需要处理 2 分钟，进度条会在 2 秒内暴冲到 90% 然后假死卡住；若底层合成提前失败，界面依旧在跑假进度，直到最终 Promise 抛错。

### 4.5 【工程死代码】孤岛页面 `pages/Export.ets`
- **代码位置**：`entry/src/main/ets/pages/Export.ets`
- **缺陷剖析**：
  该文件完整实现了导出进度面板、取消按钮、结果预览以及后台任务常驻逻辑（共 150+ 行代码），但在 `Editor.ets` 中，导出被重写为一个内嵌弹窗 `CustomDialog`，工程的 `main_pages.json` 或路由调用链中根本没有通往该页面的入口。

---

## 五、 性能陷阱深度分析 (Performance Traps)

经过对资源生命周期、I/O 调度与 Native 底层的排查，发现了 4 个可能拖垮设备性能的高危陷阱：

### 5.1 致命陷阱一：文件描述符 (File Descriptor, FD) 泄漏
- **代码位置**：`entry/src/main/ets/services/PingPongTrackController.ets:65-80`
- **代码实录**：
  ```typescript
  const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
  slot.player.fdSrc = { fd: file.fd };
  ```
- **问题分析**：
  在 A/B 槽位（Slot A / Slot B）频繁换轨预加载视频片段时，每次都执行 `fs.openSync` 获得一个系统 FD，并将该 FD 交给 AVPlayer。然而，在 Slot reset、换片或播放器销毁的整个生命周期中，**从未调用过 `fs.closeSync(file.fd)`**！
- **危害**：
  OpenHarmony 进程默认的最大打开文件句柄数为 1024。在长行程（包含几十个片段）的播放、Seek、反复切换过程中，FD 持续单调递增，几分钟内就会耗尽句柄，触发系统的 `EMFILE (Too many open files)`，导致后续所有的文件读写和组件加载彻底崩溃。

### 5.2 性能陷阱二：高频日志磁盘 I/O 阻塞 UI 主线程
- **代码位置**：`entry/src/main/ets/services/Logger.ets:25-45`
- **代码实录**：
  ```typescript
  export function debugLog(tag: string, message: string): void {
    // 每次打印日志，直接同步/异步打开磁盘文件并写入落盘
    fs.open(logFilePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND)
      .then((file) => {
        fs.write(file.fd, `${new Date().toISOString()} [${tag}] ${message}\n`)
          .then(() => fs.close(file.fd));
      });
  }
  ```
- **问题分析**：
  在视频多轨播放时，`GlobalTimelineManager` 的主时钟同步每 30ms ~ 50ms 就会触发一次 `timeUpdate`，伴随着大量的时钟对齐判定日志（`ClockSync`、`SeekBarrier`）。
- **危害**：
  每秒数十次对闪存发起 `open -> write -> close` 操作，无任何内存缓冲队列。不仅严重争抢磁盘 I/O 锁，造成 ArkTS 线程抖动掉帧，还会剧烈损耗座舱车机与手机的 UFS/eMMC 闪存寿命。

### 5.3 性能陷阱三：视频导出全链路 4 倍磁盘空间占用与无节制文件搬运
- **流程链路**：
  1. `ExportManager.materializeInputUris`：相册原始视频通过 1MB 内存分片缓冲逐块拷贝到应用的沙箱缓存目录 (`cacheDir/export_inputs/`)；
  2. `export_engine.cpp`：FFmpeg 对多路输入视频进行处理，写出临时拼接流 `.concat.mp4`；
  3. `export_engine.cpp`：FFmpeg 编码完成输出至 `cacheDir/output.mp4`；
  4. `ExportManager.saveVideoToAlbum`：再次通过 1MB 内存分片把 `output.mp4` 完整读入并写入系统相册媒体库。
- **危害**：
  处理 4 路总计 5GB 的视频片段时，整个流水线需要至少 **20GB** 的瞬时空闲磁盘空间。在移动设备存储水位较低时，极易直接发生 `ENOSPC (No space left on device)` 导致导出失败中断。

### 5.4 性能陷阱四：FFmpeg MPEG-4 纯 CPU 软编码导致的功耗与发热失控
- **代码位置**：`build_ffmpeg.sh:25-35` 与 `export_engine.cpp:180-210`
- **问题分析**：
  查看编译脚本 `build_ffmpeg.sh`：
  ```bash
  --disable-encoders --enable-encoder=mpeg4
  ```
  项目中关闭了所有现代编码器（x264/x265），仅开启了古老的 `mpeg4` 软编格式。同时，C++ 层 `export_engine.cpp` 虽然试图加载 `libnative_media_venc.so` 做探测，但没有任何接入 OpenHarmony `OH_AVCodec` 的实际编码逻辑，最终 fallback 全部跑在 CPU 软编上。
- **危害**：
  合成 1080P/4K 高清多摄画面时，CPU 多核瞬间拉满 100%，不仅导出速度极慢（低于 0.3x 实时间），还会导致终端设备迅速发烫、降频，严重影响用户体验。

---

## 六、 核心系统架构缺陷深度剖析 (System Architecture Defects)

通过对整体工程生命周期、模块通信机制与领域模型的审计，项目当前存在 **6 大深层次架构缺陷**。这些问题并非表面偶发 Bug，而是系统级的设计失范：

### 6.1 架构缺陷一：双系统割裂与“僵尸防御架构”架空（Dual-System Disconnect）
- **代码现象**：
  - 根目录存在一套完整的 Node.js/JS 原型系统（`/src`），其中设计了优秀的防御性架构：`tripAggregator.js`（基于 2 分钟时间窗口的连续行程聚类算法）、`StorageGuard.js`（存储水位监测与自动清理保护）、`CrashReporter.js`（崩溃捕获与恢复机制）、`VirtualClip.js`（虚拟切片）等。
  - 真实运行在鸿蒙设备上的 ArkTS 生产工程（`/entry`）却完全是一套重新手写的代码。
- **架构根因**：
  - 原型阶段设计的完备**系统韧性架构**根本没有接入生产运行时。
  - 生产端为了赶进度，在 `CoreBridge.ets` 中大量使用硬编码桩实现（例如行程聚类退化为“每个 60s 录像生成一个独立行程”，封面提取直接返回视频源 URI）。
- **潜在恶果**：
  系统在架构上**完全缺乏防御性设计**。在没有 `StorageGuard` 保护的情况下，车载大视频处理极易耗尽闪存；在没有行程聚合的情况下，用户相册会产生大量孤立的 1 分钟碎片行程，严重违背产品初衷。

### 6.2 架构缺陷二：状态管理“三权分立”，缺乏单一真理源（Triple State Duplication）
- **代码现象**：
  工程内并存 **3 套数据结构高度同构、职责重叠的 Editor 状态模型**：
  1. `entry/src/main/ets/viewmodel/AppState.ets` 中的 `EditorStateModel`；
  2. `entry/src/main/ets/models/EditorState.ets` 中的 `EditorState`；
  3. `entry/src/main/ets/viewmodel/Models.ets` 中的 `EditorState`。
  工程为此编写了大量无营养的“胶水转换器”：`EditorTranslationEngine.ets`、`ExportPayloadTranslator.ets`。
- **架构根因**：
  违反了软件架构的 **Single Source of Truth（单一数据真理源）** 原则。每当 UI 交互发生变化，状态都要在这 3 套模型和 4 个胶水函数之间来回拷贝赋值。
- **潜在恶果**：
  **这是导致业务逻辑静默失败的元凶**。当前项目中发现的两个重大 Bug 均源于此：
  - **裁剪范围丢失**：UI 计算了裁剪区间，但在经过多层模型胶水转换时，`rangeStartMs` 字段被丢弃，导致 C++ 只能从 0 秒开始切；
  - **隐私遮罩失效**：UI 修改了界面层的临时变量，未能同步回核心业务模型，相关方法直接沦为死代码。

### 6.3 架构缺陷三：数据管线“过度物理化”，缺乏零拷贝与流式抽象（Over-Materialization Pipeline）
- **代码现象**：
  当前的视频导出处理是一套非常原始的“多重磁盘物理拷贝”管线：
  ```
  相册系统文件 
    ──(1MB分片拷贝)──► 沙箱缓存 export_inputs 
    ──(FFmpeg拼接)──► 中间临时文件 .concat.mp4 
    ──(FFmpeg软编)──► 输出临时文件 output.mp4 
    ──(1MB分片拷贝)──► 回写相册系统文件
  ```
- **架构根因**：
  在架构层**缺乏对底层文件描述符（FD）直读直写和流式抽象（Streaming / Zero-Copy）的设计**。把数据处理建立在“频繁生成中间临时物理文件”的基础上。
- **潜在恶果**：
  - **存储雪崩**：处理 4 路 5GB 录像，瞬间需要 **20GB+** 磁盘空闲空间。在设备存储吃紧时极易直接触发 `ENOSPC` 磁盘耗尽；
  - **完全丧失扩展性**：未来若要升级 4K 高清或 6 路机位并行，此架构会在第一步“拷贝到沙箱”阶段就发生 I/O 拥塞甚至 OOM 崩溃。

### 6.4 架构缺陷四：跨语言（ArkTS ↔ C++ NAPI）边界协议脆弱反模式
- **代码现象**：
  在 `TimelineService.ets` 中，向 C++ 传递多轨信息时，将结构化数据拼装成了私有 CSV 字符串：
  ```typescript
  // ArkTS 端：字符串拼接
  const csv = tracks.map(t => `${t.camera}@${t.timestamp}@${t.uri}`).join(',');
  ```
  C++ 底层 `entry.cpp` 再用 `std::stringstream` 手动 split 拆解，最后又包成 NAPI 对象传回给 ArkTS。
- **架构根因**：
  跨语言通信设计违背了 NAPI 规范。完全抛弃了 NAPI 的标准对象树或 TypedArray 机制，转而使用高开销、脆弱的文本协议。
- **潜在恶果**：
  - **协议极其脆弱**：只要视频路径或机位名中包含特殊字符（如 `@`、`,` 等），整个字符串拆分就会错位崩溃；
  - **序列化/反序列化性能浪费**：在密集调用的时间轴对齐场景下，频繁的字符串拷贝和分配加重了 GC 负担。

### 6.5 架构缺陷五：表现层越权直连，领域服务与页面强耦合
- **代码现象**：
  - `Editor.ets` 单文件承担了过多职责：不仅渲染画布、处理复杂平移手势、管理主从播放器时钟，还自己搞了一个内嵌弹窗 `CustomDialog` 处理导出，并在里面用 `setInterval` 跑虚假进度条；
  - 与此同时，工程里其实设计并实现了一个功能完备的独立导出页面 `pages/Export.ets`（具备取消、常驻后台、真实任务管理能力），但由于 `Editor.ets` 越权包揽了一切，`Export.ets` 彻底沦为无法访问的**孤岛死页面**。
- **架构根因**：
  缺乏清晰的 UI 路由与业务域（Domain / Service）边界，表现层没有做到职责单一，缺乏对异步长耗时后台任务（Video Export Pipeline）的独立服务抽象。
- **潜在恶果**：
  导出任务与 `Editor` 页面强绑定。一旦用户在导出过程中误触返回或锁屏，由于缺少真正的后台 Service 接管，长达数分钟的导出任务将直接被强制销毁。

### 6.6 架构缺陷六：质量保障体系虚假化（Architectural Illusion of QA）
- **代码现象**：
  根目录 `test/` 下的 80 个测试用例全部由 Node.js 运行。由于 Node.js 无法加载 ArkTS 的 `@ohos.*` 运行时，大量的 Guard 测试（如 `task1234PlaybackSyncGuard.test.js`）退化成了：
  ```javascript
  const content = fs.readFileSync('entry/src/main/ets/pages/Editor.ets', 'utf-8');
  assert.strictEqual(content.includes('syncPlaybackClocks'), true);
  ```
- **架构根因**：
  测试架构完全脱离了真实运行时。它不是“单元测试”或“集成测试”，而是“静态代码字符串检查”。
- **潜在恶果**：
  **虚假的安全感**。哪怕底层存在致命的文件句柄泄漏（FD Leak）、裁剪起始点丢失、UI 开关失效，CI 流水线依旧会全绿通过。团队在不知情的情况下盲目合入代码，导致系统腐化加速。

---

## 七、 屎山代码与工程坏味道清单 (Code Smells & Tech Debt Checklist)

| 坏味道特征 | 所在文件 / 模块 | 具体表现与危害 | 恶化风险指数 |
| :--- | :--- | :--- | :---: |
| **胶水翻译代码泛滥** | `EditorTranslationEngine.ets`<br>`ExportPayloadTranslator.ets` | 几十行无意义的同构对象相互字段赋值 (`a.x = b.x`)，新增字段需改动多处 | 🔴 极高 |
| **文件描述符静默泄漏** | `PingPongTrackController.ets:65-80` | `fs.openSync` 获取 FD 传给 AVPlayer 后**从未执行 `closeSync`**，必发 `EMFILE` 崩溃 | 🔴 极高 |
| **高频无缓冲磁盘写** | `Logger.ets:25-45` | 时钟对齐每 30ms 触发一次无缓冲 `open->write->close`，损耗闪存寿命并阻塞 UI | 🔴 极高 |
| **死代码与孤立页面** | `pages/Export.ets`<br>`Editor.ets:togglePrivacy()` | 耗费精力编写的独立导出管理页无任何路由引用；隐私切换核心方法无外部调用 | 🟡 中度 |
| **伪造进度假定时器** | `Editor.ets:295-315` | C++ 导出无通知，前端 `setInterval` 假装递增进度，真实异常时 UI 假死卡住 | 🟡 中度 |
| **硬编码魔法常量** | `TemplateEngine.ets`<br>`export_engine.cpp` | 画布分辨率（1920x2160、3840x1080）硬编码写死在多个模块中，未做屏幕适配抽象 | 🟡 中度 |

---

## 八、 演进与重构建议路线图 (Refactoring Roadmap)

为防止项目在后续迭代中进一步恶化，建议按照 **P0（紧急止血）-> P1（性能跃升）-> P2（架构治理）** 三个阶段推进重构：

```
[ P0 阶段：紧急止血 (Day 1 - 3) ]
  ├── 1. 修复时间轴裁剪 StartMs 丢失问题 (透传至 C++ 并实现起始截取)
  ├── 2. 修复 PingPongTrackController 的文件描述符 (FD) 泄漏
  ├── 3. 补齐 UI 隐私打码开关数据双向绑定
  └── 4. 替换 Index 首帧假实现，引入系统 AVImageGenerator 静态缩略图

[ P1 阶段：性能跃升 (Day 4 - 7) ]
  ├── 1. Logger 改造：内存环形缓冲 (RingBuffer) + 异步批量落盘
  ├── 2. 消除 4x 磁盘搬运：FFmpeg 直接基于 FD 读取，导出流式写入相册
  ├── 3. 接入 OpenHarmony NDK OH_AVCodec 硬件编码器 (替换软编 mpeg4)
  └── 4. 导出进度全链路打通：C++ 异步回调通知 ArkTS 真实进度

[ P2 阶段：架构治理 (Day 8 - 14) ]
  ├── 1. 斩断双代码库：废除/删除根目录 /src 历史陈旧原型，核心防御策略移植到 ArkTS
  ├── 2. 状态模型大一统：统一为单一 @ObservedV2 模型，删除所有胶水翻译类
  ├── 3. 废除 CSV 字符串跨语言序列化，改用标准 NAPI 结构体交互
  └── 4. 重构测试体系：引入 DevEco Hypium 测试框架，实施真实运行期单测
```

### 8.1 P0 阶段：紧急止血（立即修复）
1. **时间轴裁剪修复**：
   - 在 `ExportManager.ets` 的 `ExportTrack` 结构中增加 `rangeStartMs` 和 `rangeEndMs` 字段；
   - 在 `export_engine.cpp` 中，读取输入视频流后，根据 `rangeStartMs` 进行精准 Seek（`av_seek_frame`），或通过 `-ss` 机制截取指定时间窗口。
2. **闭环文件描述符 (FD) 生命周期**：
   - 在 `PingPongTrackController.ets` 中，为每个 Slot 维护持有的 `fd` 句柄；在 Slot 释放、切换片段以及组件销毁（`aboutToDisappear`）时，严格执行 `fs.closeSync(slot.fd)`。
3. **真实缩略图提取**：
   - 废除 `CoreBridge.extractFirstFrameByService` 返回视频自身 URI 的假实现；使用 `@ohos.multimedia.image` 或系统提供的 AVMetadataHelper / AVImageGenerator 提取第一帧并保存为缓存图片，首页卡片仅渲染 `<Image>` 组件。

### 8.2 P1 阶段：性能优化（体验跃升）
1. **重构日志体系**：
   - 在 `Logger.ets` 中引入内存环形队列（RingBuffer），仅在内存中缓存最新 1000 条日志；
   - 屏蔽主时钟微秒级高频校准日志；仅在错误触发或用户主动反馈时批量异步落盘。
2. **消除无节制的中间磁盘拷贝**：
   - C++ FFmpeg 解码器通过传入的只读 FD（`av_format_open_input` 挂接自定义 `avio` 缓冲区读取）直接操作源文件，消除沙箱复制；
   - 导出成品通过 `PhotoAccessHelper` 创建的目标相册 FD 直接流式写出，消除本地临时文件二次转存。
3. **启用原生硬件编解码加速**：
   - 彻底废除 CPU `mpeg4` 软编。集成 OpenHarmony 原生多媒体开发框架中的 `OH_AVCodec`（`native_media_venc`），利用终端 NPU/GPU 硬件编码管线输出 H.264 / H.265 视频流。

### 8.3 P2 阶段：架构与工程治理（长效维护）
1. **清除双架构历史包袱**：
   - 评估并彻底删除根目录 `/src` 的 Node.js 废弃脚本与测试；将其中具备工程价值的 `StorageGuard` 或 `CrashReporter` 用纯 ArkTS 重新实现并归入 `entry/src/main/ets/services/`。
2. **状态模型归一化**：
   - 全工程以 `@ObservedV2` 规范重新定义单一真相源（Single Source of Truth），直接驱动 UI 与持久化；
   - 彻底删除 `EditorTranslationEngine.ets` 与 `ExportPayloadTranslator.ets` 等胶水层。
3. **真实端侧自动化测试建设**：
   - 废弃所有通过 Node.js 读文件字符串正则断言的假测试脚本；
   - 借助 DevEco Studio 内置的 Hypium 框架，编写真正能够在 OpenHarmony 模拟器或真实开发板上运行的 UI 与 Native 集成测试用例。

