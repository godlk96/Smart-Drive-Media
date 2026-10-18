# 剪单「我的剪辑」实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 导出成功后给用户明确回执；把每次导出落成一条「作品记录」，首页新增「我的剪辑」Tab 展示历史作品，点进去按记录里的参数在剪辑页**现场还原**，再导出时可**就地覆写**同一件作品。

**Architecture:** 三层分离 —— ① **记录层**（`pref_edit_records` 里的 `EditRecord`，App 完全自主）；② **成片层**（相册里的 mp4，受系统受控权限约束，只能就地覆写不能删）；③ **素材层**（`CoreBridge.trips` 里的 `TripSnapshot`，由扫描现场填充）。还原 = 记录提供**参数**（权威）+ 现场提供**素材**（尽力），两者用 `(tripTitle, tripStartTs)` 交叉校验，对不上就明确报错。记录由**导出流程**在相册写入成功后立即落盘，不经页面。

**Tech Stack:** HarmonyOS ArkTS (API 26, stage model) · ArkUI 声明式 UI · `@ohos.data.preferences` 持久化 · hypium（真机）+ `tools/offline-test.mjs`（离线纯函数）+ `tools/typecheck-player.mjs`（语法类型检查）

**Spec:** `docs/superpowers/specs/2026-10-18-my-edits-history-design.md`（rev.2，已批准）

**Global Constraints:**

- **ArkTS 严格模式**：不用 `any`、不用无类型对象字面量、所有形参与返回值显式标注类型。类实例字段必须有初值。
- **纯函数模块**（可被 `tools/offline-test.mjs` 跑的）**禁止**导入 `@ohos.*` / `@kit.*`，只能相对导入。离线测试遇到裸导入会**直接抛错**，不静默跳过。
- **新增离线用例文件**必须**同时**登记在两处：`tools/offline-test.mjs` 的 `SUITES`（:39-45）与 `entry/src/ohosTest/ets/test/List.test.ets`。
- **新增模块**必须手动加进 `tools/typecheck-player.mjs` 对应 group 的 `deps` —— 该脚本的 `GROUPS` **不会**自动跟随 import。
- **UI 文件禁止硬编码颜色**：一律 `$r('app.color.<token>')`。`tools/offline-test.mjs` 的 `checkNoLegacyColors` 会扫描 `UI_FILES` 白名单，新 UI 文件要加进该列表。
- **`fs.open(albumUri, ...)` 写相册必须带 `fs.OpenMode.TRUNC`**（见 `entry/src/main/ets/service/ExportManager.ets:291` 的现状 —— 今天没有 TRUNC，这是覆盖方案最容易踩的坑）。
- **绝不**记录未导出的中间态；**绝不**在覆盖时留下两份成片；**绝不**静默用错素材；**绝不**自动删除用户记录。
- 验证命令（两个都要绿）：
  - `& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" tools/offline-test.mjs`
  - `& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" tools/typecheck-player.mjs <group>`（group ∈ `player|bridge|export|home`）
- 提交信息沿用仓库风格：`feat(<scope>): <中文描述>` / `test(<scope>): <中文描述>`。

**Review Focus（复核者重点看）:**

1. `ExportManager` 覆盖分支**是否真的跳过** `showAssetsCreationDialog`，以及 `TRUNC` 是否只加在覆盖分支、没污染新建分支。
2. 还原路径**是否在身份对不上时明确报错**，有没有偷偷回退成「白纸打开」。
3. 记录落盘**是否在导出流程内**（不是等页面事件），以及失败时会不会留下「相册有片、列表没记录」的空档。
4. `PreferencesService` 打开失败时**是否显式上报**，而不是静默回退内存 Map（那等于丢数据）。
5. 孤儿检测**是否权限感知**（无读权限时判「未知」而不是全判孤儿），以及**是否零写盘**。

---

## Task 1: `EditRecord` 纯模型与历史列表函数

**Files:**
- Create: `entry/src/main/ets/model/EditRecord.ets`
- Create: `entry/src/ohosTest/ets/test/EditHistoryCases.ets`
- Create: `entry/src/ohosTest/ets/test/EditHistory.test.ets`
- Modify: `entry/src/ohosTest/ets/test/List.test.ets`
- Modify: `tools/offline-test.mjs:39-45`（`SUITES` 加一行）

**Interfaces:**
- Consumes: 无（本文件是纯模块，只依赖内置 `Date` / `JSON`）
- Produces（后续 Task 3/4/7/8/9 依赖）:
  - `export const EDIT_RECORD_SCHEMA_VERSION: number = 1`
  - `export class EditRecord { id, tripId, tripTitle, tripStartTs, tripEndTs, albumUri, fileName, exportedAt, durationMs, segmentCount, templateId, snapshot, coverPath, schemaVersion }`（字段与类型完全照 spec 4.1，全部带初值）
  - `export function makeRecordId(nowMs: number, salt: number): string` → `rec_<ms>_<000-999>`
  - `export function parseEditRecords(raw: string): Array<EditRecord>` —— 坏数据返回 `[]`，逐条校验，丢弃无 `id` 的项，返回按导出时间倒序
  - `export function serializeEditRecords(records: Array<EditRecord>): string`
  - `export function sortRecordsNewestFirst(records: Array<EditRecord>): Array<EditRecord>`
  - `export function findRecordById(records: Array<EditRecord>, id: string): EditRecord | undefined`
  - `export function recordsForTrip(records: Array<EditRecord>, tripId: string): Array<EditRecord>`
  - `export function findLatestRecordForTrip(records: Array<EditRecord>, tripId: string): EditRecord | undefined`
  - `export function upsertRecord(records: Array<EditRecord>, record: EditRecord): Array<EditRecord>` —— 同 `id` 原地替换后重排，否则追加
  - `export function removeRecords(records: Array<EditRecord>, ids: Array<string>): Array<EditRecord>`
  - `export function recordMatchesTrip(record: EditRecord, tripTitle: string, tripStartTs: number): boolean`
  - `export function formatExportTime(exportedAt: number): string` → `10月18日 21:04 导出`
  - `export function formatClockDuration(durationMs: number): string` → `00:32` / `1:02:03`
  - `export function formatRecordSummary(segmentCount: number, durationMs: number): string` → `2 段 · 00:32`

- [x] **Step 1: 先写失败用例**

创建 `entry/src/ohosTest/ets/test/EditHistoryCases.ets`，照 `entry/src/ohosTest/ets/test/TripFormatCases.ets:1-11` 的 `makeCase` 模式（`TimelineCase` + `expectString` / `expectNumber` / `expectTrue` / `expectFalse` 来自 `./TestSupport`）：

```typescript
import { EditRecord, makeRecordId, parseEditRecords, serializeEditRecords,
  sortRecordsNewestFirst, findRecordById, recordsForTrip, findLatestRecordForTrip,
  upsertRecord, removeRecords, recordMatchesTrip, formatExportTime,
  formatClockDuration, formatRecordSummary } from '../../../main/ets/model/EditRecord'
import { TimelineCase, expectString, expectNumber, expectTrue, expectFalse, firstError } from './TestSupport'

function makeCase(name: string, run: () => string): TimelineCase {
  const item = new TimelineCase()
  item.name = name
  item.run = run
  return item
}

function makeRecord(id: string, tripId: string, exportedAt: number): EditRecord {
  const record = new EditRecord()
  record.id = id
  record.tripId = tripId
  record.tripTitle = '10月1日 周三'
  record.tripStartTs = 1759296000000
  record.albumUri = `file://media/Photo/${id}/IMG.mp4`
  record.fileName = 'SmartDrive_Export_20261018_210400.mp4'
  record.exportedAt = exportedAt
  record.durationMs = 32000
  record.segmentCount = 2
  record.templateId = 'T5'
  record.snapshot = '{}'
  return record
}

export function editHistoryCases(): Array<TimelineCase> {
  const cases: Array<TimelineCase> = []
  // …每个函数至少一条用例（见下表）
  return cases
}
```

**必须覆盖的用例（每条一个 `makeCase`）:**

| 用例名 | 断言 |
|---|---|
| 坏 JSON 返回空列表 | `expectNumber(parseEditRecords('{oops').length, 0, '坏 JSON')` |
| 非数组 JSON 返回空列表 | `expectNumber(parseEditRecords('{"a":1}').length, 0, '非数组')` |
| 空串返回空列表 | `expectNumber(parseEditRecords('').length, 0, '空串')` |
| 缺 id 的条目被丢弃 | 喂 `[{"tripId":"t"}]`，结果长度 0 |
| 合法条目补齐默认值 | 喂只有 `id` 的条目，`tripTitle === ''`、`exportedAt === 0`、`schemaVersion === 1` |
| 解析结果按导出时间倒序 | 序列化 `[old, new]` 再 parse，`result[0].id === 'new'` |
| 序列化→解析往返保真 | `parseEditRecords(serializeEditRecords([r])).length === 1` 且 `tripStartTs` 相等 |
| 同 id 覆盖后只留一条 | `upsertRecord([a], a2).length === 1` 且取到 `a2` 的 `exportedAt` |
| 覆盖后重排到最前 | `upsertRecord([old, mid], 新的 old).id === 新的 old.id` |
| 新 id 追加 | `upsertRecord([a], b).length === 2` |
| 删除按 id 列表生效 | `removeRecords([a, b], ['a']).length === 1` 且剩下 `b` |
| 删除不存在的 id 无副作用 | `removeRecords([a], ['zzz']).length === 1` |
| 按行程取记录按时间倒序 | `recordsForTrip([a1, a2, b], 'tripA')[0].id` 是较新的 a |
| 取最近一条 | `findLatestRecordForTrip([...], 'tripA')` 命中最新 |
| 无记录时取最近返回 undefined | `expectTrue(findLatestRecordForTrip([], 'tripA') === undefined, '空列表')` |
| 按 id 查找 | `findRecordById([a, b], 'b')` 命中 b |
| 身份校验：标题+起点都对才通过 | `expectTrue(recordMatchesTrip(r, '10月1日 周三', 1759296000000), '匹配')` |
| 身份校验：起点差 1ms 就不通过 | `expectFalse(recordMatchesTrip(r, '10月1日 周三', 1759296000001), '起点漂移')` |
| 身份校验：标题为空直接不通过 | `expectFalse(recordMatchesTrip(r, '', 1759296000000), '空标题')` |
| 导出时间文案：日期用本机时区算 | 用例内先 `const d = new Date(1759296000000)`，再 `expectString(formatExportTime(1759296000000), \`${d.getMonth() + 1}月${d.getDate()}日 ${pad2(d.getHours())}:${pad2(d.getMinutes())} 导出\`, '时间')` —— **不要把时区相关的字面量写死** |
| 导出时间文案以「 导出」结尾 | `expectTrue(formatExportTime(1759296000000).endsWith(' 导出'), '后缀')` |
| 导出时间为 0 给占位 | `expectString(formatExportTime(0), '导出时间未知', '占位')` |
| 时长不足 1 小时 | `expectString(formatClockDuration(32000), '00:32', 'mm:ss')` |
| 时长跨小时 | `expectString(formatClockDuration(3723000), '1:02:03', 'h:mm:ss')` |
| 负数时长兜底 0 | `expectString(formatClockDuration(-5), '00:00', '负数')` |
| 段数摘要 | `expectString(formatRecordSummary(2, 32000), '2 段 · 00:32', '摘要')` |
| 段数为 0 也给 0 段 | `expectString(formatRecordSummary(0, 0), '0 段 · 00:00', '零段')` |
| 生成的 id 带前缀且唯一 | 两次 `makeRecordId` 不同，且都以 `rec_` 开头 |

- [x] **Step 2: 跑测试确认失败**

```powershell
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" tools/offline-test.mjs
```

预期：报 `Cannot find module .../model/EditRecord` 之类的解析错误（文件还不存在）。

- [x] **Step 3: 实现 `EditRecord.ets`**

要点：
- `parseEditRecords` 用 `try { JSON.parse(raw) as Array<EditRecord> } catch { return [] }`，再 `Array.isArray` 守卫，再逐条 `normalizeRecord`（`typeof source.x === 'string' ? source.x : ''`，数字同理），无 `id` 直接丢；最后 `sortRecordsNewestFirst`。
- `sortRecordsNewestFirst` 先 `slice()` 再 `sort((a, b) => b.exportedAt - a.exportedAt)`，**不原地改入参**。
- `upsertRecord` 遍历替换 + 未命中则 `push`，最后 `sortRecordsNewestFirst`。
- `formatExportTime` 用 `new Date(exportedAt)` + `getMonth() + 1` / `getDate()` / `getHours()` / `getMinutes()`；`exportedAt <= 0` 返回 `'导出时间未知'`。
- 内部 `pad2(value: number): string`（非导出）。

- [x] **Step 4: 注册用例**

- `tools/offline-test.mjs:39-45` 的 `SUITES` 追加：
  `{ path: 'entry/src/ohosTest/ets/test/EditHistoryCases.ets', exportName: 'editHistoryCases' },`
- 新建 `entry/src/ohosTest/ets/test/EditHistory.test.ets`：照 `entry/src/ohosTest/ets/test/TripFormat.test.ets` 的 hypium 包装（`describe` + 遍历 `editHistoryCases()` 逐个 `it` + `expect(result).assertEqual('')`），导入路径 `'../../../main/ets/model/EditRecord'` 对应的 Cases 工厂 `editHistoryCases`。
- `entry/src/ohosTest/ets/test/List.test.ets` 里按现有写法加 `editHistoryTest`（与其它 `*Test` 同层）。

- [x] **Step 5: 跑测试确认通过**

```powershell
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" tools/offline-test.mjs
```

预期：`150 + 27 = 177` 条全绿（原 150 条不许回归）。

- [x] **Step 6: 提交**

```powershell
git add entry/src/main/ets/model/EditRecord.ets entry/src/ohosTest/ets/test/EditHistoryCases.ets entry/src/ohosTest/ets/test/EditHistory.test.ets entry/src/ohosTest/ets/test/List.test.ets tools/offline-test.mjs
git commit -m "feat(我的剪辑): 新增 EditRecord 模型与历史列表纯函数"
```

---

## Task 2: 从导出快照还原编辑器状态的纯函数

**Files:**
- Modify: `entry/src/main/ets/model/Models.ets`（在 `:492` 之后追加）
- Modify: `entry/src/main/ets/model/SegmentModel.ets`（在 `:531` 之后追加）
- Create: `entry/src/ohosTest/ets/test/EditRestoreCases.ets`
- Create: `entry/src/ohosTest/ets/test/EditRestore.test.ets`
- Modify: `entry/src/ohosTest/ets/test/List.test.ets`
- Modify: `tools/offline-test.mjs:39-45`

**Interfaces:**
- Consumes: `ExportSnapshot` / `EditorState` / `Trip` / `TripSnapshot` / `ExportSegment` / `Segment` / `tripFromSnapshot` / `toTemplateId`（均已在 `Models.ets` / `SegmentModel.ets` / `TripModels.ets` 内）
- Produces:
  - `entry/src/main/ets/model/SegmentModel.ets`：
    - `export function toEditorSegments(exportSegments: Array<ExportSegment>): Array<Segment>` —— `id` 按序号 0..n-1 重编，`startSec = startMs / 1000`，`endSec = endMs / 1000`，`speedLabel` / `muted` 照抄，`enabled = true`
    - `export function isRawFullSegments(segments: Array<Segment>, totalDurationSec: number): boolean` —— 恰好 1 段、`enabled`、`startSec <= 0`、`endSec >= totalDurationSec`
  - `entry/src/main/ets/model/Models.ets`：
    - `export function parseExportSnapshot(raw: string): ExportSnapshot | undefined` —— 坏 JSON / 缺 `trip` / 缺 `playback` / `playback.segments` 非数组都返回 `undefined`
    - `export function snapshotMatchesTrip(stored: ExportSnapshot, live: TripSnapshot): boolean` —— `stored.trip.title` 非空且 `=== live.tripTitle` 且 `stored.trip.startTs === live.startTs`
    - `export function restoreEditorStateFromSnapshot(stored: ExportSnapshot, live: TripSnapshot, sessionId: string, exportStatus: string): EditorState` —— `trip` 取 `tripFromSnapshot(live)`（**素材以现场为准**），`selectedTemplateId` / `playback.playheadMs` / `playback.segments` / `brand.watermarkEnabled` 取 `stored`（**参数以记录为准**），`ui = { drawerExpanded: true, exporting: false, exportStatus }`

- [x] **Step 1: 先写失败用例**

创建 `entry/src/ohosTest/ets/test/EditRestoreCases.ets`，沿用 Task 1 的 `makeCase` 模式，导出 `editRestoreCases`。构造一个最小 `TripSnapshot` 与一个 `ExportSnapshot`：

```typescript
function makeLive(): TripSnapshot {
  const live = new TripSnapshot()
  live.id = 'trip-2026-10-01-1759296000000-3'
  live.tripTitle = '10月1日 周三'
  live.tripRange = '13:28 - 13:40'
  live.durationSec = 720
  live.startTs = 1759296000000
  live.endTs = 1759296720000
  live.previewUri = 'file:///data/front.mp4'
  live.previewFrameUri = '/data/thumb.jpg'
  live.previewCamera = 'Front'
  live.clips = []
  live.timeline = []
  return live
}
```

`ExportSnapshot` 用 `deepCloneExportSnapshot(createEditorStateFromSnapshot(live, 's1', 'T3', [seg], false, true, '待导出'))` 产出，其中 `seg` 是 `createFullSegment(720)[0]` 改过边界的段（例如 `startSec = 30, endSec = 120, speedLabel = '1.5X'`）。

**必须覆盖的用例:**

| 用例名 | 断言 |
|---|---|
| 坏 JSON 快照返回 undefined | `expectTrue(parseExportSnapshot('{oops') === undefined, '坏 JSON')` |
| 空串返回 undefined | `expectTrue(parseExportSnapshot('') === undefined, '空串')` |
| 缺 trip 返回 undefined | 喂 `{"playback":{"segments":[]}}` → undefined |
| segments 非数组返回 undefined | 喂 `{"trip":{},"playback":{"segments":1}}` → undefined |
| 合法快照往返可用 | `parseExportSnapshot(JSON.stringify(snap))` 非 undefined |
| 身份匹配：标题+起点一致 | `expectTrue(snapshotMatchesTrip(snap, live), '匹配')` |
| 身份漂移：起点不同 | 改 `live.startTs += 1` → `expectFalse(...)` |
| 身份漂移：标题不同 | 改 `live.tripTitle = '10月2日 周四'` → `expectFalse(...)` |
| 还原用现场素材不用记录素材 | `restoreEditorStateFromSnapshot(snap, live, 's2', '待导出').trip.tripId === live.id` |
| 还原用记录模板 | `...selectedTemplateId === TemplateId.T3`（记录里存的是 T3） |
| 还原用记录水印 | `...brand.watermarkEnabled === false` |
| 还原用记录分段参数 | `...playback.segments[0].speedLabel === '1.5X'` 且 `startMs === 30000` |
| 还原的 exportStatus 可控 | 传 `'已还原历史剪辑'` → `...ui.exportStatus === '已还原历史剪辑'` |
| 还原不共享记录数组引用 | 改返回值的 `playback.segments`，原 `snap.playback.segments` 不变 |
| ExportSegment→Segment 序号重编 | `toEditorSegments([e0, e1]).map(id)` 为 `[0, 1]` |
| ExportSegment→Segment 毫秒转秒 | `startMs = 1500` → `startSec === 1.5` |
| 单段覆盖全片算原始态 | `expectTrue(isRawFullSegments(createFullSegment(720), 720), '原始态')` |
| 剪过的段不算原始态 | 上面 `[30,120]` 的段 → `expectFalse(...)` |
| 两段不算原始态 | 两段拼满全片 → `expectFalse(...)` |

- [x] **Step 2: 跑测试确认失败**（同上一条命令，预期报找不到 `toEditorSegments` / `restoreEditorStateFromSnapshot`）

- [x] **Step 3: 实现**

`SegmentModel.ets`：`toEditorSegments` 与 `isRawFullSegments` 追加在 `:531` 之后，紧挨 `toExportSegments` / `exportDurationSec`，并在文件头注释里补一句「与 `toExportSegments` 互逆」。

`Models.ets`：`parseExportSnapshot` / `snapshotMatchesTrip` / `restoreEditorStateFromSnapshot` 追加在 `deepCloneExportSnapshot` 之后（`:492` 起）。

- [x] **Step 4: 注册用例**（`tools/offline-test.mjs` 的 `SUITES` 加 `EditRestoreCases.ets` / `editRestoreCases`；新建 `EditRestore.test.ets`；`List.test.ets` 加 `editRestoreTest`）

- [x] **Step 5: 跑测试确认通过**（预期全绿）

- [x] **Step 6: 提交**

```powershell
git add entry/src/main/ets/model/Models.ets entry/src/main/ets/model/SegmentModel.ets entry/src/ohosTest/ets/test/EditRestoreCases.ets entry/src/ohosTest/ets/test/EditRestore.test.ets entry/src/ohosTest/ets/test/List.test.ets tools/offline-test.mjs
git commit -m "feat(我的剪辑): 新增按记录快照还原编辑器状态的纯函数"
```

---

## Task 3: `pref_edit_records` 持久化与 `EditHistoryService`

**Files:**
- Modify: `entry/src/main/ets/service/PreferencesService.ets`
- Create: `entry/src/main/ets/service/EditHistoryService.ets`
- Modify: `tools/typecheck-player.mjs`（`home` 与 `export` 两个 group 的 `deps` 加 `EditRecord.ets` / `EditHistoryService.ets`）

**Interfaces:**
- Consumes: `EditRecord` / `parseEditRecords` / `serializeEditRecords` / `upsertRecord` / `removeRecords`（Task 1）
- Produces:
  - `PreferencesService` 新增（`:7` 之后加常量）：
    - `const KEY_EDIT_RECORDS: string = 'pref_edit_records'`（非导出）
    - `public async loadEditRecords(): Promise<Array<EditRecord>>` —— 打开失败**返回 `[]` 并 `debugLog` 明确错误**，不再静默吞
    - `public async saveEditRecords(records: Array<EditRecord>): Promise<boolean>` —— 成功 `true`；store 打不开或 `put`/`flush` 抛错则 `false`（调用方据此提示「历史记录暂时不可用」）。内存 Map 仍然同步写，作为同进程内的兜底读源
    - `public isPersistent(): boolean` —— `this.context !== null`
  - `EditHistoryService`（新文件，单例）:
    - `export class EditHistoryService`
    - `private static instance: EditHistoryService | null = null` / `public static getInstance(): EditHistoryService`
    - `public async list(): Promise<Array<EditRecord>>`
    - `public async findById(id: string): Promise<EditRecord | undefined>`
    - `public async latestForTrip(tripId: string): Promise<EditRecord | undefined>`
    - `public async upsert(record: EditRecord): Promise<boolean>`
    - `public async remove(ids: Array<string>): Promise<boolean>`
    - `public async updateCoverPath(id: string, coverPath: string): Promise<boolean>`
    - `public async setContext(context: common.UIAbilityContext | null): Promise<void>`（转调 `PreferencesService.getInstance().setContext`）
  - 说明：**`EditHistoryService.ets` 不是纯模块**（导入 `PreferencesService` → `@ohos.data.preferences`），因此**不得**进 `offline-test.mjs` 的 `SUITES`；只进 `typecheck-player.mjs` 的 deps。

- [x] **Step 1: 改 `PreferencesService`**

照 `saveLastTripId`（`:37-47`）/ `getLastTripId`（`:50-61`）的既有写法加两个方法。**关键**：`loadEditRecords` 在 `getPreferencesStore()` 返回 `null` 或 `store.get` 抛错时，`debugLog('偏好设置', '历史记录读取失败，本次以空列表继续')` 并返回 `[]`；`saveEditRecords` 同样 `debugLog` 后返回 `false`。**不要**让失败静默变成「看起来成功」。

- [x] **Step 2: 建 `EditHistoryService`**

薄封装：所有方法 `await` 到 `PreferencesService.getInstance()` 的读写，用 Task 1 的纯函数做列表变换（`upsert` 先 `list()` 再 `upsertRecord` 再 `saveEditRecords`）。`updateCoverPath` 只在 `coverPath` 非空且与现值不同时写盘（避免每次渲染都写）。

- [x] **Step 3: 登记 typecheck group**

`tools/typecheck-player.mjs` 的 `GROUPS`：给 `home` 与 `export` 两个 group 的 `deps` 各加
`'entry/src/main/ets/model/EditRecord.ets'` 与 `'entry/src/main/ets/service/EditHistoryService.ets'`（`PreferencesService.ets` 已在 deps 里）。

- [x] **Step 4: 语法类型检查**

```powershell
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" tools/typecheck-player.mjs home
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" tools/typecheck-player.mjs export
```

预期：两条都无 diagnostics 输出、退出码 0。

- [x] **Step 5: 离线测试不许回归**

```powershell
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" tools/offline-test.mjs
```

预期：全绿（`EditHistoryService` 不在 SUITES 里，不影响）。

- [x] **Step 6: 提交**

```powershell
git add entry/src/main/ets/service/PreferencesService.ets entry/src/main/ets/service/EditHistoryService.ets tools/typecheck-player.mjs
git commit -m "feat(我的剪辑): 新增 pref_edit_records 持久化与 EditHistoryService"
```

---

## Task 4: 导出覆盖写入与记录落盘

**Files:**
- Modify: `entry/src/main/ets/service/ExportManager.ets`
- Modify: `entry/src/main/ets/NativeExportManager.ets`
- Modify: `tools/typecheck-player.mjs`（`export` group deps 已在 Task 3 加过；确认 `SegmentModel.ets` 也在 deps 里，没有就补）

**Interfaces:**
- Consumes: `EditRecord` / `makeRecordId`（Task 1）· `EditHistoryService`（Task 3）· `exportDurationSec`（`SegmentModel.ets:534`）· `deepCloneExportSnapshot` 产出的 `ExportSnapshot`
- Produces:
  - `ExportManager`：
    - `private jobs` 的记录结构加 `overwriteTargetUri: string`（空串 = 新建）
    - `async start(snapshot: ExportSnapshot, context: common.UIAbilityContext, overwriteTargetUri?: string): Promise<ExportJobId>`（`:140` 签名扩展，第三参可省，省略时行为与今天**完全一致**）
    - `private async run(record: ExportJobRecord, context: common.UIAbilityContext): Promise<void>`（`:156`）末尾新增：相册写入成功后 `await this.persistRecord(record, albumUri, fileName, context)`
    - `private async persistRecord(record: ExportJobRecord, albumUri: string, fileName: string, context: common.UIAbilityContext): Promise<void>` —— 组装 `EditRecord` 并 `EditHistoryService.getInstance().upsert(...)`；**任何异常都只 `debugLog`，绝不冒泡**（不能因为落盘失败就把一次成功的导出判成失败）
    - `private async saveVideoToAlbum(fileName: string, sourceUri: string, context: common.UIAbilityContext, startProgress: number, onProgress: (percent: number) => void, overwriteTargetUri: string): Promise<string>`（`:250` 签名扩展第六参）
  - `NativeExportManager`：
    - `export async function startNativeExport(snapshot: ExportSnapshot, context: common.UIAbilityContext, onEvent?: (event: ExportJobEvent) => void, overwriteTargetUri?: string): Promise<string>`（`:5`，第四参可省）

**覆盖分支的三处改动（缺一不可）:**

1. `saveVideoToAlbum` 开头：`if (overwriteTargetUri.length > 0) { albumUri = overwriteTargetUri } else { ...现有 showAssetsCreationDialog... }` —— **覆盖时绝不弹保存对话框**（spec 4.5）。
2. `fs.open`：新建走现有 `fs.OpenMode.READ_WRITE`；覆盖走 `fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC` —— **不加 TRUNC 时新成片比旧的短就会在文件尾部残留旧字节，产物直接损坏**（spec 4.6）。
3. 覆盖时 `fileName` 仍是新名字（`buildExportFileName()` 的返回值），只是相册条目的物理名保留旧的 —— 记录里的 `fileName` 记真实新名字。

**`persistRecord` 的字段映射（spec 4.1）:**

| `EditRecord` 字段 | 来源 |
|---|---|
| `id` | 覆盖时 = 被覆盖记录的 `id`；新建时 = `makeRecordId(Date.now(), Math.random())` |
| `tripId` | `record.snapshot.trip.tripId` |
| `tripTitle` | `record.snapshot.trip.title` |
| `tripStartTs` / `tripEndTs` | `record.snapshot.trip.startTs` / `.endTs` |
| `albumUri` | `saveVideoToAlbum` 的返回值 |
| `fileName` | `buildExportFileName()` 的返回值 |
| `exportedAt` | `Date.now()` |
| `durationMs` | `Math.round(exportDurationSec(record.snapshot.playback.segments) * 1000)` |
| `segmentCount` | `record.snapshot.playback.segments.length` |
| `templateId` | `record.snapshot.selectedTemplateId` |
| `snapshot` | `JSON.stringify(record.snapshot)` |
| `coverPath` | `''` —— 由「我的剪辑」列表异步补（Task 8） |

覆盖时 `id` 必须原样保留，`upsert` 才能替换而不是追加（spec 4.5 第 3 条）。

- [x] **Step 1: 扩展 `start` / `run` / `saveVideoToAlbum` 签名并透传 `overwriteTargetUri`**

- [x] **Step 2: 在 `saveVideoToAlbum` 里加覆盖分支（跳过对话框 + TRUNC）**

- [x] **Step 3: 加 `persistRecord` 并在 `run` 的相册成功分支后调用**

覆盖时**不额外加参数**：在 `persistRecord` 里若 `record.overwriteTargetUri.length > 0`，就 `await EditHistoryService.getInstance().list()` 后找出 `albumUri === record.overwriteTargetUri` 的那条，把它的 `id` 与 `coverPath` 继承过来（`id` 不变才能被 `upsertRecord` 替换而不是追加）。找不到（记录被用户删了）就退回 `makeRecordId(...)` 新建一条 —— 此时相册条目已被覆写，新记录指向同一个 `albumUri`，语义仍然正确。

- [x] **Step 4: `ExportManager.start` 里先 `PreferencesService.getInstance().setContext(context)`**

保证 `EditHistoryService` 有 context 可写（`CoreBridge.ets:567` 也会设，但导出不一定经过它）。

- [x] **Step 5: `NativeExportManager.startNativeExport` 透传第四参**

```powershell
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" tools/typecheck-player.mjs export
```

预期：无 diagnostics、退出码 0。

- [x] **Step 6: 提交**

```powershell
git add entry/src/main/ets/service/ExportManager.ets entry/src/main/ets/NativeExportManager.ets tools/typecheck-player.mjs
git commit -m "feat(我的剪辑): 导出支持就地覆写并把作品记录落盘"
```

---

## Task 5: `CoreBridge` 还原入口与 `EditorViewModel`

**Files:**
- Modify: `entry/src/main/ets/bridge/CoreBridge.ets`
- Modify: `entry/src/main/ets/viewmodel/EditorViewModel.ets`
- Modify: `tools/typecheck-player.mjs`（`bridge` group deps 加 `EditRecord.ets`）

**Interfaces:**
- Consumes: `parseExportSnapshot` / `snapshotMatchesTrip` / `restoreEditorStateFromSnapshot` / `toEditorSegments` / `isRawFullSegments`（Task 2）· `EditRecord` / `parseEditRecords`（Task 1）
- Produces:
  - `CoreBridge`：
    - `restoreEditorState(tripId: string, recordJson: string): EditorStateModel` —— 新增公开方法，放在 `createEditorState`（`:783`）之后
    - 私有 `private applyRestoredState(restored: EditorState, live: TripSnapshot): EditorStateModel` —— 把纯模型结果写回 CoreBridge 的实例字段（`activeTemplateId` / `watermarkEnabled` / `segments` / `playheadMs` / `segmentSourceDurationSec` / `isRawFull` / `exportStatusText`），再 `return this.buildEditorState(live, live.previewCamera, 0)`
  - `EditorViewModel`：
    - `hydrateFromRecord(tripId: string, recordJson: string): EditorHydrateResult`（与 `hydrate`（`:27`）并列）
  - 语义：`restoreEditorState` **不自己判断**能不能还原，只做「能还原时的装配」。判断由调用方用 `snapshotMatchesTrip` 先做。

**`restoreEditorState` 的行为（照 spec 4.4）:**

```
1. live = this.trips.get(tripId)
2. live 不存在 → 返回 this.createEditorState(tripId, '', '')   // 素材没了，降级白纸
3. record = 第一个解析出来的 EditRecord（parseEditRecords(recordJson)[0]）
   record 不存在 → 同上降级
4. stored = parseExportSnapshot(record.snapshot)
   stored 不存在 → 同上降级
5. snapshotMatchesTrip(stored, live) 为 false → 同上降级
   （调用方负责在这之前用同样的判断给出「明确报错」的出口；这里只是最后一道防线）
6. restored = restoreEditorStateFromSnapshot(stored, live, `${tripId}_restore_${Date.now()}`, '已还原历史剪辑')
7. return this.applyRestoredState(restored, live)
```

`applyRestoredState` 的字段写入：

```typescript
this.tripId = live.id
this.tripTitle = live.tripTitle
this.tripRange = live.tripRange
this.tripDurationSec = live.durationSec
this.previewCamera = live.previewCamera
this.currentClipIndex = 0
this.currentClipTotal = live.clips.length
this.activeTemplateId = restored.selectedTemplateId
this.watermarkEnabled = restored.brand.watermarkEnabled
this.drawerExpanded = true
this.segments = toEditorSegments(restored.playback.segments)
this.selectedSegmentId = this.segments.length > 0 ? this.segments[0].id : -1
this.playheadMs = restored.playback.playheadMs
this.segmentSourceDurationSec = -1
this.isRawFull = isRawFullSegments(this.segments, live.durationSec)
this.exportStatusText = restored.ui.exportStatus
```

- [x] **Step 1: 在 `CoreBridge` 加 `restoreEditorState` + `applyRestoredState`**

- [x] **Step 2: 在 `EditorViewModel` 加 `hydrateFromRecord`**

```typescript
hydrateFromRecord(tripId: string, recordJson: string): EditorHydrateResult {
  const state = this.bridge.restoreEditorState(tripId, recordJson)
  const result: EditorHydrateResult = {
    state: state,
    tripSnapshot: this.bridge.getTripSnapshotClone(state.tripId) ?? new TripSnapshot(),
    exportSessionSeed: `${state.tripId}_${Date.now()}`
  }
  return result
}
```

- [x] **Step 3: 登记 deps 并检查**

```powershell
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" tools/typecheck-player.mjs bridge
```

预期：无 diagnostics、退出码 0。

- [x] **Step 4: 提交**

```powershell
git add entry/src/main/ets/bridge/CoreBridge.ets entry/src/main/ets/viewmodel/EditorViewModel.ets tools/typecheck-player.mjs
git commit -m "feat(我的剪辑): CoreBridge 支持按记录还原编辑器状态"
```

---

## Task 6: 剪辑页集成 —— 成功 toast、覆盖询问、按记录还原、身份漂移出口

**Files:**
- Modify: `entry/src/main/ets/pages/Editor.ets`

**Interfaces:**
- Consumes: `EditorViewModel.hydrateFromRecord`（Task 5）· `EditHistoryService`（Task 3）· `startNativeExport(snapshot, context, onEvent, overwriteTargetUri?)`（Task 4）· `recordMatchesTrip` / `parseExportSnapshot` / `findLatestRecordForTrip` / `recordsForTrip`（Task 1/2）· 既有 `showToast`（`:249`）/ `updateExportStatus`（`:545`）
- Produces: 无新公开接口

**四处改动:**

**(a) `aboutToAppear` 读 `recordId`（`:122-147`）**

```typescript
const recordId = params.recordId ?? ''            // 新增
// …
if (recordId.length > 0) {
  const record = await EditHistoryService.getInstance().findById(recordId)
  const live = this.viewModel.getTripSnapshot(tripId)          // EditorViewModel.ets:134
  const stored = record ? parseExportSnapshot(record.snapshot) : undefined
  if (record && stored && snapshotMatchesTrip(stored, live)) {
    this.recordId = recordId
    const hydrateResult = this.viewModel.hydrateFromRecord(tripId, JSON.stringify([record]))
    this.exportSessionSeed = hydrateResult.exportSessionSeed
    this.applyState(hydrateResult.state)
    this.tripSnapshot = hydrateResult.tripSnapshot
  } else {
    this.driftVisible = true      // 明确报错，绝不静默用错素材（反目标 3）
    return
  }
} else {
  // …现有白纸路径原样不动…
}
```

> `aboutToAppear` 变成 `async`；若 ArkUI 生命周期不允许 async，就保持同步、把这段抽成 `private async resolveRestore(recordId, tripId)` 并在 `aboutToAppear` 里 `void this.resolveRestore(...)`，用 `@State restorePending: boolean = true` 挡住首帧。

**(b) 身份漂移弹窗（新增 `@State driftVisible: boolean = false`）**

照 `backConfirmVisible`（`:55`，弹窗在 `:987`）的既有写法加一个模态：
- 标题「原始行程素材已不在」
- 说明「这次剪辑无法还原。可能是源素材被删除、被移动，或这是一次合并剪辑（重启后合并行程不再存在）。」
- 两个按钮：**当作新剪辑打开** → `driftVisible = false` 后走 `this.viewModel.hydrate(tripId)` 白纸路径；**返回** → `this.getUIContext().getRouter().back()`

**(c) 点导出时先问覆盖（`startNativeExportTask`，`:556`）**

在 `buildExportSnapshot` 之前插入：

```typescript
const records = await EditHistoryService.getInstance().list()
const mine = recordsForTrip(records, this.state.tripId)
const target = this.recordId.length > 0
  ? findRecordById(mine, this.recordId)
  : (mine.length > 0 ? mine[0] : undefined)
if (target) {
  this.overwriteCandidate = target
  this.overwritePromptVisible = true
  return                    // 等用户在弹窗里选完再真正开跑
}
void this.launchExport('')  // 无记录，直接导出
```

新增 `@State overwritePromptVisible: boolean = false` 与 `private overwriteCandidate?: EditRecord`；把 `:584` 起的导出逻辑整体抽成 `private async launchExport(overwriteTargetUri: string): Promise<void>`，内部调用改成：

```typescript
const outputPath = await startNativeExport(exportSnapshot, context, (event) => { /* 原样 */ }, overwriteTargetUri)
```

覆盖询问弹窗（照 `export` 模态 `:1028` 的样式）文案：
- 从「我的剪辑」进来（`this.recordId.length > 0`）：「这条作品已经导出过，要覆盖它吗？」
- 从「行程库」进来：「这趟行程已经导出过 N 条，要覆盖最近那一条吗？」（`N = mine.length`）
- 按钮：**覆盖那一条** → `overwritePromptVisible = false; void this.launchExport(this.overwriteCandidate.albumUri)`；**存成新的** → `overwritePromptVisible = false; void this.launchExport('')`

**(d) 导出成功的 toast（`:585-589` 的事件回调）**

`startNativeExport` 的 `then` 分支里，`outputPath` 拿到之后（`:590` 之后、`:594` 之前）：

```typescript
this.updateExportStatus('已保存到相册')
this.showToast('已保存到相册')
```

覆盖与新建共用这一句（用户要的就是「保存成功」的回执，spec 4.9）。**注意**：`NativeExportManager` 会在**第一个**终结事件上 resolve，而 `ExportManager` 先发 `导出完成：${fileName}` 再发 `相册保存成功：${albumUri}` —— 所以 `.then` 里拿到的不一定是相册 URI。toast 只依赖「成功」这件事，不解析文本，因此不受影响。

- [x] **Step 1: 加 `@State` 字段**（`recordId` / `driftVisible` / `overwritePromptVisible` / `overwriteCandidate` / `restorePending`）

- [x] **Step 2: 改 `aboutToAppear` 的还原分支 + 漂移弹窗**

- [x] **Step 3: 抽 `launchExport(overwriteTargetUri)` + 覆盖询问弹窗**

- [x] **Step 4: 加成功 toast**

- [x] **Step 5: 检查**

```powershell
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" tools/typecheck-player.mjs player
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" tools/offline-test.mjs
```

预期：typecheck 无 diagnostics；离线测试全绿（`checkNoLegacyColors` 会扫 `pages/Editor.ets`，**不许出现十六进制颜色**）。

- [x] **Step 6: 提交**

```powershell
git add entry/src/main/ets/pages/Editor.ets
git commit -m "feat(我的剪辑): 剪辑页支持按记录还原、覆盖询问与保存成功提示"
```

---

## Task 7: `EditRecordCard` 组件与缩略图异步加载

**Files:**
- Create: `entry/src/main/ets/components/EditRecordCard.ets`
- Modify: `tools/offline-test.mjs`（`UI_FILES` 加 `entry/src/main/ets/components/EditRecordCard.ets`）
- Modify: `entry/src/main/resources/base/element/color.json`（**只在现有 token 不够用时**才加；加了就同步 `tools/offline-test.mjs` 的 `REQUIRED_COLOR_TOKENS`）

**Interfaces:**
- Consumes: `EditRecord` / `formatExportTime` / `formatRecordSummary`（Task 1）· `getTemplateUiNameById`（`constants/AppConstants.ets:11`）· `extractFirstFrameByService`（`service/ExportNativeService.ets:101`）· `resolveThumbnailCachePath`（同文件 `:72`）
- Produces:
  - `export struct EditRecordCard`
  - `@Prop record: EditRecord`
  - `@Prop selected: boolean`
  - `@Prop selectionMode: boolean`
  - `@Prop orphan: boolean`（`true` = 相册里那份已被删，降级显示）
  - `@Prop coverPath: string`（由父组件异步填好；空串时回落到 `@Prop fallbackCoverUri: string`）
  - `@Prop fallbackCoverUri: string`（该行程在行程库里的封面）
  - `onOpen: () => void` / `onPlay: () => void` / `onToggleSelect: () => void`（`@Prop` 回调，照 `components/SegmentParamRow.ets` 的既有回调写法）

**视觉（spec 4.12，严格照做）:**

```
┌──────────────────────────┐
│     成片首帧 16:9     ▶  │
├──────────────────────────┤
│ 10月1日 周三 · 单视角     │
│ 2 段 · 00:32             │
│ 10月18日 21:04 导出       │
│ [ 重新剪辑 ]              │
└──────────────────────────┘
```

- 白底（`card_bg`）、`1px ed_line` 描边、10px 圆角；
- 顶部 16:9：`Column().width('100%').aspectRatio(16 / 9).borderRadius(9).clip(true).backgroundColor($r('app.color.stage_bg'))` —— 与 `pages/Index.ets:325-372` 的封面写法保持一致（含 `objectFit(ImageFit.Cover)` 与 `alt($r('app.media.app_icon'))`）；
- 封面右下角半透明白圆 ▶（用 `AppIcon` 里已有的播放图标，`components/AppIcon.ets:30`）；`orphan === true` 时 ▶ 置灰且 `onClick` 不触发（spec 4.11）；
- 下方三行文字：第一行 `getTemplateUiNameById(record.templateId)` 拼在 `record.tripTitle` 后面（`·` 分隔），字号 14/粗/`text_primary`；第二行 `formatRecordSummary(record.segmentCount, record.durationMs)`；第三行 `formatExportTime(record.exportedAt)`，字号 12/`text_tertiary`；
- 第四行「重新剪辑」胶囊：`amber_soft` 底 + `chip_amber_border` 边 + `amber` 字；
- `orphan === true` 时封面加灰罩（`overlay_veil`）并叠一行「相册里的视频已被删除」（`overlay_text`）；
- 多选态（`selectionMode`）左上角画选择勾，照 `pages/Index.ets:356-365` 的徽标写法；
- **卡片主体点击 = `onOpen`（重新剪辑）；▶ 点击 = `onPlay`（看成片）**（spec 4.12 的「卡片上的分工」）。

**缩略图加载策略（spec 4.8）:**

- `cacheKey` 用 `record.id`；
- 父组件（Task 9）在拿到记录后**异步**调 `extractFirstFrameByService(record.albumUri, cacheDir, record.id)`，成功则 `EditHistoryService.updateCoverPath(record.id, path)` 并更新本地 `@State`；
- **并发度限制为 2**（用简单的 `pending` 计数 + 队列，或分批 `Promise`），避免一次性拉起几十个 AVImageGenerator；
- **卡片渲染永远不等缩略图**：先显示 `fallbackCoverUri`，取到后替换；
- 取不到（返回 `''`）就**一直用 `fallbackCoverUri`**，不重试、不报错。

- [x] **Step 1: 写 `EditRecordCard.ets`**（纯 UI，无业务判断）

- [x] **Step 2: 登记 `UI_FILES`**

`tools/offline-test.mjs` 里 `checkNoLegacyColors` 用的 `UI_FILES` 列表加 `'entry/src/main/ets/components/EditRecordCard.ets'`。

- [x] **Step 3: 跑离线测试**

```powershell
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" tools/offline-test.mjs
```

预期：全绿。若报 `checkColorReferences` 失败，说明用了不存在的 `$r('app.color.X')` —— 要么改用已有 token，要么在 `color.json` 里补上并同步 `REQUIRED_COLOR_TOKENS`。

- [x] **Step 4: 提交**

```powershell
git add entry/src/main/ets/components/EditRecordCard.ets entry/src/main/resources/base/element/color.json tools/offline-test.mjs
git commit -m "feat(我的剪辑): 新增作品卡片组件"
```

---

## Task 8: `HomeViewModel` 我的剪辑状态与路由

**Files:**
- Modify: `entry/src/main/ets/viewmodel/HomeViewModel.ets`
- Modify: `tools/typecheck-player.mjs`（`home` group deps 已在 Task 3 加过）

**Interfaces:**
- Consumes: `EditRecord` / `findRecordById` / `removeRecords`（Task 1）· `EditHistoryService`（Task 3）· `PAGE_ROUTE_EDITOR`（`constants/AppConstants.ets:3`）
- Produces:
  - `export interface HomeRouteParams { tripId: string; recordId?: string }`（`:13-15` 扩展，`recordId` 可选，**不影响**现有 `openEditorRoute`）
  - `export interface MyEditsViewState { records: Array<EditRecord>; isLoading: boolean; errorText: string; coverPaths: Record<string, string>; orphanIds: Array<string>; unknownIds: Array<string>; selectionMode: boolean; selectedRecordIds: Array<string> }`
  - `HomeViewModel` 新增：
    - `private myEdits: MyEditsViewState`
    - `getMyEditsState(): MyEditsViewState`
    - `async refreshMyEdits(context: common.UIAbilityContext): Promise<void>` —— `EditHistoryService.list()`；失败时 `errorText = '历史记录暂时不可用'`（spec 4.2）；随后**异步**补缩略图（Task 7 的并发 2 策略）与孤儿检测
    - `openEditorFromRecordRoute(record: EditRecord): HomeRouteRequest` → `{ url: PAGE_ROUTE_EDITOR, params: { tripId: record.tripId, recordId: record.id } }`
    - `toggleRecordSelection(recordId: string): void` / `toggleRecordSelectionMode(): void` / `isRecordSelected(recordId: string): boolean` / `canShowDeleteButton(): boolean`（`selectionMode && selectedRecordIds.length >= 1`）
    - `async deleteSelectedRecords(): Promise<boolean>` —— `EditHistoryService.remove(ids)` 后重读列表
    - `isRecordOrphan(recordId: string): boolean` / `isRecordOrphanUnknown(recordId: string): boolean`
    - `async playRecord(record: EditRecord, context: common.UIAbilityContext): Promise<string>` —— 见下

**孤儿检测（spec 4.11，三条硬规则）:**

1. **先确认 `ohos.permission.READ_IMAGEVIDEO` 已授予**；未授予 → 所有记录进 `unknownIds`，`orphanIds` 保持空，**不判孤儿**；
2. 只有「权限已授予 **且** `albumUri` 打不开」才进 `orphanIds`；
3. **检测过程零写盘** —— 不 `updateCoverPath`、不改记录、不删记录。

**`playRecord` 的隐式 Want（spec 4.10）:**

```typescript
const want: Want = {
  action: 'ohos.want.action.viewData',          // 字面量：stage model 没有 ACTION_VIEW_DATA 常量
  uri: record.albumUri,
  type: 'video/mp4',
  flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
}
try {
  await context.startAbility(want)
  return ''
} catch (error) {
  return '没有找到能播放这条视频的应用'      // 16000019 No matching ability is found
}
```

**不要**硬编图库的 `bundleName` / `abilityName`（非公开 API）。项目里**没有 `startAbility` 先例**，这是第一次用。

- [x] **Step 1: 加 `MyEditsViewState` 与字段**

- [x] **Step 2: 加 `refreshMyEdits`（列表 + 缩略图 + 孤儿检测）**

- [x] **Step 3: 加路由 `openEditorFromRecordRoute`**

- [x] **Step 4: 加多选删除**

- [x] **Step 5: 加 `playRecord`**

- [x] **Step 6: 检查**

```powershell
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" tools/typecheck-player.mjs home
```

预期：无 diagnostics、退出码 0。

- [x] **Step 7: 提交**

```powershell
git add entry/src/main/ets/viewmodel/HomeViewModel.ets
git commit -m "feat(我的剪辑): 首页视图模型支持作品列表、还原路由与删除"
```

---

## Task 9: 首页双 Tab 集成

**Files:**
- Modify: `entry/src/main/ets/pages/Index.ets`
- Modify: `entry/src/main/resources/base/profile/main_pages.json` —— **不改**（Tab 在页内切换，不新增路由页，spec 3.4）

**Interfaces:**
- Consumes: `HomeViewModel.getMyEditsState()` / `refreshMyEdits()` / `openEditorFromRecordRoute()` / `toggleRecordSelection()` / `deleteSelectedRecords()` / `playRecord()` / `isRecordOrphan()`（Task 8）· `EditRecordCard`（Task 7）· `PAGE_ROUTE_EDITOR`（`constants/AppConstants.ets:3`）
- Produces: 无新公开接口

**改动:**

1. **新增 `@State activeTab: number = 0`**（0 = 行程库，1 = 我的剪辑）。
2. **新增 `@State private myEdits: MyEditsViewState`**，并在既有的 `syncViewState()`（`pages/Index.ets:60-62` 注册的监听回调）里一并从 `this.viewModel.getMyEditsState()` 拷一份进来。
   > **必须这么做**：ArkUI 的 `ForEach` 只认 `@State`/`@Prop` 的变化，直接在 `build()` 里调 `this.viewModel.getMyEditsState().records` 拿数组，列表**不会**随数据刷新。现有行程库列表就是靠 `@State displayCards` + `syncViewState()` 走通的，这里照抄同一条路。
3. **页头**（`pageHeader`，`:217-263`）：
   - 标题随 Tab 变（`this.activeTab === 0 ? this.state.title : '我的剪辑'`）；
   - 汇总文案只在 Tab 0 显示；
   - 右侧按钮：Tab 0 保留「合并剪辑 / 多选」原样；Tab 1 换成「选择」（`selectionMode ? '取消' : '选择'`）。
4. **Tab 栏**：在页头下方、列表上方插一行两个文字项「行程库」「我的剪辑」，选中态 = `$r('app.color.amber')` 文字 + 一条 2vp 高、背景 `$r('app.color.amber')` 的下划线（`Divider` 或 `Column`）。**禁止写 `#D98324` 之类的字面量**（`checkNoLegacyColors` 会扫本文件）。切换时 `this.activeTab = n`，首次切到 Tab 1 触发 `this.viewModel.refreshMyEdits(context)`。
5. **列表区**（`build()`，`:479-505`）按 `activeTab` 分支：
   - Tab 0 = 现有 `loadingBlock` / `permissionBlock` / `emptyBlock` / `tripList` 四分支**原样不动**；
   - Tab 1 = `myEditsList()` 新 builder：`List` + `ForEach(this.viewModel.getMyEditsState().records, (item: EditRecord) => ListItem() { EditRecordCard({...}) }, (item: EditRecord) => item.id)`；
   - Tab 1 空态：一句「还没有剪辑过的视频」+ 说明 + 黑底「去行程库」按钮（`onClick` → `this.activeTab = 0`），照 `emptyBlock`（`:444-457`）的样式；
   - Tab 1 读失败：显示 `errorText`。
6. **删除确认弹窗**：文案必须写清「**只会从列表移除，相册里的视频不会被删掉**」（spec 4.7）—— 不能让用户以为视频也没了。照 `pages/Editor.ets` 的 `backConfirmVisible` 模态写法。
7. **`EditRecordCard` 回调接线**：
   - `onOpen` → `const route = this.viewModel.openEditorFromRecordRoute(record); this.getUIContext().getRouter().pushUrl(route)`（照 `openEditor`（`:115-124`）的 try/catch 写法）；
   - `onPlay` → `const message = await this.viewModel.playRecord(record, context); if (message.length > 0) { /* toast */ }`；
   - `onToggleSelect` → `this.viewModel.toggleRecordSelection(record.id)`。
8. **多选态下点卡片**只切选择，不跳转。

- [x] **Step 1: 加 `activeTab` / `myEdits` 两个 `@State` 与 Tab 栏，并在 `syncViewState()` 里同步 `myEdits`**

- [x] **Step 2: 页头按 Tab 分支**

- [x] **Step 3: 加 `myEditsList()` 与空态 / 错误态**

- [x] **Step 4: 接线卡片回调与删除确认弹窗**

- [x] **Step 5: 检查**

```powershell
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" tools/typecheck-player.mjs player
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" tools/offline-test.mjs
```

预期：typecheck 无 diagnostics；离线测试全绿（`checkNoLegacyColors` 会扫 `pages/Index.ets`，**不许出现十六进制颜色**）。

- [x] **Step 6: 提交**

```powershell
git add entry/src/main/ets/pages/Index.ets
git commit -m "feat(我的剪辑): 首页新增「行程库 / 我的剪辑」双 Tab 与作品列表"
```

---

## Task 10: 全量验证与真机验收

**Files:** 无（只跑命令、记录结论）

- [x] **Step 1: 离线纯函数测试**

```powershell
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" tools/offline-test.mjs
```

预期：全绿，无回归。

- [x] **Step 2: 四个 group 的类型检查**

```powershell
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" tools/typecheck-player.mjs player
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" tools/typecheck-player.mjs bridge
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" tools/typecheck-player.mjs export
& "C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe" tools/typecheck-player.mjs home
```

预期：四条都无 diagnostics、退出码 0。

- [ ] **Step 3: 真机验收（`hdc list targets` 非空时）**

> **2026-10-18 实测：`hdc list targets` 输出 `[Empty]`，没有连接任何设备，本节全部未执行。**
> Task 1–9 的自动化门禁（离线纯函数测试 197/197、四组类型检查 0 诊断、`hvigorw assembleHap` BUILD SUCCESSFUL）
> 在此日期全部通过，但下面这几条**只有真机能验**，不得据自动化结果推断为通过。

按 spec 第 6 节的三条「未验证」，逐条记录结论：

| # | 验收项 | 通过标准 | 失败时的处置 |
|---|---|---|---|
| 1 | **L1 就地覆写**（最高优先级，整个覆盖方案的地基） | 跨会话对上次 `albumUri` 写入成功；系统相册里**条目数量不变**、内容换成新成片、**没有第二份** | 走 spec 4.6 的 L2 / L3 降级链，回到用户重新裁决 |
| 2 | **▶ 拉起系统播放器** | 点 ▶ → 系统拉起能播 `video/mp4` 的应用并播放该成片 | **直接删掉 ▶**，不补 App 内播放（spec 4.10，用户已裁决 m00216） |
| 3 | **导出成功 toast** | 相册写入完成后 2 秒内出现「已保存到相册」 | 修 toast 触发点 |

另外必须手工验证的路径：

- 从「我的剪辑」点卡片 → 剪辑页模板 / 分段 / 水印 / 播放头**全套**回到导出那一刻；
- 改一版再导出 → 弹「要覆盖这条作品吗？」→ 选覆盖 → 列表**同一条**更新，相册**不出现第二份**；
- 从「行程库」进、该行程已有作品 → 弹「这趟行程已经导出过 N 条…」；
- 该行程无记录 → **不弹**，直接导出；
- 删掉源素材让 `tripId` 重编号 → 从「我的剪辑」进 → 弹「原始行程素材已不在」，两个出口都可用；
- 在系统相册删掉成片 → 卡片降级（封面置灰 + 「相册里的视频已被删除」），▶ 禁用，「重新剪辑」仍可用；
- 未授予 `READ_IMAGEVIDEO` → 记录**不判孤儿**。

- [ ] **Step 4: 提交验收记录（如有代码修正）**

```powershell
git add -A
git commit -m "fix(我的剪辑): 真机验收修正"
```

---

## 附：任务依赖

```
Task 1 (EditRecord 纯模型)
  ├─▶ Task 2 (还原纯函数)
  ├─▶ Task 3 (持久化 + EditHistoryService)
  │     ├─▶ Task 4 (导出覆盖 + 记录落盘)
  │     │     └─▶ Task 6 (剪辑页集成) ◀── Task 5 (CoreBridge 还原)
  │     └─▶ Task 8 (HomeViewModel)  ─▶ Task 9 (首页双 Tab)
  └─▶ Task 7 (EditRecordCard) ─────▶ Task 8
Task 5 依赖 Task 2
Task 10 依赖全部
```
