# 智驾影音 (Smart-Drive-Media) 预览播放器单轨极简化架构设计

> **状态**：设计完成待评审  
> **日期**：2026-10-12  
> **目标版本**：HarmonyOS SDK API 23 (最低兼容) ~ API 26 (目标面向)  
> **设计原则**：单轨单芯、Surface 常驻、API 26 首帧无感切换、主时钟权威同步、精简不臃肿  

---

## 1. 背景与改造意图 (Intent & Why)

### 1.1 现状痛点
在 `Smart-Drive-Media` 中，多机位视频预览页（`EditorPreviewArea`）稳定性极差，常发两大典型致命 Bug：
1. **点击无视频画面展示（黑屏/空界面）**：切换模板或拖动时间轴后，画面经常一片漆黑或播放器假死。
2. **多视频交界处卡顿不连贯、甚至直接卡死**：切片从前一段切换到后一段时发生严重顿挫、跳帧、甚至停在末尾不再继续播放。

### 1.2 根因分析
通过对原有代码的深度审查，发现根本原因在于底层的 **“应用层 A/B 双播放器乒乓轮换（Ping-Pong）”** 架构设计存在结构性缺陷：
- **硬件解码器爆炸**：每个视轨各自创建 `slotA` 和 `slotB` 两个 `AVPlayer` 实例。在 T2/T4 等 3 机位模板下，同时活跃多达 **6 个 AVPlayer 实例与 6 个 XComponent Surface**。移动端/车机芯片硬解实例通常受限于 4~8 路，并发高负载下经常触发底层解码通道分配失败，无声无息地导致黑屏。
- **Surface 异步时序错位**：UI 组件层在 `Stack` 中叠加两个 `XComponent`，通过 `zIndex` 切换。每逢模板切换或组件重建，旧 Surface 被系统销毁，而新 Surface 的 `onLoad` 到达时序不确定，导致播放器在已失效或尚未初始化的 Surface 上调用 `prepare()`。
- **20ms 虚假无缝竞态**：原设计试图在 `remainingMs <= 20ms` 时触发备用槽无缝交接，然而鸿蒙系统的 `timeUpdate` 事件回调周期通常为 100~250ms，导致 20ms 窗口几乎不可能命中；最终大多回退到 `completed` 状态，而此时备用播放器往往未能按时就绪，导致播放彻底卡死。
- **代码极度臃肿脆弱**：原 `PingPongTrackController` 超过 830 行，混杂了两套播放器状态机、备用预加载、图层切换、FD 泄漏防护等复杂逻辑，牵一发而动全身，修不胜修。

### 1.3 改造意图
彻底废弃应用层脆弱的 A/B 乒乓双播放器机制，重构为**基于 HarmonyOS API 26 现代特性的“单轨单播放器 (Single Track Player)”极简架构**。将多路硬解实例数从 6~8 个直接压降到 2~3 个安全线内，通过 Surface 常驻和 API 26 首帧渲染策略彻底消灭黑屏与卡死，代码量精简 60% 以上，并保障未来功能扩展性。

---

## 2. 目标、非目标与反目标 (Goals, Non-Goals & Anti-Goals)

### 2.1 目标 (Goals)
1. **架构彻底降维**：
   - 每个物理视频轨道仅对应 **1 个常驻 AVPlayer** 和 **1 个单层 XComponent**。
   - 彻底删除 `slotA`/`slotB` 乒乓轮换、图层叠放、`zIndex` 切换及应用层跨播放器对齐逻辑。
2. **根除黑屏与交界卡死**：
   - **常驻槽位池（Persistent 3-Slot Pool）**：`EditorPreviewArea` 预置固定 3 槽位（当前模板最大机位数），模板切换时**永不销毁重建 XComponent**，仅动态修改几何坐标与数据源。SurfaceId 终身常驻，消除异步 `onLoad` 竞态。
   - **API 26 首帧即显策略**：利用 HarmonyOS API 26 Media Kit 的 `setPlaybackStrategy({ showFirstFrameOnPrepare: true })`，换源或 Seek 时新切片首帧秒出。
   - **自然衔接无黑闪**：切片换源期间保持原 Surface 最后一帧冻结，新切片首帧渲染就绪后立即无缝接替播放。
3. **主时钟权威栅栏同步 (Master-Driven Barrier Sync)**：
   - 以 Front（前摄）为主时钟绝对基准。主摄播完当前分钟切片跨界时，由 `GlobalTimelineManager` 统一向所有活跃机位发出换段指令，全轨就绪后统一继续播放，保证多机位画面分秒不差、同频切换。
4. **精简高效与未来可扩展**：
   - 彻底删除臃肿胶水代码，单轨控制器代码行数从 830+ 行精简至 260 行左右。
   - 提供标准化的媒体轨道抽象接口，后续可平滑扩展视频滤镜、水印、以及 Native 流式接入。

### 2.2 非目标 (Non-Goals)
1. 不改动导出的 C++/FFmpeg 底层导出管线（`smartdrive_exporter`）。
2. 不改动上层 Editor 的模板布局几何比例（T1~T4 的分屏比例、网格坐标均保持一致）。
3. 不引入本地第三方 HTTP 服务器库来支持 HLS（避免引入额外的端口占用、网络权限与内存开销）。

### 2.3 反目标 (Anti-Goals)
1. **严禁在单轨道内并发创建多个 AVPlayer**。
2. **严禁在视频切换、模板变更或 Seek 时销毁重建 XComponent 组件**。
3. **严禁在应用层使用微秒级时间差（如 20ms）进行竞态猜测切换**。
4. **严禁在正常连续播放过程中对从轨频繁调用 `seekTo()` 尝试微调**（防止解码管道频繁打断引发卡顿）。

---

## 3. 详细架构设计与落地实现方案

### 3.1 架构分层对比

#### 改造前（脆弱的乒乓双槽架构）：
```
[EditorPreviewArea]
  └── [PingPongTrackView] (每个轨道 2 个 XComponent Stack 堆叠, zIndex 切换)
        └── [PingPongTrackController] (830+ 行)
              ├── Slot A: AVPlayer 1 (硬件解码器 1)
              └── Slot B: AVPlayer 2 (硬件解码器 2)
              (3 机位共 6 个 AVPlayer + 6 个 XComponent, 易超限崩溃, 20ms 竞态交接)
```

#### 改造后（现代单轨单芯极简架构）：
```
[GlobalTimelineManager] (权威前摄主时钟，驱动多轨栅栏换段与时间戳广播)
  │
  ├── [EditorPreviewArea] (固定 3 槽位池，XComponent 与 Surface 终身常驻)
        │
        ├── Slot 0: [SingleTrackView] ── [SingleTrackController] (AVPlayer 1, Master)
        ├── Slot 1: [SingleTrackView] ── [SingleTrackController] (AVPlayer 2, Slave)
        └── Slot 2: [SingleTrackView] ── [SingleTrackController] (AVPlayer 3, Slave)
```

---

### 3.2 具体组件落地细节

#### 落地组件 1：`SingleTrackController.ets`（替代原有 `PingPongTrackController.ets`）

**核心职责**：管理单个摄像机视轨的媒体播放生命周期，控制单个 AVPlayer 实例与常驻 Surface。

**数据结构**：
```typescript
export interface TrackSegmentSource {
  uri: string
  startMs: number
  durationMs: number
}

export type TrackPlayState = 'idle' | 'preparing' | 'ready' | 'playing' | 'paused' | 'ended'
```

**关键机制与落地逻辑**：
1. **单实例生命周期**：
   - 构造时创建单个 `AVPlayer`（`media.createAVPlayer()`）。
   - 持有 `surfaceId: string`，仅在初次获取或变更时设置给 `player.surfaceId`。
2. **API 26 播放策略注入**：
   - 在播放器进入 `initialized` 状态后，配置首帧即显：
   ```typescript
   if (typeof (this.player as any).setPlaybackStrategy === 'function') {
     (this.player as any).setPlaybackStrategy({ showFirstFrameOnPrepare: true })
   }
   ```
3. **换源与文件句柄闭环**：
   - 每次换源严格执行：
     1. `fs.closeSync(oldFd)` 闭环释放句柄；
     2. `fs.openSync(newUri)` 获取新 `fd`；
     3. `player.reset()` -> `player.fdSrc = { fd }`；
     4. `stateChange: initialized` -> 挂载常驻 `surfaceId` -> 配置 `showFirstFrameOnPrepare` -> `player.prepare()`；
     5. `stateChange: prepared` -> 触发 Promise resolve 或通知回调。
4. **单轨 Seek 机制**：
   - 接收目标时间戳 `globalMs`，换算切片索引及切片内偏移 `offsetMs`。
   - 若同一切片：直接执行 `player.seek(offsetMs, media.SeekMode.SEEK_PREV_SYNC)`。
   - 若跨切片：换段加载目标文件，在 `prepared` 后 Seek 到 `offsetMs`。
   - 采用 `seekEpoch` 任务版本号，高频拖动时丢弃旧任务，仅执行最新 Seek 请求。

---

#### 落地组件 2：`SingleTrackView.ets`（替代原有 `PingPongTrackView.ets`）

**核心职责**：纯净渲染视轨画面，提供不可摧毁的常驻 Surface。

**极简化实现**：
- 废弃 `Stack` 内部双 `XComponent`，仅保留一个简洁的 `XComponent`。
- 代码精简至 40 行以内：
```typescript
@Component
export struct SingleTrackView {
  controller?: SingleTrackController
  private xController: XComponentController = new XComponentController()

  aboutToAppear(): void {
    if (this.controller) {
      this.controller.attach()
    }
  }

  aboutToDisappear(): void {
    if (this.controller) {
      this.controller.detach()
    }
  }

  build() {
    XComponent({
      id: `track_${this.controller ? this.controller.getId() : 'default'}`,
      type: 'surface',
      controller: this.xController
    })
      .width('100%')
      .height('100%')
      .onLoad(() => {
        const surfaceId = this.xController.getXComponentSurfaceId()
        if (this.controller && surfaceId) {
          this.controller.setSurfaceId(surfaceId)
        }
      })
  }
}
```

---

#### 落地组件 3：`GlobalTimelineManager.ets`（主时钟绝对基准与栅栏对齐）

**核心职责**：担当主时钟裁判，驱动全视轨多机位时间同步。

**核心机制**：
1. **主时钟选举**：
   - 默认选择 Front（前摄）机位作为 Clock Master。
2. **多机位主从栅栏换段 (Master-Driven Barrier Handshake)**：
   - Clock Master 推进时间到达当前切片末尾，由 Manager 触发跨段事件；
   - Manager 向所有活跃机位（Master 与 Slaves）同步下发换段指令（切换到下一分钟切片）；
   - 各机位换源并 `prepare`，主从机位全部进入就绪状态后，Manager 统一发出 `play()` 指令；
   - 换段期间（约 100~200ms）保持前一分钟的最后一帧，随后多机位同时启动下一段，彻底杜绝各自播完导致的画面时间错位。
3. **运行时零打断与边界精准对齐**：
   - 在正常播放过程中，信任底层硬件芯片的解码时钟，**不进行运行时连续 Seek 纠偏**；
   - 仅在用户手动拖拽时间轴（Seek）和切片换段（Barrier）这两类离散边界上实施严格时间对齐。

---

#### 落地组件 4：`EditorPreviewArea.ets`（常驻 3 槽位池）

**核心职责**：宿主容器与几何排版。

**核心机制**：
1. **预置常驻 3 槽位（Slot 0, Slot 1, Slot 2）**：
   - 无论用户在 T1（2 机位）、T2（3 机位）、T3（2 机位）、T4（3 机位）之间如何切换，底层始终保持这 3 个 `SingleTrackView` 和对应 Controller 存活；
   - 切换模板时，只计算并更新每个 Slot 的位置参数（`x, y, width, height, zoomX`）以及是否显示（`visible: boolean`）；
   - 根据新模板分配机位数据源（例如 Slot 0 绑定 Front，Slot 1 绑定 Left 等），调用 `controller.updateSegments()` 换源；
   - **XComponent 组件树 0 次重建，Surface 0 次销毁**，从根源上消灭“点击无视频显示”与切模板黑屏。
2. **兼容宿主 `Editor.ets` 握手**：
   - 当接收到 `switchTaskId` 时，在数据源与几何位置就绪后立即回调 `onTemplateSwitchStageReady(taskId, 'prepared')`，平滑兼容上层状态机，无需漫长的延时看门狗。

---

## 4. 迁移与过渡计划 (Implementation Steps)

1. **Step 1：新建单轨组件体系**
   - 新建 `SingleTrackController.ets`（单 `AVPlayer`、API 26 播放策略、FD 安全闭环）。
   - 新建 `SingleTrackView.ets`（单 `XComponent`，常驻 Surface）。
2. **Step 2：适配 `GlobalTimelineManager`**
   - 升级为“主摄绝对基准 + 栅栏同步换段 + 边界精准对齐”调度模式。
3. **Step 3：改造 `EditorPreviewArea`**
   - 改造为固定 3 槽位常驻池架构，移除原有的双层图层通知与 `surfaceReady` 繁复等待队列。
4. **Step 4：清理废弃代码**
   - 彻底删除 `PingPongTrackController.ets` 与 `PingPongTrackView.ets`，净化工程目录。
5. **Step 5：多场景验证与压测**
   - 验证单机位、双机位（T1/T3）、三机位（T2/T4）连续播放；
   - 验证多段切片交界处平滑过渡，画面同分同秒对齐；
   - 验证高频连续拖拽 Seek、暂停/播放切换时的响应速度与内存/FD 稳定性。

---

## 5. 遗留给实现者 (Left to the Builder)
1. 微调 Seek 模式（`SEEK_PREV_SYNC` 对比 `SEEK_CLOSEST` 在低端设备上的流畅度表现）。
2. 在 `SingleTrackController` 中日志打印的打标格式，保持与项目现有 Logger 风格一致。
