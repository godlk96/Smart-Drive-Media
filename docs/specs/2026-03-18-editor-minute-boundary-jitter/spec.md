# Editor 分钟边界（60s）进度条抖动修复技术规格

## 1. 问题背景

当前拖拽体验已明显改善，但在“50+秒来回拖动并跨过 60 秒边界”时，进度条与时间文本仍出现轻微抖动。  
目标：跨越分钟边界时保持单调稳定，不出现回弹或来回跳动。

## 2. 日志证据

从 `logs/debug.txt` 观察到：

- 在 50s~62s 区间仍存在多次“拖动全局进度”业务日志。
- 同一时窗内多次 `Start seek once` + `All seeks complete` 成组出现。
- 仍存在 `seekTo(-2147483648, 1)` 完成日志，说明底层在高频 seek 后出现异常边界值回调。

## 3. 根因分析

### 根因 A：拖拽期间仍有重复 commit 路径
- 代码虽做了 end-only 策略，但日志显示 update 期间仍有 commit 输出，说明存在旁路触发（如旧入口或二次触发）。
- 导致分钟边界附近重复 seek 竞争。

### 根因 B：分钟边界附近的时间格式化抖动
- UI 文本使用秒级离散显示，playhead 在 59.x/60.x 边界被回调微扰时，文本会在 `00:59` 与 `01:00` 间跳变。

### 根因 C：settling 过滤阈值与边界窗口不足
- 当前 settling 允许一定偏差，60s 切片边界时偏差更容易触发回写抖动。

### 根因 D：缺少“单向约束”与“源标记”
- 拖拽提交后，UI 未严格区分“用户落点写入”和“播放器回调回写”，两者仍可能竞争。

## 4. 修复目标

1. 拖拽 update 严格零 commit。  
2. 松手后仅一次有效 seek 提交。  
3. 跨 60s 边界进度条与时间文本单调稳定。  
4. 播放器旧回调不覆盖用户最终落点。  

## 5. 技术方案

## 5.1 强制单一提交通道

- 将所有 seek 入口统一到 `commitGlobalSeekByMs(...)`。
- 拖拽 update 路径禁止调用该方法（编译期/代码审查可见）。
- 松手时提交一次，并附带 `source='drag-end'` 与 `seekRequestId`。

## 5.2 UI 更新源标记与优先级

新增 UI playhead 写入源：
- `user_drag_preview`
- `user_drag_commit`
- `player_progress`
- `programmatic_seek`

优先级策略：
- settling 窗口内：`user_drag_commit` > `player_progress`。
- 仅当 `player_progress.requestId === latestSeekRequestId` 时允许覆盖。

## 5.3 边界抗抖（Hysteresis）

针对时间文本和滑条值，在 60s 边界引入微小滞回区（hysteresis）：
- 文本显示切换阈值：59.500ms / 60.500ms 对称窗口（可配置）。
- 当处于滞回区时保持上一稳定显示，避免来回翻转。

## 5.4 settling 强化

- settling 窗口内固定展示 `settleTargetMs`，仅接受“同 requestId + 接近阈值”回调。
- 窗口结束条件：
  1) 收到目标 seekDone 且 requestId 匹配；或  
  2) 超时（250ms~320ms）自动结束。

## 5.5 日志治理

- 拖拽 update 不再输出 `拖动全局进度` 业务日志。
- 仅在 commit 时记录：`seekRequestId/source/targetMs`，用于核对单次提交。

## 6. 修改范围

- `entry/src/main/ets/pages/Editor.ets`
- `entry/src/main/ets/media/GlobalTimelineManager.ets`
- `entry/src/main/ets/components/EditorPreviewArea.ets`（必要时）

## 7. 风险与对策

- 风险：滞回窗口过大导致显示“迟滞感”。  
  - 对策：窗口配置化，默认 500ms，A/B 调整。

- 风险：source/requestId 关联漏传。  
  - 对策：提交链路统一封装，禁止直接调用旧 seek 接口。

## 8. 验收标准

1. 50s~62s 来回拖动 20 次，进度条不出现可感知回弹。  
2. 时间文本不在 `00:59` 与 `01:00` 间抖动闪烁。  
3. 每次拖拽仅 1 次有效 seek commit 日志。  
4. hvigor 构建通过，测试无回归。  

