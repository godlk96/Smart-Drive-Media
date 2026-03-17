# Editor 拖拽进度条死循环修复技术规格

## 1. 背景

当前 Editor 预览已恢复基础播放，但拖拽时间轴时出现“疑似死循环”现象：UI 卡顿、日志刷屏、底层 seek 请求暴涨，影响可用性与稳定性。

## 2. 日志证据

基于 `logs/debug.txt` 可见以下特征：

- 拖拽期间连续输出“拖动全局进度，秒=25...34”，极短时间内多次触发全局 seek。
- AVPlayer 层频繁出现 `Start seek once` 与 `All seeks complete`，说明请求风暴存在。
- 出现 `LIBUV loop ... active reqs:100+`，说明异步任务堆积明显。
- 同时出现 `seekTo(-2147483648, 1)` 结束日志，提示 seek 参数/时序在高频情况下进入异常边界。

## 3. 根因分析

### 根因 A：拖拽事件全量直通 seek 屏障
- 时间轴 `PanGesture.onActionUpdate` 每个像素级更新都会调用 `syncGlobalPlayhead(..., true)`。
- `syncGlobalPlayhead` 每次都递增 `seekToken`，触发 `EditorPreviewArea -> manager.seek()`。
- 结果：单次拖拽产生大量并发/排队 seek（seek storm）。

### 根因 B：缺少拖拽状态机（Drag Session）
- 当前没有“拖拽中仅更新 UI、拖拽结束再提交一次 seek”的分层机制。
- 结果：UI 反馈与播放器同步耦合，系统频繁进入 seek barrier，易造成假死。

### 根因 C：缺少 seek 合并与过期请求丢弃策略
- 管理器虽有 `seekEpoch`，但 UI 层仍持续制造新请求。
- 结果：老请求尚未完成时，新请求不断进入，形成高压循环。

## 4. 目标

1. 拖拽过程流畅，不卡顿、不刷爆日志。  
2. 拖拽中只刷新 UI，不执行高频全轨 seek。  
3. 拖拽结束后仅提交最终目标 seek（或低频节流 seek）。  
4. 不影响点击跳转、播放中自动推进、模板切换等已有行为。  

## 5. 技术方案

## 5.1 引入 Drag Session 状态机（Editor 层）

新增状态：
- `isTimelineDragging: boolean`
- `dragPreviewSec: number`
- `lastSeekCommitAtMs: number`

行为规则：
- `onActionStart`：进入拖拽态，记录初始点，仅更新 UI 游标（不触发 seekToken）。
- `onActionUpdate`：更新 `dragPreviewSec` 与时间文本；按节流窗口（例如 120ms）允许一次“预览 seek”。
- `onActionEnd`：提交最终 seek 一次，退出拖拽态。

## 5.2 seek 提交分层

将 `syncGlobalPlayhead` 拆分为：
- `previewPlayheadOnly(second)`：只更新 UI 状态，不下发 AV seek。
- `commitGlobalSeek(second, source)`：真正下发 `bridge.seekGlobalPlayhead + seekToken`。

其中：
- 拖拽 update 使用 `previewPlayheadOnly`，可选节流 commit；
- 拖拽 end 必须 `commitGlobalSeek` 一次；
- 点击跳转仍直接 `commitGlobalSeek`。

## 5.3 Manager 层 seek 合并保护

在 `GlobalTimelineManager` 增加：
- `pendingSeekMs`（最后一次目标）
- `seekingInFlight` 标志

策略：
- 若正在 seek，新的 seek 仅覆盖 `pendingSeekMs`；
- 当前 seek 完成后仅执行最后一个 pending；
- 保证任意时刻仅有一个 seek barrier 执行。

## 5.4 日志降噪与诊断标记

新增日志分级：
- `drag-preview`（仅 UI 更新，不写高频业务日志）
- `seek-commit`（真正触发 AV seek 时打点）

验收中以“commit 频率”作为关键观察指标，避免误判。

## 6. 修改范围

主要文件：
- `entry/src/main/ets/pages/Editor.ets`
- `entry/src/main/ets/components/EditorPreviewArea.ets`（仅同步策略配合）
- `entry/src/main/ets/media/GlobalTimelineManager.ets`

非目标范围：
- 导出链路
- 模板布局逻辑
- 轨道切片映射逻辑

## 7. 风险与应对

- 风险 1：拖拽结束未提交最终 seek，导致画面停留旧位置。  
  - 对策：`onActionEnd` 强制 commit，添加断言日志。

- 风险 2：节流窗口过大，拖拽实时感下降。  
  - 对策：窗口可配置（80~160ms），先以 120ms 落地。

- 风险 3：seek 合并逻辑引入播放态抖动。  
  - 对策：保持 `wasPlaying` 恢复策略不变，仅合并 seek 请求。

## 8. 验收标准

1. 连续拖拽 5 秒，日志不再出现 `active reqs:100+` 异常堆积。  
2. 拖拽期间 UI 游标平滑，未出现明显卡死。  
3. 松手后画面稳定落在最终位置，音画同步恢复正常。  
4. `Start seek once` 次数显著下降（与拖拽 update 次数不再 1:1）。  
5. hvigor 构建通过，自动化测试无回归。  

