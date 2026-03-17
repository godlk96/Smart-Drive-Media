# HarmonyOS NEXT 剪辑预览无缝播放重构技术规格（API 12+）

## 1. 背景与问题定义

当前“剪辑预览页”在连续播放多个 1 分钟片段时，主流程仍以单实例 `AVPlayer` 切换 URL 为核心，交界处出现卡顿、黑屏、音频断层。现有实现将切段调度分散在页面层多个布尔状态中，导致：

- 切段触发点分散（定时提前切段 + completed 回调），容易竞态
- 预热、切换、播放控制交错，状态不可证明
- UI 与播放器绑定关系弱一致，交界瞬间存在可见闪烁

本规格目标是抛弃现有拼装式切段逻辑，重构为可验证的“乒乓缓冲双路播放器”架构。

## 2. 目标与非目标

### 2.1 目标

- 实现片段 N 到 N+1 的零黑屏、零可感知停顿、音频连续衔接
- 在 ArkTS + API 12+ 范围内完成，不引入 C++ OpenGL 播放引擎
- 建立单一调度入口 `SeamlessPlayerManager`，统一管理双 `AVPlayer` 生命周期
- 提供高内聚 UI 组件 `SeamlessPreviewView`，内部双 `XComponent` 完全重叠并可瞬时置顶切换
- 严格遵守 `AVPlayer` 状态机：`idle -> initialized -> prepared -> playing -> stopped -> released`

### 2.2 非目标

- 本轮不改动导出链路（FFmpeg/NAPI）与模板业务规则
- 本轮不实现跨轨道音频混音，仅保证主音轨连续
- 本轮不扩展三路及以上播放器并发

## 3. 重构范围

- 完全替换 `entry/src/main/ets/components/SeamlessVideoPlayer.ets`
- 在 `entry/src/main/ets/components/` 新增：
  - `SeamlessPlayerManager.ets`
  - `SeamlessPreviewView.ets`
- `Editor.ets` 侧移除现有主画面 A/B 手工切换状态与逻辑，改为通过 `SeamlessPreviewView` 提供片段序列与控制命令

## 4. 总体架构

### 4.1 分层职责

1. `SeamlessPreviewView`（UI 层）
   - 渲染两个重叠 `XComponent`
   - 采集 `surfaceIdA/surfaceIdB`
   - 订阅 manager 的“前台路由”事件并切换可见层级
   - 对外暴露播放、暂停、seek、重载片段列表接口

2. `SeamlessPlayerManager`（调度层）
   - 持有 `PlayerA/PlayerB`
   - 维护当前播放片段索引、前台播放器、后台预热播放器
   - 管理预加载、瞬时交替、轮转释放、异常恢复
   - 输出状态事件：`onSwapTo(playerSlot)`、`onError(code)`、`onClipChanged(index)`

3. `ClipProvider`（数据输入层，来自 Editor/Bridge）
   - 提供顺序片段列表 `ClipItem[]`
   - 每个片段包含 `uri/durationMs/clipId`

### 4.2 乒乓轮转策略

- 时刻 T：A 播放 Clip N，B 预热 Clip N+1 至 `prepared`
- 到达切点：立即执行 `B.play()`，并通知 UI 将 B 对应 `XComponent` 置顶
- 切换完成：A 进入回收并装载 Clip N+2，等待下一次切换
- 如此循环：`A <-> B`

## 5. 状态机设计

### 5.1 Manager 级状态

- `IDLE`：尚未绑定 surface 或无片段
- `BOOTSTRAPPING`：创建双播放器并绑定 surface
- `PLAYING_ACTIVE_A` / `PLAYING_ACTIVE_B`
- `SWAPPING`：交界瞬时切换窗口
- `SEEKING`：全局 seek 期间，双路重定位
- `STOPPED`：用户暂停/停止
- `RELEASED`：页面销毁

### 5.2 单播放器子状态

- `EMPTY`：无实例
- `CREATED`：`createAVPlayer` 成功
- `INITIALIZED`：已设置 `url/fdSrc`
- `PREPARED`：`prepare()` 完成，首帧可出
- `PLAYING`
- `STOPPED`
- `RELEASED`

### 5.3 状态约束

- 任一时刻仅允许一个前台播放器 `PLAYING`
- 后台播放器允许 `PREPARED` 或 `INITIALIZED`，不允许后台 `PLAYING`
- `SWAPPING` 状态最多持续一个短窗口（建议 < 120ms），超时触发降级策略

## 6. 关键时序

### 6.1 首次启动

1. `SeamlessPreviewView` 获取 `surfaceIdA/B`
2. `manager.attachSurfaces(A, B)`
3. A 加载 `clip[0]` -> `prepare`
4. B 加载 `clip[1]` -> `prepare`
5. A `play`，UI 置顶 A

### 6.2 正常切段

1. 前台播放器收到 `timeUpdate`
2. 当 `remainingMs <= swapThresholdMs`（建议 90~140ms）且后台已 `prepared`
3. 进入 `SWAPPING`：
   - 后台 `play`
   - 发送 `onSwapTo(后台槽位)` 给 UI
4. 旧前台 `stop/reset`，装载后续片段并 `prepare`
5. 状态回到 `PLAYING_ACTIVE_X`

### 6.3 失败切段降级

当后台未及时 `prepared`：

- 进入 `DEGRADED_SWITCH`
- 允许短暂静帧但禁止黑屏：维持旧前台最后一帧，等待后台可播后立即切
- 记录诊断事件 `PRELOAD_MISS`

## 7. 接口契约（ArkTS）

### 7.1 数据模型

- `ClipItem`
  - `clipId: string`
  - `uri: string`
  - `durationMs: number`

- `SeamlessSwapEvent`
  - `activeSlot: 'A' | 'B'`
  - `clipIndex: number`
  - `clipId: string`

### 7.2 Manager 对外接口

- `init(clips: ClipItem[]): Promise<void>`
- `attachSurfaces(surfaceA: string, surfaceB: string): Promise<void>`
- `play(): Promise<void>`
- `pause(): Promise<void>`
- `seek(globalMs: number): Promise<void>`
- `replacePlaylist(clips: ClipItem[], startIndex?: number): Promise<void>`
- `release(): Promise<void>`

### 7.3 View 组件接口

- 入参：
  - `clips: ClipItem[]`
  - `autoPlay: boolean`
  - `muted: boolean`
  - `onSwap?: (event: SeamlessSwapEvent) => void`
  - `onError?: (code: string, message: string) => void`
- 方法（由 controller 暴露）：
  - `start()`
  - `pause()`
  - `seek(ms: number)`
  - `setMuted(muted: boolean)`
  - `reload(clips: ClipItem[], startIndex?: number)`

## 8. UI 设计规范（SeamlessPreviewView）

- 使用 `Stack` 包裹两个完全同尺寸、同位置 `XComponent`
- 两层默认都存在，禁止切段时销毁/重建节点
- 可见切换采用 `zIndex + opacity` 组合：
  - 前台层：`zIndex=2, opacity=1`
  - 后台层：`zIndex=1, opacity=1`（保持可渲染，避免重建抖动）
- 切换只改变层级，不改布局属性

## 9. AVPlayer 异步与资源管理规则

- 创建后仅在 `initialized` 设置 `surfaceId`
- 每次换源必须串行：`reset -> setSource -> prepare`
- `prepare` 完成才允许 `play/seek/setSpeed`
- 旧前台在切换后执行：
  - `stop`（若状态允许）
  - `reset`
  - 装载未来片段并 `prepare`
- 页面销毁必须严格 `release` 双实例，并解除所有监听

## 10. 与 Editor 集成改造

- 移除页面层以下状态：
  - `primaryUseA/primarySrcA/primarySrcB/primaryReadyA/primaryReadyB`
  - `standbyWarmUri/seamlessPendingPlay/isSwitchingClip`
- `Editor` 仅维护业务级时间轴与片段列表，不再关心 A/B 路由
- 统一通过 `SeamlessPreviewViewController` 发命令
- 切段事件由 `onSwap` 反哺 UI（如高亮当前片段）

## 11. 观测与诊断

必须新增结构化日志（避免字符串拼装噪声）：

- `PLAYER_STATE_CHANGED`
- `PRELOAD_START/PRELOAD_READY/PRELOAD_MISS`
- `SWAP_START/SWAP_DONE/SWAP_TIMEOUT`
- `RECYCLE_START/RECYCLE_DONE`
- `PLAYLIST_REPLACED/SEEK_APPLIED`

每条日志至少含：`sessionId`, `activeSlot`, `clipIndex`, `clipId`, `timestampMs`。

## 12. 风险与缓解

- 风险：后台 `prepare` 波动导致错过切点  
  缓解：动态阈值（基于最近一次 prepare 耗时）+ 提前预热

- 风险：双路同时占用资源导致低端机抖动  
  缓解：仅主轨双路，副轨维持单路；异常时自动降级单路

- 风险：异步回调串扰（过期回调）  
  缓解：为每次装载分配 `loadToken`，回调先验 token

## 13. 验收标准

- 连续 20 次跨片段切换无黑屏、无可感知卡顿
- 音频衔接无明显断层（人工听感 + 波形抽样校验）
- 快速拖动 seek 后仍能恢复双路预热并继续无缝切段
- 页面反复进出 30 次，无播放器泄漏、无崩溃

## 14. 实施里程碑

- M1：完成 `SeamlessPlayerManager` 与双路状态机
- M2：完成 `SeamlessPreviewView` 与双 `XComponent` 叠层切换
- M3：完成 `Editor` 接入与旧逻辑删除
- M4：完成稳定性验证与回归
