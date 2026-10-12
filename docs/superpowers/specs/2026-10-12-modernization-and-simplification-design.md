# Smart-Drive-Media 现代化演进与系统极简化设计方案

> **状态**：草案待审  
> **日期**：2026-10-12  
> **目标版本**：HarmonyOS SDK API 23 (最低兼容) ~ API 26 (目标面向)  
> **设计原则**：不臃肿、后期轻松、易排查、工具包替代、系统极简

---

## 1. 背景与改造意图 (Intent & Why)

`Smart-Drive-Media`（智驾影音）经历多轮迭代后，沉淀了大量的架构负债与“屎山”特征：
- 根目录留存了一套完全未接入运行时的 Node.js 原型库（`/src`，近 3000 行），以及 80 个几乎完全测错对象的虚假测试；
- 核心功能存在严重断代与死穴：裁剪仅作用于 UI（导出永远是整条录像）、导出在无素材时发生 Promise 永久挂死、PingPong 播放器每加载一个片段泄漏一个文件描述符（FD）、音视频导出存在严重的封装时序倒挂；
- 架构过度复杂：3 套数据结构同构的 Editor 状态并存，充斥着胶水数据转换层；跨 NAPI 竟然采用私有 CSV 文本拼串；
- 性能与资源隐患：首页封面使用空实现导致网格卡片退化为数十个 `<Video>` 并发解码；FFmpeg 导出管线硬编码采用远古的 MPEG-4 纯 CPU 软编，且中间产生多次全量磁盘拷贝。

本次改造的核心意图：**以 HarmonyOS 现代 SDK（最低 API 23，目标 API 26）为底座，用官方系统工具包全面替换掉脆弱自研胶水，剔除全部历史包袱，修复核心功能与资源死穴，将系统大幅度“瘦身”并形成清晰易维护、易排查的工程结构。**

---

## 2. 目标、非目标与反目标 (Goals, Non-Goals & Anti-Goals)

### 2.1 目标 (Goals)
1. **底座升级至 API 23–26**：更新 `build-profile.json5`，启用新版本 SDK 语法与编译规范。
2. **代码库与二进制彻底减负**：
   - 彻底删除未接入 App 的 `/src` 历史目录及相关的 37 个 JS 假测试；
   - 清理 `cpp/libs` 中 25MB 逐字节完全重复的 FFmpeg 二进制副本，规范依赖路径；
   - 删除已被跟踪的 1.4MB `logs/debug.txt` 历史设备日志并完善 `.gitignore`。
3. **修复所有 P0 级功能与崩溃死穴**：
   - **导出挂死修复**：重构 `ExportManager` 状态机为结构化枚举，确保错误分支与无素材分支必定 settle 并支持超时兜底；
   - **裁剪功能打通**：端到端传递 `rangeStartMs`/`rangeEndMs` 至 Native，底层通过精准 Seek/时间窗口真正实现片段截取；
   - **FD 句柄闭环**：`PingPongTrackController` 严格闭环 `fs.closeSync(fd)`，消除 `EMFILE` 崩溃隐患；
   - **音轨时序修复**：重构 `export_engine.cpp`，消除视频全写完后再写音频的倒挂现象，按 PTS/DTS 时间片正确交织写入。
4. **官方现代工具包全面替换**：
   - 用系统 `AVImageGenerator`（或图片解码服务）替换首页封面假桩，首页卡片统一改为静态 `<Image>` 渲染；
   - 用官方 `@ohos.data.preferences` 补齐轻量持久化能力（记录模板偏好、隐私开关、最近行程）；
   - 用 `@ObservedV2` / `@Trace` 统一全工程 Editor 领域模型，彻底删除 3 套同构模型及所有中间胶水转换器；
   - 跨 NAPI 通信废除脆弱的 CSV 拼串，改用标准 NAPI 结构体或轻量 JSON。
5. **FFmpeg 滤镜管线极净化**：
   - 保留 FFmpeg 的多机位拼接布局（T1~T4 `vstack`/`hstack`/`crop`）与前摄隐私打码（`drawbox`）；
   - 消除第一阶段写入 `concat.mp4` 临时文件再由 `movie` 滤镜重读的低效磁盘链路，改为输入源直接进 FilterGraph；
   - 修复现代 FFmpeg 8.0 弃用的 `av_init_packet`，规范为动态 `av_packet_alloc`/`free`。

### 2.2 非目标 (Non-Goals)
1. **不做纯原生 OpenGL ES 渲染器重写**：经严谨评估，纯鸿蒙原生 AVCodec 缺少多路画面排版拼接（FilterGraph）能力；手写 OpenGL 多路视频混流不仅代码暴增数千行，而且极难调试维护。因此坚持保留成熟的 FFmpeg FilterGraph，不重复造轮子。
2. **不颠覆现有产品交互视觉**：保留首页网格、多选合并、编辑页 5 套经典预设模板（T1~T5）及时间轴拖拽体验，聚焦于架构治理与健壮性。

### 2.3 反目标 (Anti-Goals)
1. **严禁伪造进度与假状态**：彻底废除 `setInterval` 假装爬升的导出进度条，Native 按编码阶段真实上报，若无细粒度回调则诚实显示“处理中”而不伪造确定百分比。
2. **严禁不可达页面与死代码**：删除孤岛页面 `pages/Export.ets` 或将其真正接为导出收口页，不允许出现几百行无调用入口的代码。
3. **严禁字符串断言假测试**：绝不在 CI 中保留“读源码文件做 includes 正则断言”的虚假测试。

---

## 3. 详细实施蓝图与系统架构

### 3.1 架构分层演进对比

```
[ 改造前现状（臃肿混乱）]
  /src (3000行孤立JS) ──(完全无连接)──┐
  test/ (80个测错对象的假测试)         │
                                      ▼
  [Editor UI] ──(临时变量)──► [EditorTranslationEngine] ──► [ExportPayloadTranslator] 
        │                          │ (3重状态模型相互拷贝)
        ▼                          ▼
  [TimelineService] ──(CSV文本拼接)──► [napi_init.cpp] ──► [export_engine.cpp]
                                                               ├── 临时写出 3 个 concat.mp4
                                                               ├── movie 滤镜重新读入
                                                               ├── 恒定 MPEG-4 软编
                                                               └── 视频写完再写音频(倒挂)

-----------------------------------------------------------------------------------------

[ 改造后架构（极简、官方工具包替代）]
  [Index UI] ──(AVImageGenerator 静态缩略图)──► 零多余解码器占用
  [Preferences] ──(冷启动持久化数据恢复)
        │
        ▼
  [Editor UI (ArkUI V2)]
        │ 依托单一 @ObservedV2 领域状态模型 (Single Source of Truth)
        ▼
  [ExportNativeBridge] ──(强类型 NAPI 结构体)
        │
        ▼
  [export_engine.cpp]
        ├── FFmpeg FilterGraph 多流直接输入 (无 concat.mp4 中间落盘)
        ├── T1~T5 排版与 drawbox 打码滤镜
        ├── 音视频按 DTS 微交织写入
        └── 真实编码阶段进度回调
```

### 3.2 阶段与任务分解

#### 阶段一：环境升级与资产大清洗 (P0)
1. **构建配置升级**：
   - 修改 `build-profile.json5`：
     ```json5
     "compatibleSdkVersion": "23",
     "targetSdkVersion": "26",
     ```
   - 验证编译选项，启用现代 TS/ArkTS 严格类型检查。
2. **物理删除废弃模块**：
   - 物理删除根目录 `/src` 全部内容；
   - 物理删除 `test/` 目录下全部针对 `/src` 的旧测试和 7 个字符串匹配测试文件；
   - 物理删除 `entry/src/main/js/harmonyBridge.mjs`（未被引用的孤儿文件）；
   - 物理删除 `entry/src/main/ets/pages/Export.ets`（350 行孤岛未接入死页面）；
   - 从 `main_pages.json` 和 `AppConstants.ets` 中同步移除 `pages/Export` 路由配置。
3. **工程卫生与重复二进制剔除**：
   - 删除 `entry/src/main/cpp/libs/` 下与 `.ffmpeg-install` 重复的 25MB `.so` 文件，统一通过 CMakeLists 链接指定位置；
   - 清理 `logs/debug.txt`，将 `logs/` 与 `*.txt` 正式纳入 `.gitignore`。

#### 阶段二：P0 级核心功能与内存/句柄死穴修复
1. **打通完整裁剪链路**：
   - 在 `ExportNativeService` 的请求参数中显式增加 `startSec` 与 `endSec`（或 `rangeStartMs`, `rangeEndMs`）；
   - 在 `export_engine.cpp` 的输入流读取阶段，根据 `rangeStartMs` 执行 `av_seek_frame`（Seek 到关键帧）并根据时间差重新调整输出 PTS，确保用户裁剪的选区真实落地。
2. **修复导出 Promise 竞态卡死与中文协议**：
   - 重构 `ExportManager`：状态改用 TypeScript 强类型枚举 `ExportStatus { PENDING, PROCESSING, COMPLETED, FAILED }`；
   - 调整 `start()` 执行时序：确保先注册内部监听与回调记录，再触发异步任务；为迟到订阅提供当前状态快照补发；
   - 增加 180 秒全局超时兜底保障机制，无论底层发生任何异常，UI 一定能收到明确报错并重置导出遮罩。
3. **闭环文件描述符 (FD) 生命周期**：
   - 在 `PingPongTrackController.ets` 中，为 Slot 绑定关联的 `file` 对象句柄；
   - 在 `player.reset()`、`releaseSlot()`、切片预加载失败以及组件销毁阶段，使用 `try...finally` 确保强制执行 `fs.closeSync(file.fd)`；
   - 增加当前活跃 FD 数量的安全边界监控。
4. **重构音轨交织逻辑**：
   - 改造 `export_engine.cpp` 中的 `composeTemplateToMp4`：重构编码输出循环，在主循环中按 PTS/DTS 先后顺序交替写入视频包与音频包（微交织），杜绝整段视频写完后再追加音频的倒挂行为。

#### 阶段三：用官方工具包大幅简化应用层 (P1)
1. **封面缩略图工具包替换**：
   - 废除 `ExportNativeService.extractFirstFrameByService` 原样返回视频 URI 的伪实现；
   - 使用 `@ohos.multimedia.image` 或系统媒体辅助服务在后台提取视频第一帧生成低分辨率 WebP/JPEG 缩略图缓存；
   - 首页卡片彻底移除 `<Video>` 组件，恢复纯静态 `<Image>`，彻底终结首页 12 个解码器并发风暴。
2. **轻量持久化能力集成**：
   - 新建 `service/PreferencesService.ets`，基于 `@ohos.data.preferences` 封装；
   - 冷启动时自动恢复用户上次选择的预设模板（T1~T5）、前摄隐私打码偏好（车速/VIN/时间）以及最近访问的行程 ID，消除每次启动重置。
3. **领域状态模型大一统 (ArkUI V2)**：
   - 统一全仓领域模型，以 `model/AppState.ets` 为唯一数据真理源，全部使用 `@ObservedV2` 和 `@Trace` 声明；
   - 彻底删除 `EditorTranslationEngine.ets`、`ExportPayloadTranslator.ets` 等冗余胶水层；
   - 修复前摄隐私打码开关数据双向绑定，打通 UI Toggle 与导出配置，解绑 `maskTime` 与 `maskGps` 强耦合。
4. **跨 NAPI 通信协议结构化**：
   - 废除 `camera@timestamp@uri` 私有 CSV 拼串；
   - 采用标准 NAPI 结构体或标准化 JSON 字符串传递行程轨道元数据，杜绝特殊字符引发的解析崩溃。

#### 阶段四：FFmpeg 导出管线极简优化 (P2)
1. **消除无谓的中间落盘与二次解码**：
   - 改造导出管线：不再为 Front、Back、Side 各自生成一个中间 `.concat.mp4` 临时物理文件；
   - 统一在 FilterGraph 内部完成素材拼接与毫秒级精确裁剪，消除 3 次全量磁盘写与 3 次 `movie` 滤镜磁盘重读。
2. **清理弃用 C++ API**：
   - 替换 `export_engine.cpp` 中所有弃用的 `av_init_packet`，规范为现代的 `av_packet_alloc()` 与 `av_packet_free()`。
3. **真实进度通知**：
   - 废除 `setInterval` 假进度定时器；在 C++ 导出各阶段（转码帧计数 / 进度百分比）通过 NAPI 异步回调向上报真实进度，让用户与开发者具备真实的耗时感知。

### 3.3 架构预审技术裁决 (Architectural Decisions from Builder Check)

经架构预审员核查，为避免实现过程中的发散与重复造轮子，明确以下 4 项核心技术裁决：

1. **多片段拼接与裁剪架构**：
   - **裁决**：采用 **FilterGraph 内联拼接 + `trim` 滤镜方案**。利用 FFmpeg 内置的 `concat` 与 `trim` 滤镜完成毫秒级精确裁剪（滤镜在解码后自动丢弃未选中的帧，提供帧级精度的毫秒截取）。
   - **理由**：坚决贯彻“不臃肿、尽量利用工具包”原则，无需在 C++ 中额外手写上千行自研解复用器和时钟调度状态机，代码量精简 80%。
2. **无 AAC 编码器条件下的音轨处理**：
   - **裁决**：采用 **流式封包复制（Packet Copy）+ PTS/DTS 时间戳偏移重写**，按时间戳交织写入 MP4。裁剪起点对齐至最近的 AAC 压缩包边界（误差 < 22ms，人耳无法感知）。
   - **理由**：行车记录仪录音重在保真与轻量，避免在缺乏 AAC 编码器的情况下强行重编或引入庞大的编解码库。
3. **领域模型收口边界**：
   - **裁决**：**全仓收口于 `model/AppState.ets`**。将多轨素材、时间轴和导出必须的数据直接内聚在 `@ObservedV2` 的 `EditorStateModel` 中，`ExportManager` 直接消费此模型。
   - **理由**：彻底物理删除 `ExportSnapshot` 及 `EditorTranslationEngine`、`ExportPayloadTranslator` 等全部胶水类，实现真正的 Single Source of Truth。
4. **自动化测试体系**：
   - **裁决**：**轻量纯逻辑单测 + 手工全功能验收矩阵**。在清理 37 个旧测试后，针对时间轴切片计算、选区时间换算、状态机流转等高频出错纯逻辑建立秒级运行的自动化测试；端到端多媒体播放与导出依照验收清单进行闭环验证，不引入需要笨重真机环境的庞大模拟器测试套件。

---

## 4. 留给实现者的自由度 (What's Left to the Builder)

1. **缩略图缓存管理**：实现者可自主决定缩略图本地磁盘缓存的具体淘汰策略（例如 LRU 缓存上限 100 张或最大 50MB）。
2. **日志打印细节**：实现者可自主将 `Logger.ets` 改为纯内存 RingBuffer 队列，仅在错误发生时落盘，或直接按规范过滤高频无用 trace。
3. **持久化键值定义**：实现者可根据代码整洁性定义具体的 Preferences 存储键名。

---

## 5. 验收标准与交付物清单 (Acceptance Criteria)

1. **工程与体积**：
   - 编译配置中最低 API 为 23，目标 API 为 26；
   - 根目录下无 `/src` 废弃代码；无重复的 25MB `.so` 文件；
   - 单工程文件行数大幅缩减，不再包含 `pages/Export.ets` 死页面与 4 个数据转换胶水类。
2. **功能正确性**：
   - 用户在时间轴上拖拽选区后点导出，导出的视频内容**精确对应选取的起止时间**，不再是整段原片；
   - 行程为空或无素材时点击导出，界面能够立即收到明确错误提示并优雅关闭，**绝不发生永久卡死**；
   - 首页行程列表加载时，**绝不并发实例化和自动播放 Video 组件**，CPU/内存维持低水位；
   - 长时间在编辑页进行 Seek 和片段切换播放，通过系统句柄检查确认 **FD 数量平稳不增长**，无泄漏；
   - 导出的 MP4 文件在主流播放器中打开，**声画同步，无起止卡顿与音轨缺失**。
