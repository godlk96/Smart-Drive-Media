# 智驾影音 App 剪辑预览引擎重构技术规格

## 1. 背景与目标

当前 Editor 预览链路为“主画面双路无缝 + 副画面单路播放器”混合实现，跨 60s 物理切片时存在黑屏、断音与多播放器 Seek 失步问题。  
本次重构目标是落地“全局时钟屏障 + 全轨乒乓双缓冲”架构，使所有轨道具备统一时钟、统一屏障、统一生命周期管理能力，保障拖拽与连续播放均可无撕裂衔接。

## 2. 范围

### 2.1 in-scope
- 清理旧版主副播放器组合逻辑：
  - `SeamlessPlayerManager`
  - `SeamlessVideoPlayer`
  - `Editor.ets` 中基于 `bridge.playNextClip` 的预览切片联动逻辑
- 新增统一预览调度引擎：
  - `GlobalTimelineManager.ets`
  - `PingPongTrackController.ets`
- 新增表现层组件：
  - `PingPongTrackView.ets`
  - `EditorPreviewArea.ets`
- 将 Editor 预览改为只消费统一状态与统一调度器，不再在 UI 层处理切片映射。

### 2.2 out-of-scope
- 导出链路与 ffmpeg 合成策略变更
- 模板定义数据模型大改（保留现有 `TemplateId` 与 camera 枚举）
- 历史 JS 端模拟器重构（`src/logic`）

## 3. 现状问题摘要

- 主副通道能力不对称：主画面可双缓冲，副画面单路，导致切片时 prepare/reset 黑屏。
- 音频归属分散：由页面层按槽位手工 mute/unmute，跨模板与跨切片易错。
- Seek 无屏障：多播放器异步 seek，UI 先后刷新，产生画面错位与“橡皮筋”现象。

## 4. 目标架构

### 4.1 核心原则
- 单一时钟源：预览页仅存在一个全局时间主宰。
- 单一调度入口：play/pause/seek 只允许由全局管理器下发。
- 轨道自治：每个视角轨道内部负责“全局毫秒 -> 物理切片 + 片内偏移”的映射。
- 表现解耦：UI 层只渲染轨道状态，不参与切片策略。

### 4.2 模块关系
- `GlobalTimelineManager`
  - 维护播放状态与全局游标
  - 注册并驱动多个 `PingPongTrackController`
  - 提供 seek 屏障并发控制
- `PingPongTrackController`
  - 每轨双 AVPlayer（A/B）乒乓切换
  - 处理切片映射、预热、交接、释放
  - 管理音频主轨静音策略
- `PingPongTrackView`
  - 双 `XComponent` 重叠渲染
  - 响应 `activeLayer` 做瞬时层级切换
- `EditorPreviewArea`
  - 根据模板创建轨道控制器并布局
  - 负责模板切换时销毁旧实例并重建

## 5. 详细设计

## 5.1 GlobalTimelineManager.ets

### 5.1.1 状态
- `globalDurationMs: number`
- `globalPlayheadMs: number`
- `playbackState: 'playing' | 'paused' | 'buffering'`
- `tracks: PingPongTrackController[]`
- `isSeeking: boolean`
- `seekEpoch: number`（用于抑制过期 seek 回调）

### 5.1.2 接口
- `registerTrack(track: PingPongTrackController): void`
- `unregisterTrack(trackId: string): void`
- `play(): Promise<void>`
- `pause(): Promise<void>`
- `seek(globalMs: number): Promise<void>`
- `release(): Promise<void>`

### 5.1.3 Seek 屏障
1. `isSeeking=true`，`seekEpoch++`，状态切至 `buffering`。
2. 并发 `await Promise.all(tracks.map(t => t.pause()))`。
3. 并发 `await Promise.all(tracks.map(t => t.seekTo(globalMs, seekEpoch)))`。
4. 若 seekEpoch 未被后续 seek 覆盖，更新 `globalPlayheadMs`，状态回 `paused`。
5. 若调用方期望继续播放，再统一触发 `play()`。

### 5.1.4 失败处理
- 任一轨 seek 失败：
  - 全局状态置 `paused`
  - 记录失败轨道
  - 拒绝本次 Promise，禁止自动恢复播放

## 5.2 PingPongTrackController.ets

### 5.2.1 状态
- `trackId: string`
- `camera: CameraPosition`
- `isAudioMaster: boolean`
- `playerA`, `playerB`
- `activeLayer: 'A' | 'B'`
- `activeSegmentIndex: number`
- `standbyPreparedSegmentIndex: number | null`
- `segments: ClipSegment[]`
- `disposed: boolean`

### 5.2.2 接口
- `init(surfaceA: string, surfaceB: string): Promise<void>`
- `play(): Promise<void>`
- `pause(): Promise<void>`
- `seekTo(globalMs: number, seekEpoch?: number): Promise<void>`
- `bindSegments(segments: ClipSegment[]): void`
- `release(): Promise<void>`
- `getActiveLayer(): 'A' | 'B'`

### 5.2.3 音频规则
- `isAudioMaster=false`：A/B 初始化后立即 `setVolume(0)`，后续交接保持静音。
- `isAudioMaster=true`：激活层允许出声，非激活层维持静音，交接完成后切换音量归属。

### 5.2.4 切片映射
- 输入全局毫秒，计算：
  - 目标 segment 索引
  - segment 内偏移毫秒
- 控制器内部完成 URI 装载与 seek，不向 UI 暴露切片细节。

### 5.2.5 预热与交接
- 监听 active 播放进度，距离当前 segment 结束 `<1000ms` 时：
  - standby 装载下一 segment URI
  - `prepare()` 完成后进入待切换
- 到达切点时：
  - standby `play()`
  - `activeLayer` 切换并通知观察者
  - 旧 active `reset()` 并作为新 standby

### 5.2.6 生命周期
- `release()` 必须幂等，按顺序 `stop/reset/release` 两个 player。
- 模板切换与页面销毁时必须调用。

## 5.3 PingPongTrackView.ets

### 5.3.1 结构
- `Stack` 下两个重叠 `XComponent`，分别绑定 A/B surface。
- 不使用 `Video` 组件。

### 5.3.2 切换行为
- 监听 controller 的 `activeLayer`。
- 在同帧切换 zIndex/visibility，禁止淡入淡出导致双帧重影。

## 5.4 EditorPreviewArea.ets

### 5.4.1 数据源
- 仅订阅 `EditorState`（关注 `selectedTemplateId` 与轨道数据）。

### 5.4.2 模板轨道策略
- **T1**：FRONT(AudioMaster) + REAR，上下均分。
- **T2**：FRONT(AudioMaster) + LEFT + RIGHT（对应左后/右后视角），倒品字。
- **T3**：LEFT + RIGHT（对应左后/右后视角），均 `isAudioMaster=false`。
- **T4**：LEFT_FRONT + FRONT(AudioMaster) + RIGHT_FRONT，三分屏并对左右画面做 UI 裁切。

### 5.4.3 重建机制
- 模板变更时：
  1. 暂停并释放旧 `GlobalTimelineManager` 与全部 Track
  2. 基于新模板重建 Track 列表与布局
  3. 恢复全局游标到切换前位置并完成 seek 屏障

## 6. 迁移方案

### 6.1 清理步骤
1. 从 Editor 预览区移除 `SeamlessPreviewView + SeamlessVideoPlayer` 组合。
2. 删除 `handleSeamlessSwap` 及 `playNextClip` 手工联动调用。
3. 删除旧组件源码与引用导入。

### 6.2 接入步骤
1. 增加 `media/` 下新引擎类。
2. 新增 `PingPongTrackView` 与 `EditorPreviewArea`。
3. Editor 页面改为挂载 `EditorPreviewArea`，时间控制改调 `GlobalTimelineManager`。

## 7. 风险与对策

- 多轨并发 seek 超时：增加超时保护与失败回退到 paused。
- 模板频繁切换导致资源泄漏：严格执行 destroy-before-create。
- AVPlayer 状态机竞态：所有跨 player 操作串行化到控制器内部队列。

## 8. 验收标准

- 跨切片无黑屏，单次切换可见中断 < 1 帧。
- Seek 后所有轨道在同一全局毫秒点恢复，视觉无错位。
- T1/T2/T4 仅 AudioMaster 出声，T3 全局静音。
- 切换模板 20 次无崩溃，内存无持续攀升。
- 页面退出后无悬挂 AVPlayer 实例。
