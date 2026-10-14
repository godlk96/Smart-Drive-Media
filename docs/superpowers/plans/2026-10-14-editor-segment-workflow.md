# 剪辑页片段剪辑与手柄调整工作流实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 重构剪辑页片段工作流，实现“默认全片可导出、首次剪辑高光圈选、双向手柄硬阻挡微调、空白区间态、直接物理删除以及删光干净恢复全片”，同时确保多机位播放器底层寻道（Seek）稳定不卡死。

**Architecture:** 
1. **纯模型层 (`SegmentModel.ets`)**：新增双向手柄边界硬阻挡计算、物理删除、全片状态标识与 10 秒最小段长（`MIN_SEGMENT_SEC = 10`）约束，采用无依赖纯函数并以 TDD 严格覆盖；
2. **状态机与桥接层 (`CoreBridge.ets` / `EditorViewModel.ets`)**：统一维护全片态 `isRawFull` 与空白区态（`selectedSegmentId = -1`），删除片段时保持播放头不动（零跳跃），删光无缝重置全片；
3. **视图层 (`SegmentTrack.ets` / `SegmentParamRow.ets` / `Editor.ets`)**：为选中段提供水平 PanGesture 拖动手柄，拖动过程**严格禁止向播放器发送 Seek 请求**（仅 60Hz 刷新本地时间气泡），松手时一次性结算边界；参数行完美支持全片态、片段编辑态、空白区间态的三态切换。

**Tech Stack:** HarmonyOS ArkTS, TypeScript, Node.js (offline test runner)

**Spec:** `docs/superpowers/specs/2026-10-14-editor-segment-workflow-redesign.md`

## Global Constraints

- 单段最短时长必须为 10 秒：`MIN_SEGMENT_SEC = 10`
- 首次与空档剪辑默认窗口：`DEFAULT_CLIP_WINDOW_SEC = 15`
- 全局最多 3 个片段：`MAX_SEGMENTS = 3`
- 片段拆分（一分为二）门槛：原片段时长必须 $\ge 20$ 秒，且落刀点距两端均 $\ge 10$ 秒
- 手柄拖拽过程中**绝对禁止向播放器派发 seek 请求**，仅更新手柄与气泡 UI
- 删除操作为物理删除（从数组移除，无置灰无删除线），删光所有片段自动恢复为覆盖 60s 的 `RAW_FULL` 状态，播放头保持当前秒数不动
- 纯函数模块禁止引入任何 `@ohos.*` 或 `@kit.*` 依赖，确保离线测试（`tools/offline-test.mjs`）100% 绿灯

## Review Focus

1. **拖动手柄边界越界与倒置**：左手柄向右拉不能越过 $E - 10$；右手柄向左拉不能越过 $S + 10$；遇到相邻片段或 0/总长时硬阻挡，绝对不重叠、不挤压。
2. **播放头停留在空白区间（Gap）时的状态隔离**：`selectedSegmentId` 为 `-1`，参数行进入空白态，隐藏倍速/静音/删除，仅留剪刀；点击剪刀在当前落刀点插入新片段。
3. **全片状态与首次落刀切换**：进入页面默认 `isRawFull = true`，参数行显示“全片 · 60s”，导出可用；首次落刀后变为 `isRawFull = false` 且只保留高光选区。
4. **多段全删光恢复原片**：删除最后一个片段时，平滑恢复为初始全片模式，倍速/静音恢复默认，导出依然可用，弹窗提示“已恢复为完整视频”。
5. **手柄拖拽对播放器的零干扰**：拖拽手柄过程中播放器不卡顿、不重置、不丢帧。

---

## Task 1: 纯模型层 (`SegmentModel.ets`) 双向手柄与工作流纯函数 (TDD)

**Files:**
- Modify: `entry/src/main/ets/model/SegmentModel.ets`
- Modify: `entry/src/ohosTest/ets/test/SegmentModelCases.ets`
- Test: `tools/offline-test.mjs`

- [ ] **Step 1: 编写手柄调节与新工作流的失败测试用例**
  - 在 `entry/src/ohosTest/ets/test/SegmentModelCases.ets` 中增加测试用例：
    - `MIN_SEGMENT_SEC 变为 10 秒`
    - `adjustSegmentStart：向左不越过前一段终点，向右不越过 endSec - 10`
    - `adjustSegmentEnd：向左不越过 startSec + 10，向右不越过下一段起点`
    - `removeSegment：物理移除片段，保持数组有序`
    - `首次剪辑生成 15 秒高光选区（不满 15 秒延伸至片尾且保底 10 秒）`
    - `片段内落刀一分为二：>=20 秒且两端均 >=10 秒才允许切分，否则拒绝`
    - `空档落刀：需 >=10 秒空间，生成默认 15 秒片段`
- [ ] **Step 2: 运行离线测试确认测试失败**
  - 执行 `& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" tools/offline-test.mjs`，验证新用例失败。
- [ ] **Step 3: 在 `SegmentModel.ets` 中实现核心算法**
  - 修改 `MIN_SEGMENT_SEC = 10`，添加 `DEFAULT_CLIP_WINDOW_SEC = 15`。
  - 实现 `adjustSegmentStart(segments, id, targetSec, totalDurationSec): Array<Segment>`。
  - 实现 `adjustSegmentEnd(segments, id, targetSec, totalDurationSec): Array<Segment>`。
  - 实现 `removeSegment(segments, id): Array<Segment>`。
  - 重构 `canSplitAt` / `splitSegmentAt`，区分全片模式与多片段模式（支持一分为二与空档插入）。
- [ ] **Step 4: 运行离线测试确认全部通过**
  - 执行 `& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" tools/offline-test.mjs`，确保全部测试绿灯。
- [ ] **Step 5: 提交更改**
  - `git add entry/src/main/ets/model/SegmentModel.ets entry/src/ohosTest/ets/test/SegmentModelCases.ets`
  - `git commit -m "feat(model): implement segment boundary adjustment and new workflow algorithms"`

---

## Task 2: 状态机与桥接层 (`CoreBridge.ets` & `EditorViewModel.ets`) 全片与空白态重构

**Files:**
- Modify: `entry/src/main/ets/model/AppState.ets`
- Modify: `entry/src/main/ets/bridge/CoreBridge.ets`
- Modify: `entry/src/main/ets/viewmodel/EditorViewModel.ets`

- [ ] **Step 1: 扩展状态模型**
  - 在 `EditorStateModel` 中添加 `isRawFull: boolean = true` 字段。
- [ ] **Step 2: 在 `CoreBridge.ets` 中重构全片模式与首次落刀**
  - 初始化时 `isRawFull = true`，`segments = createFullSegment(tripDurationSec)`。
  - `splitAtPlayhead()`:
    - 若 `isRawFull`：切为 `[playheadSec, min(total, playheadSec + 15)]`，设置 `isRawFull = false`，选中该片段（id=0）。
    - 若非 `isRawFull`：调用新 `splitSegmentAt`，成功后选中新生成的后半段。
- [ ] **Step 3: 在 `CoreBridge.ets` 中实现物理删除与空白区状态联动**
  - `deleteSegment(id)`：
    - 调用 `removeSegment` 物理移除非当前段；
    - 播放头保持原位不动（不修改 `playheadMs`）；
    - 若数组变为空：调用 `createFullSegment` 恢复原片，设置 `isRawFull = true`，倍速设为 1.0X，静音设为 false，`selectedSegmentId = 0`；
    - 若数组非空：若播放头在某个活段内，选中该段；若播放头在空白区，设置 `selectedSegmentId = -1`。
- [ ] **Step 4: 在 `CoreBridge.ets` 中支持手柄拖动边界更新**
  - 新增 `adjustSegmentBoundary(id: number, edge: 'start' | 'end', sec: number)`，调用 `adjustSegmentStart` 或 `adjustSegmentEnd`，返回更新后的 state。
- [ ] **Step 5: 在 `EditorViewModel.ets` 中透传方法**
  - 透传 `deleteSegment(id)`、`adjustSegmentBoundary(id, edge, sec)` 以及状态计算方法。
- [ ] **Step 6: 提交更改**
  - `git add entry/src/main/ets/model/AppState.ets entry/src/main/ets/bridge/CoreBridge.ets entry/src/main/ets/viewmodel/EditorViewModel.ets`
  - `git commit -m "feat(bridge): implement raw-full mode, physical deletion, and gap state management"`

---

## Task 3: 视图层 `SegmentParamRow.ets` 三态支持与 `SegmentTrack.ets` 双向手柄拖拽（零 Seek）

**Files:**
- Modify: `entry/src/main/ets/components/SegmentParamRow.ets`
- Modify: `entry/src/main/ets/components/SegmentTrack.ets`

- [ ] **Step 1: 重构 `SegmentParamRow.ets` 支持全片态、片段编辑态、空白态**
  - 增加 `@Prop isRawFull: boolean = false`。
  - 增加 `@Prop isGap: boolean = false`（当 `selectedSegmentId === -1` 时为 true）。
  - UI 逻辑：
    - **全片态** (`isRawFull`): 显示 `全片` · `${duration}s` · 倍速微胶囊 · 声音图标 · 剪辑微胶囊；**隐藏删除按钮**。
    - **空白态** (`isGap`): 显示 `空白区间`；**隐藏倍速、声音、删除微胶囊**；仅显示剪辑微胶囊。
    - **片段编辑态** (默认): 显示 `片段 N` · `${duration}s` · 倍速 · 声音 · 剪刀 · 删除【✕】微胶囊。
- [ ] **Step 2: 重构 `SegmentTrack.ets` 双向手柄与手势**
  - 增加对 `isRawFull` 的判断：若为全片态，片段块不渲染手柄。
  - 仅给当前选中的片段（`isSelected && !isRawFull`）渲染左右两个拉动手柄。
  - 手柄样式保持琥珀竖条 + 三颗小圆点。
  - 左手柄绑定 `PanGesture`:
    - `onActionUpdate(event)`: 仅更新本地拖动偏移量与时间气泡浮层（60Hz 响应），**严禁触发任何 seek 或外部回调**！
    - `onActionEnd(event)`: 计算最终秒数，调用 `onAdjustBoundary?.(segment.id, 'start', newSec)`。
  - 右手柄绑定 `PanGesture`:
    - `onActionUpdate(event)`: 仅更新本地右侧偏移量与时间气泡，**严禁触发 seek**！
    - `onActionEnd(event)`: 计算最终秒数，调用 `onAdjustBoundary?.(segment.id, 'end', newSec)`。
- [ ] **Step 3: 提交更改**
  - `git add entry/src/main/ets/components/SegmentParamRow.ets entry/src/main/ets/components/SegmentTrack.ets`
  - `git commit -m "feat(ui): add three-state parameter row and zero-seek handle gesture dragging"`

---

## Task 4: 页面集成与全流程联调 (`Editor.ets`)

**Files:**
- Modify: `entry/src/main/ets/pages/Editor.ets`

- [ ] **Step 1: 页面状态集成**
  - 接入 `onAdjustBoundary`：调用 `viewModel.adjustSegmentBoundary(id, edge, sec)` 并 `applyState`，标记 `hasUnsavedChanges`。
  - 接入 `onDeleteSegment`：点击参数行【✕】时调用 `viewModel.deleteSegment(id)`。若删光切回全片态，弹出 Toast：“已恢复为完整视频”。
  - 进度条拖动与播放推进联动：检测当前秒数 `sec`，若落入空白区（`segmentIndexAtSec == -1`），且当前非 `isRawFull`，设置 `state.selectedSegmentId = -1`。
- [ ] **Step 2: 导出快照校验**
  - 检查 `buildExportSnapshot`：
    - 在 `RAW_FULL` 模式下，导出整段 `0 ~ totalDurationSec`。
    - 在 `SEGMENTED` 模式下，仅导出当前存在的有效片段。
- [ ] **Step 3: 运行全量离线测试验证纯函数**
  - 执行 `& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" tools/offline-test.mjs`，确保全部测试通过。
- [ ] **Step 4: 语法与类型检查**
  - 检查代码语法，确保无类型报错。
- [ ] **Step 5: 提交最终集成代码**
  - `git add entry/src/main/ets/pages/Editor.ets`
  - `git commit -m "feat(editor): integrate new segment clipping, handle adjustment, and reset workflow"`
