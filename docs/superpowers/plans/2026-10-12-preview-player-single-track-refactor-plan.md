# 智驾影音 (Smart-Drive-Media) 预览播放器单轨极简重构实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 彻底淘汰应用层双播放器乒乓轮换（Ping-Pong）与多层 XComponent 堆叠，重构为基于 HarmonyOS API 26 播放策略的“单轨单芯 + 常驻 3 槽位 Surface + 前摄权威时钟栅栏对齐”极简预览架构，彻底根除播放黑屏与切片交界卡顿。

**Architecture:** 每个视轨由单实例 `SingleTrackController` 持有单一常驻 `AVPlayer`，UI 层 `EditorPreviewArea` 维护固定 3 槽位 `SingleTrackView`（Surface 终身常驻复用、永不销毁重建）。全局时间轴由 `GlobalTimelineManager` 以 Front 前摄为主时钟绝对基准，切片交界处触发全轨栅栏换段，利用 API 26 `showFirstFrameOnPrepare` 实现首帧即显与无感覆盖。

**Tech Stack:** HarmonyOS SDK API 23~26, ArkTS, `@ohos.multimedia.media` (AVPlayer), `@ohos.file.fs`, XComponent (Surface mode).

**Spec:** [docs/superpowers/specs/2026-10-12-preview-player-architecture-refactor-design.md](file:///C:/Users/gzr/Desktop/Smart-Drive-Media/docs/superpowers/specs/2026-10-12-preview-player-architecture-refactor-design.md)

## Global Constraints

- 最低兼容版本为 API 23，目标面向 API 26（`targetSdkVersion: "26.0.0"`）。
- 单个视轨内严禁并发创建多个 `AVPlayer` 实例（并发解码器总数严格控制在 <= 3 个）。
- 切换模板、行程变更或 Seek 时，严禁销毁重建 `XComponent` 组件树。
- 换段与 Seek 期间，所有文件描述符（FD）必须严格闭环（`fs.closeSync`）。
- 正常播放过程中禁止在从轨频繁调用 `seekTo()` 微调纠偏，仅在切片交界和手动 Seek 边界严格对齐。

## Review Focus

1. **单轨快速切段时的文件句柄与状态机复位**：连续调用 `switchSegment` 或高频 Seek 时，旧 FD 必须在 `player.reset()` 前关闭，新 FD 必须正确赋值给 `player.fdSrc` 且无内存/句柄泄漏。
2. **Surface 常驻下 XComponent `onLoad` 的先后时序**：若组件初始化时 `onLoad` 晚于数据源加载，Controller 需暂存状态并在 Surface 注入瞬间自动完成挂载与首帧渲染。
3. **主时钟跨分钟分界时的全轨栅栏等待**：前摄切片结束时触发跨段，若从轨切片略短或略长，Manager 必须暂停全局推进并等待所有活跃轨道 `prepared` 后统一恢复 `play()`。
4. **模板切换时的槽位数据重映射与隐藏**：从 3 机位模板（T2）切换到 2 机位模板（T1）时，第 3 个 Slot 隐藏并暂停播放器，前两个 Slot 仅更新坐标与重绑数据源，宿主页面两阶段握手立即完成。
5. **API 26 `setPlaybackStrategy` 特性兼容降级**：在低版本系统或模拟器上缺失该接口时需做 `typeof` 安全防守，保证不发生运行时崩溃。

---

### Task 1: 实现单视轨控制器 `SingleTrackController`

**Files:**
- Create: `entry/src/main/ets/media/SingleTrackController.ets`
- Test: 单元逻辑测试/编译验证

**Interfaces:**
- Consumes: `@ohos.multimedia.media`, `@ohos.file.fs`
- Produces: 
  ```typescript
  export interface TrackSegmentSource {
    uri: string
    startMs: number
    durationMs: number
  }

  export class SingleTrackController {
    constructor(trackId: string, camera: string, isAudioMaster: boolean)
    getId(): string
    getCamera(): string
    isAudio(): boolean
    setSurfaceId(surfaceId: string): void
    bindSegments(segments: Array<TrackSegmentSource>): void
    init(surfaceId?: string): Promise<void>
    play(): Promise<void>
    pause(): Promise<void>
    seekTo(globalMs: number): Promise<void>
    switchSegment(nextIndex: number, offsetMs: number, autoPlay: boolean): Promise<void>
    setGlobalMuted(muted: boolean): Promise<void>
    setPlaybackRate(rate: number): Promise<void>
    setCallbacks(onProgressChanged?: (globalMs: number) => void, onTrackEnded?: () => void): void
    release(): Promise<void>
  }
  ```

- [ ] **Step 1: 创建 `SingleTrackController.ets` 骨架与接口定义**
  定义 `TrackSegmentSource`、内部状态流转与单 `AVPlayer` 持有属性。

- [ ] **Step 2: 实现状态机监听、句柄安全释放与 API 26 播放策略注入**
  在 `initialized` 状态时绑定 `surfaceId`，安全调用 `setPlaybackStrategy({ showFirstFrameOnPrepare: true })`，并在换源时严格执行 `fs.closeSync(openedFd)`。

- [ ] **Step 3: 实现单轨分段定位、单轨换段与 Seek 版本防抖机制**
  实现 `resolveSegment(globalMs)`、`switchSegment(targetIndex, offsetMs, autoPlay)` 与 `seekTo(globalMs)`，利用自增 `seekEpoch` 丢弃过时操作。

- [ ] **Step 4: 编译检查验证**
  验证 `SingleTrackController.ets` 语法及类型定义无错。

---

### Task 2: 实现极简单视轨组件 `SingleTrackView`

**Files:**
- Create: `entry/src/main/ets/components/SingleTrackView.ets`

**Interfaces:**
- Consumes: `SingleTrackController`
- Produces: `@Component struct SingleTrackView`

- [ ] **Step 1: 编写 `SingleTrackView.ets`**
  单层 `XComponent({ type: 'surface' })`，组件卸载时不销毁播放器，仅在 `onLoad` 时将 `surfaceId` 交付给 Controller，代码控制在 40 行以内。

- [ ] **Step 2: 编译与类型检查**
  确保与 ArkUI 规范完全吻合。

---

### Task 3: 改造 `GlobalTimelineManager` 为权威前摄栅栏时钟

**Files:**
- Modify: `entry/src/main/ets/media/GlobalTimelineManager.ets`

**Interfaces:**
- Consumes: `SingleTrackController`
- Produces:
  ```typescript
  export class GlobalTimelineManager {
    registerTrack(track: SingleTrackController): void
    setDuration(durationMs: number): void
    play(): Promise<void>
    pause(): Promise<void>
    seek(globalMs: number): Promise<void>
    setMuted(muted: boolean): Promise<void>
    setPlaybackRate(rate: number): Promise<void>
    release(): Promise<void>
  }
  ```

- [ ] **Step 1: 升级轨道注册类型为 `SingleTrackController`**
  移除对旧 `PingPongTrackController` 的依赖，统一使用新单轨控制器。

- [ ] **Step 2: 实现前摄权威时钟推进与切片跨界栅栏同步**
  当 Master 视轨播放到当前切片末尾，Manager 统一暂停推进，向全活跃视轨分发 `switchSegment(nextIndex, 0, true)`，等待全轨就绪后统一恢复 `play()`。

- [ ] **Step 3: 优化全局 Seek 与暂停/恢复时序**
  Seek 时统一派发给所有视轨，清除正在等待的旧跨段任务，保持各机位在离散边界点分秒对齐。

---

### Task 4: 重构 `EditorPreviewArea` 为常驻 3 槽位池架构

**Files:**
- Modify: `entry/src/main/ets/components/EditorPreviewArea.ets`

**Interfaces:**
- Consumes: `SingleTrackView`, `SingleTrackController`, `GlobalTimelineManager`
- Produces: `@Component struct EditorPreviewArea`

- [ ] **Step 1: 声明常驻 3 槽位状态池**
  在 `EditorPreviewArea` 中固定预置 3 个常驻 Slot 模型，包含固定的 Controller 与常驻绑定的 `SingleTrackView`。

- [ ] **Step 2: 重构模板切换与几何映射算法**
  切换模板时，只计算并设置 3 个 Slot 的 `x, y, width, height, zoomX, visible`，并动态调用对应 Controller 的 `bindSegments()`，**不销毁重建 XComponent 组件树**。

- [ ] **Step 3: 简化宿主 `Editor.ets` 握手**
  当模板几何与数据源配置就绪后，直接向宿主触发 `onTemplateSwitchStageReady(taskId, 'prepared')`，彻底删除旧有的 1800ms 异步 `surfaceReady` 等待队列。

---

### Task 5: 清理旧有乒乓代码并完成全链路端到端验证

**Files:**
- Delete: `entry/src/main/ets/media/PingPongTrackController.ets`
- Delete: `entry/src/main/ets/components/PingPongTrackView.ets`
- Verify: `entry/src/main/ets/pages/Editor.ets`

- [ ] **Step 1: 删除废弃的乒乓播放器文件**
  彻底删除 `PingPongTrackController.ets` 与 `PingPongTrackView.ets`，消除死代码。

- [ ] **Step 2: 检查全局导入与引用完整性**
  确认无任何遗留导入，编译检查通过。

- [ ] **Step 3: 运行端到端行为验证**
  验证单机位、双机位（T1/T3）、三机位（T2/T4）预览播放；高频拖拽 Seek；切片跨分钟换段连续播放无黑屏。
