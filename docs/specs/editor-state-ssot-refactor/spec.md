# 多视角剪辑状态流重构技术规格（HarmonyOS NEXT）

## 1. 背景与问题定义

当前工程在“首页 -> 剪辑页 -> 导出”链路上出现了状态错位、视角串轨、导出参数污染等问题。根因不是单点 Bug，而是数据流缺少单一数据源（Single Source of Truth, SSOT）与快照隔离机制。

### 1.1 全局诊断结论

#### 诊断A：数据抽象层缺陷（视角与下标耦合）
- 视角素材取源依赖局部数组下标（如 `cameraClips[index]`、`clips[index]`），而不是“摄像头枚举 + 时间段”显式定位。
- 导出链路使用输入流顺序偏移拼接（`front/back/side` 通过偏移计算 FFmpeg 输入索引），当上游顺序变化时可能发生串轨。
- 结果：模板预览与导出输入存在“看起来一致、实际不同轨”的隐性风险。

#### 诊断B：ArkTS 响应式陷阱（多状态源 + 深层字段直改）
- 页面中同时维护 `@State state` 与多个独立 `@State` 标量（如 `playheadSec`、`timelineStartSec`、`timelineEndSec`），形成多源状态。
- 存在 `this.state.xxx = ...` 的深层字段直接改写，缺少统一不可变更新策略。
- 工程中未建立 `@Observed/@ObjectLink` 的对象级状态传播体系，子组件无法稳定消费统一模型。
- 结果：UI 展示状态与桥接内部状态可能短时脱节，调试难度高。

#### 诊断C：副作用与闭包污染（导出读取可变运行态）
- 导出入口直接读取可变 UI 状态并写回 Bridge 内部可变字段，再异步组装导出请求。
- 导出流程没有“任务级不可变快照（Deep Clone Snapshot）”，而是引用运行时对象。
- 结果：导出执行期间若状态变化，可能导致“点击时参数”与“实际执行参数”不一致。

## 2. 目标与非目标

### 2.1 目标
- 构建严格 SSOT：所有编辑交互只修改 `EditorState`。
- 用强类型领域模型替换下标语义：所有视角必须使用 `CameraPosition` 枚举。
- 让导出引擎只接收深拷贝快照：禁止直接读取页面或全局可变状态。
- 消除“页面状态 + Bridge 状态”双写，形成单向数据流。

### 2.2 非目标
- 本轮不改动 FFmpeg 算法视觉效果（布局/滤镜策略保持等价）。
- 本轮不扩展新模板（仅重构已有 T1-T4 表达与映射方式）。

## 3. 领域模型（DDD + SSOT）

### 3.1 核心枚举

```ts
enum CameraPosition {
  FRONT = 'FRONT',
  REAR = 'REAR',
  LEFT = 'LEFT',
  RIGHT = 'RIGHT',
  LEFT_FRONT = 'LEFT_FRONT',
  RIGHT_FRONT = 'RIGHT_FRONT'
}

enum TemplateId {
  T1 = 'T1',
  T2 = 'T2',
  T3 = 'T3',
  T4 = 'T4'
}
```

### 3.2 Trip（物理文件数据源）
- `Trip` 代表一次行程聚合，包含跨切片的全局时间轴。
- `Trip` 内部按 `CameraPosition` 建立显式轨道映射，禁止数组下标代表视角。
- `Trip` 的最小单位是 `ClipSegment`（含 start/end/duration/sourceUri/camera）。

建议结构：
- `tripId`
- `title/range`
- `tracks: Record<CameraPosition, CameraTrack>`
- `globalTimeline: GlobalTimelineMap`（全局秒 -> 各视角 segment 引用）

### 3.3 Template（渲染规则）
- 模板只描述“需要哪些视角 + 槽位绑定 + 导出策略”。
- 通过 `requiredCameras` 与 `slotBindings` 明确依赖，避免隐式回退。

建议结构：
- `templateId`
- `requiredCameras: CameraPosition[]`
- `optionalCameras: CameraPosition[]`
- `slotBindings: { slotId -> CameraPosition }`
- `ffmpegPolicy`（输入轨声明、filter 生成策略、降级策略）

### 3.4 EditorState（唯一状态源）
- 页面交互只操作一个对象：`EditorState`。
- 任何 UI 文本、预览槽位、导出按钮状态均由 selector 从 `EditorState` 派生。

建议结构：
- `sessionId`
- `trip: Trip`
- `selectedTemplateId: TemplateId`
- `playback: { playheadMs, rangeStartMs, rangeEndMs, speed, muted }`
- `privacy: { hideSpeed, hideGps, hideVin }`
- `brand: { watermarkEnabled }`
- `ui: { drawerExpanded, exporting, exportStatus }`

## 4. 目标架构与数据流

### 4.1 单向流
1. Page 初始化：加载 `Trip` + 默认 `Template`，生成 `EditorState`。
2. UI 交互：发出 Action（如 `SET_TEMPLATE`、`SET_RANGE`、`TOGGLE_PRIVACY`）。
3. Reducer：不可变更新 `EditorState`。
4. Selector：从 `EditorState` 计算 `PreviewSlots`、`TimelineVM`、`ExportVM`。
5. 导出：`ExportManager` 接收 `EditorState` 深拷贝快照并独立执行。

### 4.2 ArkTS 装饰器策略
- 页面根组件：`@State private editorState: EditorState`
- 子组件：通过 `@ObjectLink` 只读消费分片（必要时 `@Observed` 包装对象）
- 禁止：`this.editorState.xxx.yyy = ...` 深层直改
- 强制：通过 reducer/action 返回新对象并替换整棵 state

## 5. 文件重构方案（删除/合并/新增）

### 5.1 删除或退役
- 退役 `AppState.ets` 与 `TripModels.ets` 的重复/松散模型定义（由 `Models.ets` 统一承接）。
- 退役 `CoreBridge.ets` 中“页面状态维护职责”（保留必要的设备/媒体访问能力到 repository/service 层）。

### 5.2 合并与拆分
- 合并模型：`AppState.ets + TripModels.ets -> model/Models.ets`
- 拆分 `CoreBridge.ets`：
  - `TripRepository`（扫描、分组、读取）
  - `EditorStateStore`（状态与 reducer）
  - `ExportManager`（导出调度）

### 5.3 新增核心
- `entry/src/main/ets/model/Models.ets`
- `entry/src/main/ets/service/EditorStateStore.ets`
- `entry/src/main/ets/service/ExportManager.ets`

## 6. 生命周期与状态注入/销毁

### 6.1 页面初始化注入
- `aboutToAppear`：
  - 读取 `tripId`
  - `store = createEditorStore(tripId)` 初始化 `EditorState`
  - `this.editorState = store.getState()`

### 6.2 页面离开销毁
- `aboutToDisappear`：
  - 停止播放器与计时器
  - 取消导出订阅/回调
  - 调用 `store.dispose()` 清理 session 引用

## 7. 导出隔离设计（Snapshot First）

### 7.1 约束
- `ExportManager.startExport()` 只接收 `ExportSnapshot`。
- `ExportSnapshot` 必须来自 `deepClone(EditorState)`，并可选冻结（`Object.freeze`）防止变异。
- 导出过程中禁止读取页面 `@State` 或全局 bridge 可变字段。

### 7.2 快照内容
- Trip 轨道引用（已按模板解析）
- 模板 ID 与槽位绑定
- 范围、倍速、隐私、静音、尾标
- 输出路径与文件名策略

## 8. 迁移计划（分阶段）

### 阶段1：模型落地
- 引入 `Models.ets` 并完成旧模型到新模型的适配层。

### 阶段2：编辑页改造
- EditorPage 改为单 `EditorState` + action/reducer 模式。
- 预览/时间轴/模板抽屉全部改为 selector 数据来源。

### 阶段3：导出链路切换
- 引入 `ExportManager`，移除 `CoreBridge.startExport` 的状态写回逻辑。
- 导出前生成深拷贝快照并记录快照 ID 用于排障。

### 阶段4：清理与回归
- 移除冗余 bridge 状态字段。
- 执行回归：模板一致性、跨片段时间轴、导出参数一致性。

## 9. 验收标准

- 同一模板下：预览槽位与导出轨道绑定 100% 一致。
- 任意时刻点击导出：导出参数与点击瞬间 UI 配置一致。
- 页面中仅存在一个可写业务状态源 `EditorState`。
- 不再出现基于数组下标推断视角的业务逻辑。
