# Editor 拖拽落点反复横跳修复技术规格

## 1. 背景

上一轮已压制拖拽 seek 风暴，但用户反馈“拖拽松手后仍会反复横跳两次”。  
目标是实现严格的落点一致性：**拖到哪里，松手后就停在哪里，不发生二次回弹**。

## 2. 日志证据

从 `logs/debug.txt` 可见：

- 拖拽期间仍持续出现“拖动全局进度，秒=6/19/28/30/34/42...62”，说明拖拽 update 仍触发多次 commit seek。
- 同步出现大量 `Start seek once` 与 `All seeks complete`，且同一时窗内多组 seekDone 收敛。
- 反复出现 `HandleSeekDoneInfo end seekTo(-2147483648, 1)`，说明底层 seek 完成回调序列复杂，易触发 UI 回写抖动。

结论：当前策略是“拖拽期间节流提交 + 松手提交”，仍会制造多次落点竞争，导致最终位置抖动。

## 3. 根因分析

### 根因 A：拖拽 update 仍提交 seek，造成多落点竞争
- 现实现中拖拽 update 仍按 120ms 节流 commit。
- 松手后最终 seek 与拖拽尾段节流 seek 竞争，可能出现先到后到交错。

### 根因 B：播放器进度回调在落点收敛窗口内反向覆盖 UI
- 松手后 `onPlayheadChanged` 回推秒数可能来自前一次 seek 或播放态推进。
- UI 立即接受回推，导致“落到目标 -> 被回推偏移 -> 再回到目标”的横跳。

### 根因 C：seek 目标存在秒级取整误差
- 当前桥接层多处使用 `Math.floor(sec)`，会放大边界误差，导致落点与拖拽视觉点不一致。

## 4. 修复目标

1. 拖拽 update 完全不提交 seek，仅更新 UI。  
2. 松手时只提交一次最终 seek（单次原子提交）。  
3. 在落点收敛窗口内屏蔽旧回调对 UI 的反向覆盖。  
4. 统一毫秒精度传递，避免秒级量化误差引起回弹。  

## 5. 技术方案

## 5.1 拖拽模式升级为“End-only Commit”

调整策略：
- `onActionStart/onActionUpdate`：只更新 `dragPreviewSec` 与时间文本，不下发 `seekToken`。
- `onActionEnd`：仅一次 `commitSeek(finalSec)`。
- 删除拖拽 update 的节流 commit 分支。

收益：
- 从根源消除拖拽尾段多落点竞争。

## 5.2 落点稳定屏障（Settle Barrier）

新增状态：
- `isSettlingAfterDrag: boolean`
- `settleTargetMs: number`
- `settleWindowMs: number`（建议 220~300ms）

规则：
1. 松手提交 seek 时进入 settling 态。
2. settling 窗口内，`onPlayheadChanged` 仅在“接近目标阈值内”才接受；偏移回调直接忽略。
3. 窗口结束后恢复正常回调。

## 5.3 seek 回调去重与过期保护

在 `GlobalTimelineManager` 中继续保留 in-flight 合并，并增加：
- `lastCommittedSeekId`
- `playheadCallbackEpoch`

只允许最新 seek 的收敛回调更新全局游标；旧 seek 的回调不再回推 UI。

## 5.4 精度统一

统一从秒改为毫秒路径：
- UI 拖拽保留小数秒
- 提交时转换为毫秒并透传
- 避免 `Math.floor(second)` 在边界造成回弹

## 6. 修改范围

主要文件：
- `entry/src/main/ets/pages/Editor.ets`
- `entry/src/main/ets/media/GlobalTimelineManager.ets`
- `entry/src/main/ets/components/EditorPreviewArea.ets`（回调接收策略配合）

非目标范围：
- 模板布局
- 导出链路
- 轨道切片映射

## 7. 风险与对策

- 风险 1：只在松手提交 seek，拖拽预览画面不跟随。  
  - 对策：本次目标是落点稳定优先；若需“拖拽中实时画面”，后续引入低成本预览轨。

- 风险 2：settling 屏蔽时间过长，播放恢复延迟。  
  - 对策：窗口可配置，默认 250ms，并在 seekDone 提前结束。

- 风险 3：毫秒精度改造影响旧逻辑。  
  - 对策：边界测试覆盖 `0s`、`60s`、切片边界点。

## 8. 验收标准

1. 连续拖拽后松手，游标与画面仅落一次，无“横跳两次”。  
2. 日志中拖拽 update 不再输出高频 `拖动全局进度` commit 日志。  
3. 每次拖拽仅有一次最终 seek commit（或一次有效 barrier）。  
4. 边界落点（切片交界、末尾）不回弹。  
5. hvigor 构建通过，自动化测试无回归。  

