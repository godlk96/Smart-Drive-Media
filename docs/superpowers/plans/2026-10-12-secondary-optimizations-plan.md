# 次级优化与工程严谨性改造实施计划 (Secondary Optimizations Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 基于交叉审计报告，逐项落地次级优化点：倍速真实对齐、播放器超时保护、消除虚假进度条、日志系统防积压、消除 NAPI CSV 协议、DVR 连续行程智能聚类，使工程达到严谨、无虚假逻辑、无隐性卡死的生产级状态。

**Architecture:**
1. 媒体播放层严格遵从 HarmonyOS `@ohos.multimedia.media` 的 `PlaybackSpeed` 原生能力上限（最高 2.0X），界面与引擎完全对齐；
2. 播放器管线对异步状态跃迁增加超时保护（3000ms 兜底）；
3. 导出进度由无根据的 250ms 定时器自增转为确定性阶段感知（素材准备 -> 滤镜渲染 -> 写入相册）；
4. 日志系统去除 `console` 与 `hilog` 的双重打印，文件落盘做轻量缓冲；
5. 导出请求去除 `@`/`,` CSV 字符串拼解，在 ArkTS 侧完成结构化解析；
6. 连续行车记录仪切片根据 120s 时间窗口聚类为连续完整行程。

**Tech Stack:** HarmonyOS NEXT / API 23-26, ArkTS, C++ NAPI, Node.js 纯逻辑自动化回归套件。

---

### Task 1: 播放器倍速选项与系统对齐（消除虚假承诺）

**Files:**
- Modify: `entry/src/main/ets/constants/AppConstants.ets`
- Modify: `entry/src/main/ets/bridge/CoreBridge.ets`
- Modify: `entry/src/main/ets/media/GlobalTimelineManager.ets`
- Modify: `entry/src/main/ets/media/PingPongTrackController.ets`
- Modify: `entry/src/main/ets/viewmodel/EditorViewModel.ets`
- Modify: `test/timelineAndState.test.js`

**Step 1: 编写测试断言倍速选项合法性**
- [x] 在 `test/timelineAndState.test.js` 中扩充针对倍速选项列表的断言，确保选项列表与 AVPlayer 原生枚举（最高 2.0X）完全一致。

**Step 2: 统一收敛常量与倍速映射**
- [x] 修改 `AppConstants.ets` 与 `CoreBridge.ets` 中的 `EDITOR_SPEEDS`：由 `['1.0X', '1.5X', '2.0X', '3.0X', '4.0X']` 改为 `['1.0X', '1.25X', '1.5X', '2.0X']`；
- [x] 修改 `PingPongTrackController.ets` 中的 `applyPlaybackRate`，与 `media.PlaybackSpeed` 严格映射（0.75X、1.0X、1.25X、1.5X、2.0X）；
- [x] 确保 `EditorViewModel.getPlaybackRate` 与 UI 标签 100% 对齐。

**Step 3: 运行测试并提交**
- [x] 运行测试验证通过；
- [x] Commit 变更。

---

### Task 2: 播放器 waitPrepared 增加 3000ms 超时容错

**Files:**
- Modify: `entry/src/main/ets/media/PingPongTrackController.ets`
- Create: `test/playerPreparedTimeout.test.js`

**Step 1: 编写超时保护单元测试**
- [x] 在 `test/playerPreparedTimeout.test.js` 中模拟 `waitPrepared` 在未收到状态时的 3000ms 超时行为。

**Step 2: 在 PingPongTrackController.ets 中增加超时防卡死**
- [x] 在 `waitPrepared(slot: PlayerSlot)` 中增加 `setTimeout(3000)`，超时自动 resolve 或标记错误，避免坏素材挂起整个播放器队列；
- [x] 在 `releaseSlot` 时清理超时定时器。

**Step 3: 运行测试并提交**
- [x] 运行测试验证通过；
- [x] Commit 变更。

---

### Task 3: 消除伪造导出进度条（改为确定性真实阶段汇报）

**Files:**
- Modify: `entry/src/main/ets/service/ExportNativeService.ets`
- Modify: `entry/src/main/ets/ExportManager.ets`
- Modify: `test/exportPipelineContract.test.js`

**Step 1: 编写阶段化进度契约测试**
- [x] 在 `test/exportPipelineContract.test.js` 中增加阶段化进度递进与终态通知测试。

**Step 2: 移除 smoothTimer 定时器并规范阶段进度**
- [x] 从 `ExportNativeService.ets` 中物理删除 `smoothTimer` / `startSmoothProgress` / `stopSmoothProgress`；
- [x] 导出过程按真实处理阶段向外通知：
  - 阶段 1: `素材准备与切片物化 (10%)`
  - 阶段 2: `Native 滤镜渲染与编码合成 (35%)`
  - 阶段 3: `保存至系统相册 (85% -> 100%)`。

**Step 3: 运行测试并提交**
- [x] 运行测试验证通过；
- [x] Commit 变更。

---

### Task 4: 日志系统精简（消除重复双写与串行磁盘 IO 链）

**Files:**
- Modify: `entry/src/main/ets/utils/Logger.ets`

**Step 1: 精简重复输出与优化文件落盘**
- [x] 在 `Logger.ets` 中删除 `console.info` 重复打印（仅保留标准的 `hilog.info`，消除 IDE 日志双份刷屏）；
- [x] 为文件落盘引入轻量内存批量缓冲（Buffer Array），每 1 秒或满 20 条集中写入一次，避免每次 log 都触发一次 `fs.open/write/close` 导致的无界 Promise 链与磁盘磨损。

**Step 2: 验证并提交**
- [x] 检查代码并跑通全量测试；
- [x] Commit 变更。

---

### Task 5: 消除跨 NAPI 的 CSV 字符串拼接协议

**Files:**
- Modify: `entry/src/main/ets/service/ExportService.ets`
- Modify: `entry/src/main/cpp/napi_init.cpp`
- Modify: `entry/src/main/cpp/types/libsmartdrive_exporter/Index.d.ts`
- Modify: `test/exportPipelineContract.test.js`

**Step 1: 重构素材分类直接在 ArkTS 侧完成**
- [x] 消除 `ExportService.ets` 中的 `${item.camera}@${item.timestamp}@${item.uri}` 拼接逻辑；
- [x] `ExportService.ets` 直接利用已有的 `clips` 数组做 `Front`/`Back` 机位过滤与去重，消除对 C++ `buildComposeRequest` 的多余脆弱跨语言文本转换；
- [x] 保持 C++ 侧兼容或直接精简。

**Step 2: 运行测试并提交**
- [x] 运行测试验证通过；
- [x] Commit 变更。

---

### Task 6: 行程连续时间窗口智能聚类

**Files:**
- Modify: `entry/src/main/ets/bridge/CoreBridge.ets`
- Create: `test/tripAggregationWindow.test.js`

**Step 1: 编写多段 DVR 连续时间窗口聚类测试**
- [x] 在 `test/tripAggregationWindow.test.js` 中测试：相距 <= 120 秒的连续片段被自动合并到同一条行程；相距 > 120 秒的片段被拆分成不同的行程。

**Step 2: 在 CoreBridge.ets 中实现时间窗口聚类**
- [x] 改造 `buildTripsFromMetas`，以 120 秒为连续行程聚合窗口，消除 60 秒片段碎成单张卡片的问题。

**Step 3: 运行测试并提交**
- [x] 运行测试验证通过；
- [x] Commit 变更。

---

### Task 7: 全套自动化测试验证与端到端全链路验收

**Step 1: 全量运行测试套件**
- [x] 运行：`npm test`
- [x] 确保全量测试 100% 通过（26 项用例全部 PASS）。

**Step 2: 审查 git 状态与分支合并**
- [x] 检查 `git status` 无遗留未提交文件；
- [x] 合并并向用户报告结果。
