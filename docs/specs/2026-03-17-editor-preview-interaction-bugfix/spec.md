# Editor 预览交互故障修复技术规格

## 1. 背景

在完成“全局时钟屏障 + 全轨乒乓双缓冲”重构后，播放剪辑器已恢复音画，但出现三类交互级故障：

1. 默认进入 T2 后点击播放，短时间内自动暂停，后续播放/暂停失效。  
2. 在 1 的基础上切模板后可播放，但无法暂停。  
3. 在 2 的基础上再次切模板，模板不再切换生效。

本规格聚焦“播放状态机 + 模板切换状态机 + 组件重建时序”的一致性修复。

## 2. 日志证据与问题定位

### 2.1 日志证据
- 日志显示 `EditorPreviewArea rebuild done` 多次出现，且模板切换时重复触发。
- 日志显示播放链路中存在频繁 pause 触发。
- 旧链路遗留的 AVPlayer 错误（audio interrupt）已在前一轮修复，此轮不作为主要根因。

### 2.2 根因假设（需按此实施验证）

#### 根因 A：轨道回调被覆盖，导致 UI 与调度状态分裂
- `GlobalTimelineManager.registerTrack()` 使用 `setCallbacks(...)`，会覆盖 `PingPongTrackView` 设置的 layer-change 回调，造成控制器事件消费者互相覆盖。
- 结果：播放态、交接态、UI 渲染态不一致，触发异常状态流。

#### 根因 B：任意单轨 ended 直接上抛为全局 ended
- 当前每个 Track `completed` 都会上报 `onEnded`，但全局结束应为“所有轨道到达全局终点”。
- 结果：某个轨道提前结束即可把全局状态打回暂停，表现为“刚播放就停”。

#### 根因 C：EditorState 高频变更触发不必要重建
- `EditorPreviewArea` 监听 `editorState` 与 `tripSnapshot` 同一 Watch 入口，播放期间 `playhead` 更新可能引发重建链路。
- 结果：播放/暂停命令与重建并发，出现“按钮点击无效”“模板切换后状态锁死”。

#### 根因 D：模板切换触发条件过宽
- 模板切换依赖整个状态对象变化，而非仅 template/trip 关键字段变化。
- 结果：状态噪声触发 rebuild，破坏模板切换可重复性。

## 3. 修复目标

1. 播放按钮行为可重复、可逆：`play -> pause -> play` 稳定有效。  
2. 模板切换可重复：连续切换 T1/T2/T3/T4 均生效。  
3. 仅在必要条件下重建预览引擎：禁止播放期间因游标刷新触发 rebuild。  
4. 全局 ended 语义正确：仅在全局播放真正结束时触发。

## 4. 技术方案

## 4.1 回调总线拆分（避免互相覆盖）

在 `PingPongTrackController` 中拆分回调注册接口：
- `setLayerChangedCallback(...)` 仅供视图层使用。
- `setProgressCallback(...)`、`setEndedCallback(...)` 仅供 `GlobalTimelineManager` 使用。
- 保证 manager 注册进度/结束回调时不会覆盖 UI 层回调。

验收点：
- layer 切换事件持续上报；
- manager 进度同步正常；
- 两者互不影响。

## 4.2 全局 ended 屏障

在 `GlobalTimelineManager` 引入全局结束判定：
- 维护 `trackEndFlags: Map<trackId, boolean>`；
- 仅当 `playing` 状态下，且所有已注册轨道都为 ended，才触发全局 `onEnded`；
- 在 `seek/play/template rebuild` 时重置 ended flags。

验收点：
- 单轨 completed 不会立即全局停止；
- 到达全局尾部才触发结束回调。

## 4.3 重建触发最小化

`EditorPreviewArea` 内部重建条件改为“关键键变更”：
- `tripId`
- `activeTemplateId`
- `tripSnapshot` 数据版本（如 clip 数量/首尾时间戳）

播放游标、速度文案、静音状态不触发 rebuild，只触发调度命令：
- seek -> `manager.seek(...)`
- speed -> `manager.setPlaybackRate(...)`
- muted -> `manager.setMuted(...)`
- play/pause -> `manager.play()/pause()`

验收点：
- 连续播放期间无 rebuild 日志刷屏；
- 点击暂停立即生效且不被重建覆盖。

## 4.4 模板切换事务化

将模板切换处理为原子序列：
1. `pause`
2. 记录切换前是否播放
3. 更新模板状态
4. 触发单次 rebuild
5. seek 到目标游标（默认保留当前游标或按产品策略归零）
6. 若切前为播放态，恢复 `play`

并在切换期间设置 `isSwitchingTemplate` 防重入。

验收点：
- 连续快速切模板稳定；
- 不会出现“第二次后模板不再变化”。

## 5. 修改范围

### 5.1 主要文件
- `entry/src/main/ets/media/PingPongTrackController.ets`
- `entry/src/main/ets/media/GlobalTimelineManager.ets`
- `entry/src/main/ets/components/EditorPreviewArea.ets`
- `entry/src/main/ets/pages/Editor.ets`

### 5.2 非目标范围
- 导出链路
- FFmpeg 策略
- 模板定义数据源

## 6. 风险与回退

### 风险
- 回调拆分后遗漏绑定，可能导致进度条不刷新。
- ended 屏障逻辑错误，可能导致播到尾部不结束。

### 回退
- 保留旧分支可回滚；
- 以 feature flag（预览引擎开关）快速切换到旧版预览实现。

## 7. 验收标准

1. 默认进入 T2：首次播放连续稳定，不会秒停。  
2. 同一模板下：连续 10 次 play/pause 均生效。  
3. 连续切换模板（T2->T1->T4->T3->T2）均正确重排并可控播放。  
4. 日志中播放期间 `rebuild done` 仅在模板/行程切换时出现。  
5. hvigor 构建通过，现有自动化测试不回归。

