# 剪单「作品库」实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把成片的主存从系统图库搬进 App 私有空间 —— 导出落成 `filesDir/exports/` 下的一个 `mp4` + 同名 `json` + 同名 `jpg`；列表直接列目录；还原判定从「行程级」降到「片段级」；「保存到相册」降级成一个显式动作。

**Architecture:** 作品 = 一个目录项。**没有第二层数据** —— 记录与成片都在 App 空间里，App 对两者都有完全控制权，因此不需要受控权限、不需要 `TRUNC` 就地覆写、不需要孤儿检测。sidecar 记的是**实际送进 native 的四条轨道**（有序、含重复的文件名），所以还原判定是精确差集、素材装配是逐位复现，**不依赖 `ffmpegPolicy`**。合成中间态留在 `cacheDir`（native 的 concat 副本与 JS 的素材落地副本都写在 `outputPath` 同级，必须隔离在作品库之外）。

**Tech Stack:** HarmonyOS ArkTS (API 26, stage model) · ArkUI 声明式 UI · `@ohos.file.fs` 本地文件 · hypium（真机）+ `tools/offline-test.mjs`（离线纯函数）+ `tools/typecheck-player.mjs`（纯逻辑层类型检查）

**Spec:** `docs/superpowers/specs/2026-10-20-app-local-work-library-design.md`（rev.2，已批准）

---

## Global Constraints

- **ArkTS 严格模式**：不用 `any`、不用无类型对象字面量、所有形参与返回值显式标注类型。类实例字段必须有初值。
- **纯函数模块**（可被 `tools/offline-test.mjs` 跑的）**禁止**导入 `@ohos.*` / `@kit.*`，只能相对导入。离线测试遇到裸导入会**直接抛错**，不静默跳过。
- **新增离线用例文件**必须**同时**登记在两处：`tools/offline-test.mjs` 的 `SUITES`（`:38-46`）与 `entry/src/ohosTest/ets/test/List.test.ets`。
- **新增模块**必须手动加进 `tools/typecheck-player.mjs` 对应 group 的 `deps` —— 该脚本的 `GROUPS` **不会**自动跟随 import。
- **UI 文件禁止硬编码颜色**：一律 `$r('app.color.<token>')`。`tools/offline-test.mjs` 的 `checkNoLegacyColors` 会扫描 `UI_FILES` 白名单，新 UI 文件要加进该列表。
- **反目标（做了就算失败）**：绝不自动删除用户的作品（磁盘紧张也不静默清理）；绝不静默用错素材（片段对不上宁可报错）；绝不留下半截文件（写入必须原子）；绝不假装图库那份归 App 管。
- **`exports/` 目录必须只放成品**：合成中间态一律留在 `cacheDir`，因为 native 会写 `<outputPath>.front.concat.mp4` 之类、JS 会写 `input_<ts>_<n>.mp4`，它们的名字都像作品文件。
- 验证命令（默认三条都要绿）：
  - `node tools/offline-test.mjs`（基线：209/209 通过，收集模块 17 个）
  - `node tools/typecheck-player.mjs <group>`（group ∈ `player|bridge|export|home`；基线：各组诊断 0 条）
  - ArkUI 页面/组件的构建与真机预览在 DevEco Studio 里做，计划里逐条标了验收点。
- 提交信息沿用仓库风格：`feat(<scope>): <中文描述>` / `test(<scope>): <中文描述>` / `refactor(<scope>): <中文描述>`。

---

## Review Focus（复核者重点看）

1. **sidecar 是坏 JSON / 被截断**时，该作品应**降级显示**（可看、可存相册、可删、**不可重剪**），列表其余条目完全不受影响 —— 而不是整页报错或整表清空。
2. **`exports/` 里混进非作品文件**（native 的 `<id>.mp4.tmp.front.concat.mp4`、JS 的 `input_<ts>_<n>.mp4` 残留，进程被杀时必然出现）时，它们**不得**出现在列表里。
3. **同一个源片段文件名在现场扫描结果里出现多次**时，重建轨道必须**确定性地**取同一个（取时间戳最早的那条），不能随扫描顺序变化。
4. **没授 `READ_IMAGEVIDEO`** 时点作品，必须提示「需要相册权限才能重新剪辑」并给授权入口，**绝不能**报「原始行程素材已不在」—— 那句话是假的，而「列表免权限可看」正是本次改动的核心收益。
5. **覆盖导出后**，封面必须换成新成片的首帧（不能停在上一版画面），且 `createdAt` 保留、`exportedAt` 刷新。

---

## Task 1: `WorkMeta` 纯模型与文件名契约

**Files:**
- Create: `entry/src/main/ets/model/WorkMeta.ets`
- Create: `entry/src/ohosTest/ets/test/WorkMetaCases.ets`
- Create: `entry/src/ohosTest/ets/test/WorkMeta.test.ets`
- Modify: `entry/src/ohosTest/ets/test/List.test.ets`
- Modify: `tools/offline-test.mjs:38-46`（`SUITES` 加一行）

**Interfaces:**
- Consumes: 无（纯模块，只依赖内置 `Date` / `JSON`，以及 `./Models` 的 `PlaybackState` 类型 —— **`PlaybackState` 在 `Models.ets:337`，不在 `TripModels.ets`**）
- Produces（后续 Task 3/4/6/7/8/9 依赖）:
  - `export const WORK_META_SCHEMA_VERSION: number = 1`
  - `export class WorkTracks { front: Array<string>; back: Array<string>; side: Array<string>; side2: Array<string> }`（全部带初值 `[]`）
  - `export class WorkMeta { schemaVersion, id, createdAt, exportedAt, tripTitle, tripStartTs, tripEndTs, tracks: WorkTracks, templateId: string, playback: PlaybackState, watermarkEnabled: boolean, segmentCount: number, durationMs: number }` —— **`playback` 非空**，默认 `{ playheadMs: 0, segments: [] }`；`templateId` 存 `string` 而不是 `TemplateId`（sidecar 是外部数据，可能含未知值，转换交给 Task 3）
  - `export function parseWorkMeta(raw: string): WorkMeta | undefined` —— 永不抛错；坏 JSON / 缺 `id` / **缺 `playback` 或 `playback.segments` 非数组** 一律返回 `undefined`
  - `export function serializeWorkMeta(meta: WorkMeta): string`
  - `export function isWorkVideoFileName(name: string): boolean` —— 严格匹配 `^SmartDrive_Export_\d{8}_\d{6}(_\d+)?\.mp4$`
  - `export function workIdFromFileName(name: string): string` —— 去掉扩展名
  - `export function exportTimeFromFileName(name: string): number` —— 解析 `YYYYMMDD_HHMMSS`，失败返回 0
  - `export function findWorkByTrip(metas: Array<WorkMeta>, tripTitle: string, tripStartTs: number): WorkMeta | undefined` —— **软匹配**，只用于「问不问覆盖」；按 `exportedAt` 取最新的一条
  - `export function workSortKey(meta: WorkMeta | undefined, fileName: string): number` —— 有 meta 用 `exportedAt`，否则用文件名时间戳
  - `export function formatExportTime(exportedAt: number): string` / `formatClockDuration(durationMs: number): string` / `formatRecordSummary(segmentCount: number, durationMs: number): string` / `templateSlotCount(templateId: string): number` / `formatRecordSlotCount(templateId: string): string` / `templateAspectRatio(templateId: string): number` —— **从 `entry/src/main/ets/model/EditRecord.ets` 原样搬过来，行为不许变**（Task 12 才删原文件）

- [ ] **Step 1: 先写失败用例**

创建 `entry/src/ohosTest/ets/test/WorkMetaCases.ets`，照 `entry/src/ohosTest/ets/test/TripFormatCases.ets:1-11` 的 `makeCase` 模式（`TimelineCase` / `expectString` / `expectNumber` / `expectTrue` / `expectFalse` / `firstError` 来自 `./TestSupport`）。导出 `export function workMetaCases(): Array<TimelineCase>`。

**必须覆盖的用例（每条一个 `makeCase`）:**

| 用例名 | 断言 |
|---|---|
| 空串返回 undefined | `expectTrue(parseWorkMeta('') === undefined, '空串')` |
| 坏 JSON 返回 undefined | `expectTrue(parseWorkMeta('{oops') === undefined, '坏 JSON')` |
| 缺 id 返回 undefined | `expectTrue(parseWorkMeta('{"tripTitle":"x"}') === undefined, '缺 id')` |
| 缺 playback 返回 undefined | `expectTrue(parseWorkMeta('{"id":"w1"}') === undefined, '缺 playback')` |
| playback.segments 非数组返回 undefined | `expectTrue(parseWorkMeta('{"id":"w1","playback":{"segments":1}}') === undefined, 'segments 非数组')` |
| 合法条目补齐默认值 | 喂 `{"id":"w1","playback":{"playheadMs":0,"segments":[]}}`：`tracks.front.length === 0`、`exportedAt === 0`、`schemaVersion === 1`、`templateId === ''` |
| 序列化→解析往返保真 | `parseWorkMeta(serializeWorkMeta(m))` 的 `id` / `exportedAt` / `templateId` 相等 |
| **轨道顺序与重复往返不丢** | `m.tracks.front = ['a.mp4','b.mp4','a.mp4']`，往返后仍严格等于该数组（**Review Focus 3 的前置**） |
| 作品视频名严格匹配 | `expectTrue(isWorkVideoFileName('SmartDrive_Export_20261018_210400.mp4'), '标准名')` |
| **带后缀的作品名也匹配** | `expectTrue(isWorkVideoFileName('SmartDrive_Export_20261018_210400_1.mp4'), '撞名后缀')` |
| **native 的 concat 残留不匹配** | `expectFalse(isWorkVideoFileName('SmartDrive_Export_20261018_210400.mp4.tmp.front.concat.mp4'), 'concat 残留')`（**Review Focus 2**） |
| **JS 的素材落地副本不匹配** | `expectFalse(isWorkVideoFileName('input_1759296000000_0.mp4'), '素材副本')`（**Review Focus 2**） |
| sidecar / 封面不是视频 | `expectFalse(isWorkVideoFileName('SmartDrive_Export_20261018_210400.json'), 'json')` 与 `..._210400.jpg` |
| 空串与乱码不匹配 | `expectFalse(isWorkVideoFileName(''), '空串')`、`expectFalse(isWorkVideoFileName('SmartDrive_Export_2026.mp4'), '位数不足')` |
| 取作品 id | `expectString(workIdFromFileName('SmartDrive_Export_20261018_210400.mp4'), 'SmartDrive_Export_20261018_210400', 'id')` |
| 从文件名取导出时刻 | 用例内先 `const d = new Date(2026, 9, 18, 21, 4, 0)`，再 `expectNumber(exportTimeFromFileName('SmartDrive_Export_20261018_210400.mp4'), d.getTime(), '时刻')` —— **不要把时区相关的字面量写死** |
| 文件名时间戳非法返回 0 | `expectNumber(exportTimeFromFileName('SmartDrive_Export_99999999_999999.mp4'), 0, '非法')` 或按实现判为非法月/日/时，断言 `0` |
| 软匹配命中同标题同起点 | `findWorkByTrip([m], '10月1日 周三', 1759296000000)?.id === 'w1'` |
| 软匹配取最近一条 | 同标题同起点两条，`exportedAt` 大者胜出 |
| 软匹配不命中返回 undefined | 起点差 1ms → `undefined` |
| 软匹配标题为空直接不命中 | `findWorkByTrip([m], '', 1759296000000) === undefined` |
| 排序键：有 meta 用 exportedAt | `workSortKey(m, 'anything.mp4') === m.exportedAt` |
| 排序键：无 meta 用文件名时刻 | `workSortKey(undefined, 'SmartDrive_Export_20261018_210400.mp4')` 等于上一条算出的时刻 |
| 展示格式化沿用旧值 | `formatExportTime(0) === '导出时间未知'`、`formatClockDuration(32000) === '00:32'`、`formatRecordSummary(2, 32000) === '2 段 · 00:32'`、`templateSlotCount('T5') === 1`、`formatRecordSlotCount('T5') === '1 机位'`、`formatRecordSlotCount('TX') === ''` |

- [ ] **Step 2: 跑用例确认失败**

Run: `node tools/offline-test.mjs`
Expected: FAIL —— 报找不到 `entry/src/ohosTest/ets/test/WorkMetaCases.ets`

- [ ] **Step 3: 实现 `entry/src/main/ets/model/WorkMeta.ets`**

字段与类型严格照 spec 3.2。`parseWorkMeta` 照 `EditRecord.parseEditRecords`（`entry/src/main/ets/model/EditRecord.ets:110`）的容错风格逐字段收敛类型，但**返回单条**而不是数组。`isWorkVideoFileName` 用 `RegExp` 严格匹配；**不要**用「`.mp4` 结尾且不含 `.tmp`」这类宽松规则。

- [ ] **Step 4: 建 hypium 包装与登记**

`entry/src/ohosTest/ets/test/WorkMeta.test.ets` 照 `entry/src/ohosTest/ets/test/EditRestore.test.ets` 原样改写（`describe('WorkMeta.pureFunctions')` + 遍历 `workMetaCases()`）。
`List.test.ets` 加 `import workMetaTest from './WorkMeta.test'` 与调用。
`tools/offline-test.mjs` 的 `SUITES` 加 `{ path: 'entry/src/ohosTest/ets/test/WorkMetaCases.ets', exportName: 'workMetaCases' }`。

- [ ] **Step 5: 跑用例确认通过**

Run: `node tools/offline-test.mjs`
Expected: PASS —— 通过数 = 209 + 本任务新增用例数，`全部通过 ✓`

- [ ] **Step 6: 提交**

```bash
git add entry/src/main/ets/model/WorkMeta.ets entry/src/ohosTest/ets/test/WorkMetaCases.ets entry/src/ohosTest/ets/test/WorkMeta.test.ets entry/src/ohosTest/ets/test/List.test.ets tools/offline-test.mjs
git commit -m "feat(works): 新增 WorkMeta 纯模型与作品文件名契约"
```

---

## Task 2: 前提修正 —— `ClipSegment` 带上源片段文件名

**Files:**
- Modify: `entry/src/main/ets/model/Models.ets:22-28`（`ClipSegment` 加字段）、`:431-439`（`tripFromSnapshot` 填充）
- Modify: `entry/src/main/ets/service/ExportManager.ets:56`（`snapshotToLegacyClips` 用真名）
- Test: `entry/src/ohosTest/ets/test/EditRestoreCases.ets`

**Interfaces:**
- Consumes: `DvrMeta.fileName`（`entry/src/main/ets/model/TripModels.ets:6`）
- Produces:
  - `interface ClipSegment { clipId: string; camera: CameraPosition; uri: string; fileName: string; timestampMs: number; durationSec: number }` —— Task 3 的 `collectWorkTracks` 靠它把 URI 反查回文件名
  - `tripFromSnapshot(snapshot: TripSnapshot): Trip` 保留每个片段的 `fileName`

- [ ] **Step 1: 先写失败用例**

在 `entry/src/ohosTest/ets/test/EditRestoreCases.ets` 的 `editRestoreCases()` 里加两条：

```typescript
cases.push(makeCase('tripFromSnapshot 保留源片段文件名', () => {
  const live = makeLive()
  const clip = new DvrMeta()
  clip.fileName = 'DVR_LoopRecording_2026-10-01_13-28-18_front_camera.mp4'
  clip.uri = 'file://media/Photo/1/IMG_1/DVR_LoopRecording_2026-10-01_13-28-18_front_camera.mp4'
  clip.camera = 'Front'
  clip.timestamp = 1759296000000
  live.clips = [clip]
  const trip = tripFromSnapshot(live)
  return expectString(trip.tracks[CameraPosition.FRONT].segments[0].fileName,
    clip.fileName, '文件名')
}))

cases.push(makeCase('tripFromSnapshot 的空文件名保持空串', () => {
  const live = makeLive()
  const clip = new DvrMeta()
  clip.uri = 'file://media/Photo/1/IMG_1/x.mp4'
  clip.camera = 'Front'
  clip.timestamp = 1759296000000
  live.clips = [clip]
  const trip = tripFromSnapshot(live)
  return expectString(trip.tracks[CameraPosition.FRONT].segments[0].fileName, '', '空文件名')
}))
```

文件顶部 import 需补 `tripFromSnapshot`、`CameraPosition`（来自 `../../../main/ets/model/Models`）与 `DvrMeta`（来自 `../../../main/ets/model/TripModels`）。

- [ ] **Step 2: 跑用例确认失败**

Run: `node tools/offline-test.mjs`
Expected: FAIL —— `ClipSegment` 上不存在 `fileName`（类型错误或 `undefined`）

- [ ] **Step 3: 实现**

`entry/src/main/ets/model/Models.ets`：`ClipSegment` 加 `fileName: string`；`tripFromSnapshot` 里那个对象字面量加 `fileName: clip.fileName`。
`entry/src/main/ets/service/ExportManager.ets:56`：`clip.fileName = \`${segment.clipId}.mp4\`` 改成 `clip.fileName = segment.fileName`。

**注意**：`Models.ets` 是纯模块，只能相对导入 —— 不要为了让 `fileName` 通过而引入任何 `@ohos.*`。

- [ ] **Step 4: 跑用例与类型检查确认通过**

Run: `node tools/offline-test.mjs`
Expected: PASS
Run: `node tools/typecheck-player.mjs bridge` 与 `node tools/typecheck-player.mjs export`
Expected: 各 0 条诊断

- [ ] **Step 5: 提交**

```bash
git add entry/src/main/ets/model/Models.ets entry/src/main/ets/service/ExportManager.ets entry/src/ohosTest/ets/test/EditRestoreCases.ets
git commit -m "feat(model): ClipSegment 保留源片段文件名"
```

---

## Task 3: `WorkRestore` —— 轨道记录、片段级判定、逐位重建

**Files:**
- Create: `entry/src/main/ets/model/WorkRestore.ets`
- Create: `entry/src/ohosTest/ets/test/WorkRestoreCases.ets`
- Create: `entry/src/ohosTest/ets/test/WorkRestore.test.ets`
- Modify: `entry/src/ohosTest/ets/test/List.test.ets`
- Modify: `tools/offline-test.mjs:38-46`（`SUITES` 加一行）

**Interfaces:**
- Consumes: `WorkTracks` / `WorkMeta`（Task 1）；`ClipSegment.fileName`（Task 2）；`DvrMeta`、`ExportComposeRequest`、`TripSnapshot`（`./TripModels`）；`ExportSnapshot`、`normalizeTemplateIdValue`、`tripFromSnapshot`（`./Models`，全部已导出）
- Produces（Task 6/9 依赖）:
  - `export function collectWorkTracks(clips: Array<DvrMeta>, request: ExportComposeRequest): WorkTracks` —— 把 request 四条轨道的 URI 按顺序反查回 `DvrMeta.fileName`；**URI 查不到就放空串**（宁可判缺失，也不静默跳过）
  - `export function collectTrackClipNames(tracks: WorkTracks): Array<string>` —— 四条轨道合并去重，过滤空串
  - `export function findMissingClipNames(tracks: WorkTracks, liveFileNames: Array<string>): Array<string>` —— 返回缺失的文件名，**按首次出现顺序**；空串一律算缺失
  - `export class RebuiltTracks { front: Array<string>; back: Array<string>; side: Array<string>; side2: Array<string>; missing: Array<string> }`
  - `export function rebuildTrackUris(tracks: WorkTracks, liveClips: Array<DvrMeta>): RebuiltTracks` —— **逐位**复现每条轨道（含重复）；同名多份时取 `timestamp` 最小的那条；找不到的进 `missing`
  - `export function buildRestoredTripSnapshot(meta: WorkMeta, liveClips: Array<DvrMeta>): TripSnapshot` —— `id` = `trip-restored-<meta.id>`，`durationSec` **取自 `meta.durationMs / 1000`**（不是从片段累加），`clips` 是命中的片段并集（按 timestamp 升序），`previewCamera` / `previewUri` 从并集里挑第一个非空的
    - **`timeline` 留空数组**：`buildTimeline` 在 `entry/src/main/ets/service/TimelineService.ets:58`，那个模块导入了 `libsmartdrive_exporter.so` 与 `./CoreApiContract`，**不是纯模块**，本文件不能引。由 Task 9 的 `CoreBridge` 在拿到快照后填 `live.timeline = buildTimeline(live.clips)`
  - `export function exportSnapshotFromWorkMeta(meta: WorkMeta, live: TripSnapshot): ExportSnapshot` —— 把 sidecar 还原成 `restoreEditorStateFromSnapshot` 需要的那份 `ExportSnapshot`：`trip` 用 `tripFromSnapshot(live)`、`selectedTemplateId` 用 `normalizeTemplateIdValue(meta.templateId)`（`Models.ets:289` 已导出）、`playback` 直接取 `meta.playback`、`brand.watermarkEnabled` 取 `meta.watermarkEnabled`。**Task 9 靠它，不要自己在 `CoreBridge` 里拼**

- [ ] **Step 1: 先写失败用例**

创建 `entry/src/ohosTest/ets/test/WorkRestoreCases.ets`（导出 `workRestoreCases()`），照 Task 1 的 `makeCase` 模式。写两个构造器：`makeClips(entries: Array<[string, string, number]>): Array<DvrMeta>`（`[fileName, camera, timestamp]`）与 `makeTracks(front, back, side, side2)`。

**必须覆盖的用例:**

| 用例名 | 断言 |
|---|---|
| `collectWorkTracks` 按顺序反查文件名 | request 的 `frontUris = [uriA, uriB]` → `tracks.front` 严格等于 `['a.mp4','b.mp4']` |
| `collectWorkTracks` 保留重复 | `frontUris = [uriA, uriB, uriA]` → `tracks.front` 长度为 3 且第 3 项等于第 1 项 |
| `collectWorkTracks` 查不到的 URI 放空串 | `frontUris = [uriUnknown]` → `tracks.front[0] === ''` |
| 四轨合并去重 | front `['a','a']` + side `['a','b']` → `collectTrackClipNames` 长度 2 |
| 差集：全部命中为空 | `findMissingClipNames(tracks, ['a.mp4','b.mp4']).length === 0` |
| **差集：缺中间片段被检出** | tracks.front `['a','b','c']`，live 只有 `['a','c']` → 返回 `['b.mp4']`（**这是 1.2 那条静默错的回归测试**） |
| 差集：缺最早片段也被检出 | live 缺 `a` → 返回含 `a.mp4` |
| 差集：空串算缺失 | tracks.front `['']`，live 任意 → 返回 `['']` |
| 差集保持首次出现顺序 | tracks 为 `['c','a']` 且都缺 → 返回 `['c.mp4','a.mp4']` |
| 重建：逐位复现顺序与重复 | front `['a','b','a']` → 结果 `front` 长度为 3、`[0] === [2]`、`[1] !== [0]` |
| **重建：同名多份取时间戳最早** | live 有两条 `a.mp4`（timestamp 2 与 1，URI 不同）→ 结果取 timestamp 1 那条的 URI（**Review Focus 3**） |
| 重建：结果与 live 输入顺序无关 | 把 live 数组倒序再跑一次，`RebuiltTracks` 四轨完全相同（**Review Focus 3**） |
| 重建：缺的进 missing 且不出现在轨道里 | front `['a','b']` 缺 `b` → `missing` 含 `b.mp4`，`front` 长度为 1 |
| 合成快照的 durationSec 取自 meta | `meta.durationMs = 32000` → `snapshot.durationSec === 32`（**不是片段累加值**） |
| 合成快照的 id 稳定可复现 | 同 `meta.id` 跑两次 → 同一个 `id` |
| 合成快照的 clips 是命中并集且升序 | live 乱序输入 → `snapshot.clips` 的 `timestamp` 单调不减 |
| 合成快照的 timeline 留空 | `expectNumber(snapshot.timeline.length, 0, 'timeline 留空')`（由 Task 9 的 CoreBridge 填） |
| `exportSnapshotFromWorkMeta` 的模板走归一化 | `meta.templateId = 'T3'` → `snapshot.selectedTemplateId === TemplateId.T3` |
| `exportSnapshotFromWorkMeta` 的未知模板回落到默认 | `meta.templateId = 'ZZ'` → `snapshot.selectedTemplateId === TemplateId.T5`（`normalizeTemplateIdValue` 的行为） |
| `exportSnapshotFromWorkMeta` 透传 playback 与水印 | `meta.playback.playheadMs` 与 `meta.watermarkEnabled` 原样出现在结果里 |

- [ ] **Step 2: 跑用例确认失败**

Run: `node tools/offline-test.mjs`
Expected: FAIL —— 找不到 `WorkRestoreCases.ets`

- [ ] **Step 3: 实现 `entry/src/main/ets/model/WorkRestore.ets`**

纯模块，只相对导入 `./WorkMeta` / `./TripModels` / `./Models`。同名多份的取舍：先按 `timestamp` 升序、再按 `uri` 字典序排一次，取第一条 —— 这样结果与输入顺序无关。

- [ ] **Step 4: 建 hypium 包装与登记**

`WorkRestore.test.ets` 照 `EditRestore.test.ets` 写；`List.test.ets` 与 `tools/offline-test.mjs` 的 `SUITES` 各加一条。

- [ ] **Step 5: 跑用例确认通过**

Run: `node tools/offline-test.mjs`
Expected: PASS

- [ ] **Step 6: 提交**

```bash
git add entry/src/main/ets/model/WorkRestore.ets entry/src/ohosTest/ets/test/WorkRestoreCases.ets entry/src/ohosTest/ets/test/WorkRestore.test.ets entry/src/ohosTest/ets/test/List.test.ets tools/offline-test.mjs
git commit -m "feat(works): 新增片段级还原判定与轨道重建"
```

---

## Task 4: `WorkStore` —— 作品库的文件系统层

**Files:**
- Create: `entry/src/main/ets/service/WorkStore.ets`
- Modify: `tools/typecheck-player.mjs`（`export` 与 `home` 两个 group 的 `deps` 各加一行）

**Interfaces:**
- Consumes: `WorkMeta` / `parseWorkMeta` / `serializeWorkMeta` / `isWorkVideoFileName` / `workIdFromFileName`（Task 1）
- Produces（Task 6/7/8/9/10 依赖）:
  - `export class WorkEntry { id: string; videoPath: string; coverPath: string; meta: WorkMeta | undefined; sortKey: number }`
  - `export class WorkStore { static getInstance(): WorkStore; setContext(context: common.UIAbilityContext | null): void }`
  - `exportsDir(): string` —— `${filesDir}/exports`，不保证存在
  - `async list(): Promise<Array<WorkEntry>>` —— 目录不存在返回 `[]`；只收 `isWorkVideoFileName` 为真的项；按 `sortKey` 倒序
  - `async readMeta(id: string): Promise<WorkMeta | undefined>`
  - `async writeMeta(meta: WorkMeta): Promise<boolean>` —— 先写 `<id>.json.tmp` 再替换；失败返回 `false`
  - `async moveIntoLibrary(sourcePath: string, id: string): Promise<boolean>` —— 把合成产物移成 `<id>.mp4`（目标已存在则先 unlink）
  - `async deleteWork(id: string): Promise<boolean>` —— 删 `.mp4` / `.json` / `.jpg`，任一不存在不报错
  - `async freeBytes(): Promise<number>` —— `statvfs.getFreeSize(exportsDir)`；取不到返回 `-1`

> `writeCoverFrom` **不在本任务**：它要用 Task 5 拆出来的 `extractFirstFrameToPath`，由 Task 7 补上。

- [ ] **Step 1: 写实现**

无离线用例（本模块导入 `@ohos.file.fs` / `@ohos.file.statvfs` / `@ohos.app.ability.common`，按 Global Constraints 不能进离线桩）。`list()` 里对每个视频项：`coverPath` = 同名 `.jpg`（`fs.accessSync` 探存在性，不存在给空串），`meta` = `readMeta` 的结果（`undefined` 即降级卡片），`sortKey` = `workSortKey(meta, fileName)`。

`moveIntoLibrary` 的跨目录搬运：`cacheDir` 与 `filesDir` 同属 App 沙盒，`fs.rename` 可用；**若真机上 `rename` 拒绝覆盖已存在文件**，退化成 `unlink` + `rename`。这条兜底写进注释。

- [ ] **Step 2: 类型检查**

Run: `node tools/typecheck-player.mjs export`
Expected: 0 条诊断
Run: `node tools/typecheck-player.mjs home`
Expected: 0 条诊断

- [ ] **Step 3: 提交**

```bash
git add entry/src/main/ets/service/WorkStore.ets tools/typecheck-player.mjs
git commit -m "feat(works): 新增作品库文件系统层 WorkStore"
```

---

## Task 5: 首帧抽取拆成两层

**Files:**
- Modify: `entry/src/main/ets/service/ExportNativeService.ets:100-175` 附近（`resolveThumbnailCachePath` / `extractFirstFrameByService`）

**Interfaces:**
- Produces:
  - `export async function extractFirstFrameToPath(sourceUri: string, targetPath: string, sourceAspectRatio: number): Promise<boolean>` —— 抽首帧写到**指定路径**，成功 `true`；任何失败 `false`（绝不抛）
  - `export async function extractFirstFrameByService(sourceUri: string, cacheDir: string, cacheKey: string, sourceAspectRatio: number = 0): Promise<string>` —— **签名与行为完全不变**（命中 `isUsableThumbnail` 直接返回旧路径），行程库封面还在用它

- [ ] **Step 1: 实现**

把 `extractFirstFrameByService` 的 `AVImageGenerator` → `PixelMap` → JPEG 那段原样挪进 `extractFirstFrameToPath`；`extractFirstFrameByService` 变成「算路径 → 命中缓存则返回 → 否则调 `extractFirstFrameToPath` → 成功返回路径、失败返回 `''`」。`isImagePath` 分支保持在 `extractFirstFrameByService` 里（今天的行为是图片直接返回原路径）。

**为什么要拆**：今天输出路径被 `resolveThumbnailCachePath` 写死成 `${cacheDir}/thumb_v3_<key>.jpg`，而且命中缓存就返回旧文件 —— 覆盖导出时不会重抽，卡片会永远停在上一版首帧。

- [ ] **Step 2: 类型检查**

Run: `node tools/typecheck-player.mjs export` 与 `node tools/typecheck-player.mjs home`
Expected: 各 0 条诊断

- [ ] **Step 3: 提交**

```bash
git add entry/src/main/ets/service/ExportNativeService.ets
git commit -m "refactor(export): 首帧抽取拆成抽到指定路径与带缓存两层"
```

---

## Task 6: 导出产出落进作品库

**Files:**
- Modify: `entry/src/main/ets/service/ExportManager.ets`（`ExportJobRecord`、`start`、`run`、删 `persistRecord`）
- Modify: `entry/src/main/ets/NativeExportManager.ets:9-11`（参数改名）
- Modify: `entry/src/main/ets/pages/Editor.ets:624-730`（`startNativeExportTask` / `chooseOverwrite` / `launchExport` 改成传 `workId`）

**Interfaces:**
- Consumes: `WorkStore`（Task 4）、`collectWorkTracks`（Task 3）、`WorkMeta` / `findWorkByTrip` / `workIdFromFileName`（Task 1）、`buildExportFileName` 的既有逻辑
- Produces:
  - `ExportManager.start(snapshot: ExportSnapshot, context: common.UIAbilityContext, overwriteWorkId?: string): Promise<ExportJobId>` —— **第三参从 `overwriteTargetUri` 改成 `overwriteWorkId`**（文件基名）
  - `startNativeExport(snapshot, context, onEvent, overwriteWorkId?: string)`（`entry/src/main/ets/NativeExportManager.ets`）
  - `Editor` 的 `this.overwriteCandidate: WorkMeta | undefined`（替换原来的 `EditRecord`）

- [ ] **Step 1: 改 `run()` 的产出路径与落盘顺序**

`run()` 里：

1. `const workId = record.overwriteWorkId.length > 0 ? record.overwriteWorkId : buildExportFileName()`（去掉 `.mp4` 后缀，作为基名）
2. **合成前查空间**：对 `request` 的四条 URI 各 `fs.stat` 求字节和 `sourceBytes`，调 `WorkStore.getInstance().freeBytes()`；`free < Math.max(512 * 1024 * 1024, sourceBytes * 3)` → `throw new Error('存储空间不足，无法导出')`。3 倍是因为合成期间同时存在 native 的轨道 concat 副本、JS 侧落地的素材副本、以及成品本身。
3. `outputPath = ${cacheDir}/${workId}.mp4.tmp`（**继续用 cacheDir** —— native 会把 `<outputPath>.front.concat.mp4` 之类写在同级，绝不能落进 `exports/`）
4. 合成成功 → `await store.moveIntoLibrary(outputPath, workId)`
5. 构造 `WorkMeta`：`id = workId`、`createdAt` 在覆盖时沿用旧的（`await store.readMeta(workId)` 取）、`exportedAt = Date.now()`、`tripTitle/tripStartTs/tripEndTs` 取 `snapshot.trip`、`tracks = collectWorkTracks(clips, request)`、`templateId = snapshot.selectedTemplateId`、`playback = snapshot.playback`、`watermarkEnabled = snapshot.brand.watermarkEnabled`、`segmentCount = snapshot.playback.segments.length`、`durationMs = Math.round(exportDurationSec(...) * 1000)`
6. `await store.writeMeta(meta)` —— 失败只记日志，**导出仍报成功**（mp4 已经是作品本体，报失败是撒谎）
7. 成功事件文案改成 `导出完成：${workId}` 与 `已保存：${workId}`；`recordTerminalEvent` / `notify` 照旧
8. 删掉 `persistRecord`（`:399-446`）与 `saveVideoToAlbum` 的调用（方法体保留给 Task 10 复用，先移出主流程）
9. `saveVideoToAlbum` 里那个 `fs.OpenMode.TRUNC` 的就地覆写分支删掉 —— 覆盖不再经过相册

**封面（`writeCoverFrom`）本任务先不接**，由 Task 7 补上调用。

- [ ] **Step 2: 改 `Editor` 的覆盖入口**

`startNativeExportTask`（`:624`）：把「读 `EditHistoryService.list()` + `recordMatchesTrip` + `recordsForTrip`」整段换成 `const entries = await WorkStore.getInstance().list()`，再 `const metas = entries.map(e => e.meta).filter(m => m !== undefined)`，用 `findWorkByTrip(metas, this.tripSnapshot.tripTitle, this.tripSnapshot.startTs)` 找目标（**软匹配，只决定问不问**）。

`this.recordId` 改名为 `this.workId`（**本任务只改名与改覆盖目标，`resolveRestore` 的还原逻辑留给 Task 9**）：有 `workId` 时目标是 `metas.find(m => m.id === this.workId)`，否则是软匹配到的那条。`overwriteCandidate` 类型改成 `WorkMeta | undefined`。`chooseOverwrite`（`:717`）传的是 `candidate ? candidate.id : ''`。`overwritePromptText`（`:725`）的两条分支暂时都保留（`this.workId.length > 0` / `overwriteCount`）。

- [ ] **Step 3: 类型检查**

Run: `node tools/typecheck-player.mjs export`
Expected: 0 条诊断

- [ ] **Step 4: 手动核对 exports/ 的干净性**

在真机/模拟器上导出一次，确认 `filesDir/exports/` 下**只有** `<id>.mp4` / `<id>.json` / `<id>.jpg` 三个文件，没有 `input_*.mp4`、没有 `*.concat.mp4`。这一条对应 Review Focus 2 的运行时验证。

- [ ] **Step 5: 提交**

```bash
git add entry/src/main/ets/service/ExportManager.ets entry/src/main/ets/NativeExportManager.ets entry/src/main/ets/pages/Editor.ets
git commit -m "feat(export): 导出产出落进 App 私有作品库"
```

---

## Task 7: 导出时生成封面

**Files:**
- Modify: `entry/src/main/ets/service/WorkStore.ets`（补 `writeCoverFrom`）
- Modify: `entry/src/main/ets/service/ExportManager.ets`（在 `run()` 里接上调用）

**Interfaces:**
- Consumes: `extractFirstFrameToPath`（Task 5）、`WorkStore`（Task 4）、`templateAspectRatio`（Task 1）
- Produces:
  - `WorkStore.writeCoverFrom(sourceVideoPath: string, id: string, aspectRatio: number): Promise<boolean>` —— 写 `exports/<id>.jpg`
  - `exports/<id>.jpg`，覆盖导出时**重新抽取**

- [ ] **Step 1: 在 `WorkStore` 里实现 `writeCoverFrom`**

`extractFirstFrameToPath(sourceVideoPath, \`${exportsDir()}/${id}.jpg.tmp\`, aspectRatio)`，成功则替换成 `<id>.jpg`，失败则清掉 `.tmp` 并返回 `false`。

**覆盖时必须重抽**：因为文件名（= 作品 id）不变，用任何基于文件名的缓存 key 都会命中旧图 —— 这里刻意不走 `isUsableThumbnail` 那条缓存路径，每次都真抽。

- [ ] **Step 2: 在 `ExportManager.run()` 里接上调用**

`moveIntoLibrary` 成功之后、`writeMeta` 之前：

```typescript
await WorkStore.getInstance().writeCoverFrom(`${store.exportsDir()}/${workId}.mp4`, workId,
  templateAspectRatio(snapshot.selectedTemplateId))
```

失败只记日志，**不阻断导出** —— 没有 jpg 就是卡片回落到占位图。

- [ ] **Step 3: 类型检查**

Run: `node tools/typecheck-player.mjs export`
Expected: 0 条诊断

- [ ] **Step 4: 手动验收覆盖刷新（Review Focus 5）**

真机：导出作品 A → 记下卡片封面 → 进剪辑页改一处（换模板或改分段）→ 导出并选「覆盖」→ 回列表，确认封面**变了**，且卡片上的「导出时间」刷新、作品在列表里仍只有一条。

- [ ] **Step 5: 提交**

```bash
git add entry/src/main/ets/service/WorkStore.ets entry/src/main/ets/service/ExportManager.ets
git commit -m "feat(export): 导出时生成封面首帧"
```

---

## Task 8: 列表链路改成「列目录」

**Files:**
- Modify: `entry/src/main/ets/viewmodel/HomeViewModel.ets`（`refreshMyEdits` / `getMyEditsState` / `deleteSelectedRecords` / `openEditorFromRecordRoute`；删 `resolveMyEditsCovers` / `isCoverUsable` / `resolveMyEditsOrphans` / `probeAlbumUri` / `updateCoverPath` 调用）
- Modify: `entry/src/main/ets/components/EditRecordCard.ets` → 改名 `WorkCard.ets`（`@Prop record: EditRecord` 改成 `@Prop entry: WorkEntry`）
- Modify: `entry/src/main/ets/pages/Index.ets`（渲染、`recordCardKey`、封面取值、删除确认文案）
- Modify: `tools/typecheck-player.mjs`（`home` group 的 `deps` **追加** `WorkMeta.ets` / `WorkRestore.ets` / `WorkStore.ets`；`EditRecord.ets` / `EditHistoryService.ets` **本任务先留着**，Task 12 才删）

**Interfaces:**
- Consumes: `WorkStore.list()` / `deleteWork()`（Task 4）
- Produces:
  - `HomeViewModel.refreshMyEdits(context)` —— 改为 `await WorkStore.getInstance().list()` 后一次性通知，**不再有异步补封面/补孤儿两个后台任务**
  - `MyEditsViewState` 精简为 `{ entries: Array<WorkEntry>; isLoading: boolean; errorText: string; selectionMode: boolean; selectedEntryIds: Array<string> }` —— `coverPaths` / `orphanIds` / `unknownIds` 三个字段删除
  - `HomeViewModel.openEditorFromWorkRoute(entry: WorkEntry): HomeRouteRequest` —— `params: { workId: entry.id }`，**不再传 `tripId`**
  - `HomeViewModel.playWork(entry: WorkEntry, context): Promise<string>` —— 打开 `entry.videoPath`

- [ ] **Step 1: 改 `HomeViewModel`**

`refreshMyEdits` 变成一次 `WorkStore.list()` + 一次 `notifyStateChanged`。删除 `resolveMyEditsCovers`（`:392-446`）、`isCoverUsable`（`:373-386`）、`resolveMyEditsOrphans`（`:454-492`）、`probeAlbumUri`（`:494-516`），以及 `isRecordOrphan` / `isRecordOrphanUnknown`。删除路径只调 `WorkStore.deleteWork(id)`。

- [ ] **Step 2: 改卡片组件**

`EditRecordCard.ets` 改名 `WorkCard.ets`：`@Prop entry: WorkEntry`。封面取 `entry.coverPath`，空则回落 `fallbackCoverUri`。新增 `@Prop canReedit: boolean`（= `entry.meta !== undefined`）：为假时「重新剪辑」按钮置灰，并按 spec 4.11 保留「保存到相册」与删除。`orphan` prop 删除。

- [ ] **Step 3: 改 `Index.ets`**

`recordCardKey` 改成 `${entry.id}_${entry.coverPath}_${selected}${mode}${canReedit}`。空态文案不变。删除确认弹窗文案改成：「只会从「我的剪辑」移除，相册里的副本不会被删掉」—— 因为 App 空间那份是真删，而相册那份 App 删不掉（没有 `WRITE_IMAGEVIDEO`）。把 `WorkCard.ets` 加进 `tools/offline-test.mjs` 的 `UI_FILES` 白名单。

- [ ] **Step 4: 验证**

Run: `node tools/typecheck-player.mjs home`
Expected: 0 条诊断
Run: `node tools/offline-test.mjs`
Expected: PASS（`checkNoLegacyColors` 也要绿）
DevEco 构建 + 真机预览验收点：① 有作品时列表正常渲染封面与元信息；② **删掉某作品的 `.json` 后重进列表**，该卡片降级显示（有封面、有导出时间、按钮置灰），其余卡片不受影响（**Review Focus 1**）；③ 手工在 `exports/` 放一个 `input_1.mp4`，列表**不出现**新卡片（**Review Focus 2**）。

- [ ] **Step 5: 提交**

```bash
git add entry/src/main/ets/viewmodel/HomeViewModel.ets entry/src/main/ets/components/WorkCard.ets entry/src/main/ets/components/EditRecordCard.ets entry/src/main/ets/pages/Index.ets tools/typecheck-player.mjs tools/offline-test.mjs
git commit -m "feat(works): 我的剪辑列表改为直接列作品目录"
```

---

## Task 9: 还原链路 —— 片段级校验与逐位重建

**Files:**
- Modify: `entry/src/main/ets/bridge/CoreBridge.ets`（`restoreEditorState` 重写、加 `isPermissionGranted()`、`createLibraryState` 记权限）
- Modify: `entry/src/main/ets/viewmodel/EditorViewModel.ets`（`hydrateFromRecord` → `hydrateFromWork`）
- Modify: `entry/src/main/ets/pages/Editor.ets:144-192`（`recordId` → `workId`，`resolveRestore` 重写）
- Modify: `entry/src/main/ets/model/Models.ets`（**删** `snapshotMatchesTrip`）
- Modify: `entry/src/ohosTest/ets/test/EditRestoreCases.ets`（**删**三条 `snapshotMatchesTrip` 用例与它的 import）
- Modify: `tools/typecheck-player.mjs`（`bridge` group 的 `deps` 加 `WorkMeta.ets` / `WorkRestore.ets` / `WorkStore.ets`）

**Interfaces:**
- Consumes: `WorkStore.readMeta`（Task 4）、`findMissingClipNames` / `rebuildTrackUris` / `buildRestoredTripSnapshot`（Task 3）
- Produces:
  - `CoreBridge.isPermissionGranted(): boolean` —— `createLibraryState` 里记录；**这是权限三态判定的唯一依据**
  - `CoreBridge.restoreEditorStateFromLive(live: TripSnapshot, meta: WorkMeta): EditorStateModel` —— 直接收装配好的快照，**不走 `this.trips.get`**，也**不把合成快照注册进 `this.trips`**
  - `EditorViewModel.isPermissionGranted(): boolean` —— 转发 `this.bridge.isPermissionGranted()`
  - `EditorViewModel.allLibraryClips(): Array<DvrMeta>` —— 把 `CoreBridge` 全部行程的 `clips` 摊平成一个数组
  - `EditorViewModel.hydrateFromWork(live: TripSnapshot, meta: WorkMeta): EditorHydrateResult`
  - `Editor.resolveRestore(workId)` 的三态出口见 Step 3

- [ ] **Step 1: 改 `CoreBridge`**

`createLibraryState(permissionGranted, context)` 里记下 `this.libraryPermissionGranted = permissionGranted`，加 `public isPermissionGranted(): boolean`。

新增 `restoreEditorStateFromLive(live: TripSnapshot, meta: WorkMeta): EditorStateModel`，四步：

1. `live.timeline = buildTimeline(live.clips)` —— **必须做**。`buildEditorState`（`:698`）把 `activeSnapshot.timeline` 直接赋给 `this.tripTimeline`，而 Task 3 的 `buildRestoredTripSnapshot` 刻意把 `timeline` 留空（`TimelineService` 非纯，它引不了）。不填的话剪辑页时间轴是空的，模板选择与机位切换全废。
2. `const stored = exportSnapshotFromWorkMeta(meta, live)`（Task 3）。
3. `const restored = restoreEditorStateFromSnapshot(stored, live, \`${live.id}_restore_${Date.now()}\`, '已还原历史剪辑')`。
4. `return this.applyRestoredState(restored, live)`。

`applyRestoredState` 一行不改 —— 它已经用 `live.durationSec` 建时间轴、算 `isRawFull`。**合成快照不注册进 `this.trips`。**

`restoreEditorState(tripId, recordJson)`（`:827`）与 `snapshotMatchesTrip` 一起删。

- [ ] **Step 2: 改 `EditorViewModel`**

`hydrateFromRecord(tripId, recordJson)` → `hydrateFromWork(live: TripSnapshot, meta: WorkMeta)`：调 `this.bridge.restoreEditorStateFromLive(live, meta)`，`tripSnapshot` 直接用传进来的 `live`，`exportSessionSeed = \`${live.id}_${Date.now()}\``。`resolveTripIdByTitleStartTs` 删除。另加两个转发方法：`isPermissionGranted()` 与 `allLibraryClips()`（后者遍历 `CoreBridge` 的全部行程把 `clips` 摊平）。

- [ ] **Step 3: 重写 `Editor.resolveRestore`**

```typescript
private async resolveRestore(workId: string): Promise<void>
```

顺序：

1. `const meta = await WorkStore.getInstance().readMeta(workId)`；
2. `meta === undefined` → **降级态**：`applyHydrateResult(this.viewModel.hydrate(workId))` 走白纸，弹「这条作品的剪辑参数已丢失，无法重新剪辑」（可复用现有 `driftVisible` 弹窗的样式）；
3. `!this.viewModel.isPermissionGranted()` → **未授权态**：白纸 + 弹「需要相册权限才能重新剪辑」+ 授权出口。授权出口复用首页那套：`abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, REQUIRED_MEDIA_PERMISSIONS)`，授权成功后重新跑一次 `resolveRestore(workId)`。**绝不判「素材已不在」**（**Review Focus 4**）；
4. 有权限：`const liveClips = this.viewModel.allLibraryClips()`（新增，从 `CoreBridge.trips` 摊平所有 `DvrMeta`）；
   `const missing = findMissingClipNames(meta.tracks, liveClips.map(c => c.fileName))`；
5. `missing.length > 0` → **素材已不在态**：白纸 + 弹「原始行程素材已不在，这次剪辑无法还原」，文案里带上缺失数量与涉及的机位名，出口「当作新剪辑打开」/「返回」；
6. 否则 `const live = buildRestoredTripSnapshot(meta, liveClips)` → `applyHydrateResult(this.viewModel.hydrateFromWork(live, meta))`，并记下 `this.workId = workId`。

`onCreate`（`:146`）读参数从 `params.recordId` 改成 `params.workId`；`this.recordId` 字段改名 `this.workId`。

- [ ] **Step 4: 验证**

Run: `node tools/offline-test.mjs`
Expected: PASS（用例数比 Task 3 后少 3 条 —— 删掉的 `snapshotMatchesTrip` 三条）
Run: `node tools/typecheck-player.mjs bridge`
Expected: 0 条诊断
DevEco 构建 + 真机预览验收点：① 正常作品点进去，模板/分段/水印/播放头全套还原，**分段没被冲掉**；② 从系统相册删掉某个源 DVR 片段后再点进去，弹「素材已不在」；③ **撤掉相册权限**后点进去，弹的是权限提示而不是「素材已不在」。

- [ ] **Step 5: 提交**

```bash
git add entry/src/main/ets/bridge/CoreBridge.ets entry/src/main/ets/viewmodel/EditorViewModel.ets entry/src/main/ets/pages/Editor.ets entry/src/main/ets/model/Models.ets entry/src/ohosTest/ets/test/EditRestoreCases.ets tools/typecheck-player.mjs
git commit -m "feat(editor): 还原判定改为片段级并区分权限三态"
```

---

## Task 10: 「保存到相册」变成显式动作

**Files:**
- Create: `entry/src/main/ets/service/AlbumExport.ets`
- Modify: `entry/src/main/ets/service/ExportManager.ets`（删掉 `saveVideoToAlbum`）
- Modify: `entry/src/main/ets/pages/Index.ets`（卡片按钮接线）
- Modify: `entry/src/main/ets/components/WorkCard.ets`（加按钮）
- Modify: `tools/typecheck-player.mjs`（`home` group 的 `deps` 加 `AlbumExport.ets`）

**Interfaces:**
- Consumes: `showAssetsCreationDialog` + `copyExportFileData` 的既有实现（`entry/src/main/ets/service/ExportManager.ets:294-389`）
- Produces:
  - `export async function saveWorkToAlbum(context: common.UIAbilityContext, entry: WorkEntry, onProgress: (percent: number) => void): Promise<string>` —— 成功返回 `''`，失败返回给用户看的文案
  - 不记录相册 URI（App 不再管理相册那份）

- [ ] **Step 1: 抽出 `saveWorkToAlbum`**

把 `ExportManager.saveVideoToAlbum` 里「`showAssetsCreationDialog` → 拷字节 → 进度回调」那段搬进新模块，去掉 `overwriteTargetUri` 参数与 `TRUNC` 分支（覆盖不再经过相册），源文件改成 `entry.videoPath`。从 `ExportManager` 里删掉 `saveVideoToAlbum`。

- [ ] **Step 2: 接线**

`WorkCard` 加「保存到相册」按钮 → `Index` 调 `saveWorkToAlbum` → 期间显示进度浮层 → 完成 `showToast('已保存到相册')`，失败 `showToast(错误文案)`。

- [ ] **Step 3: 验证**

Run: `node tools/typecheck-player.mjs home` 与 `node tools/typecheck-player.mjs export`
Expected: 各 0 条诊断
DevEco 构建 + 真机验收：点「保存到相册」→ 出现系统保存对话框 → 选位置 → toast 成功 → 系统图库里能看到该成片；**再点一次**会产生第二条相册条目（这是预期的 —— 相册那份是用户主动存的副本，App 不管）。

- [ ] **Step 4: 提交**

```bash
git add entry/src/main/ets/service/AlbumExport.ets entry/src/main/ets/service/WorkStore.ets entry/src/main/ets/service/ExportManager.ets entry/src/main/ets/pages/Index.ets entry/src/main/ets/components/WorkCard.ets
git commit -m "feat(works): 保存到相册改为显式动作"
```

---

## Task 11: 导出后引导跳列表

**Files:**
- Create: `entry/src/main/ets/constants/PendingNavigation.ets`（模块级 pending 标记）
- Modify: `entry/src/main/ets/pages/Editor.ets:694-701`（toast 文案与跳转）
- Modify: `entry/src/main/ets/pages/Index.ets:98-102`（`onPageShow` 消费 pending）

**Interfaces:**
- Produces:
  - `export function requestOpenMyEdits(): void` / `export function consumeOpenMyEdits(): boolean` —— 模块级布尔，与 `Editor.ets:200` 的 `requestPreviewSeek` 是同一个模式

- [ ] **Step 1: 实现 pending 模块**

一个模块级的 `boolean` + 两个函数。不引任何 `@ohos.*`（纯模块，可离线跑）。

- [ ] **Step 2: 接线**

`Editor.launchExport` 成功后：`this.showToast('已保存 · 查看作品')`，并 `requestOpenMyEdits()`。点 toast 时 `router.back()`（toast 的点击处理沿用页面现有 toast 结构；若现有 toast 不可点，改成 2 秒后自动回首页 + 切 Tab，由实现者按现有 `toastText` / `toastVisible` 结构选一种）。
`Index.onPageShow` 改成：先 `if (consumeOpenMyEdits()) { this.switchTab(1); return }`，再保留原有的 `if (this.activeTab === 1) refresh`。

- [ ] **Step 3: 验证**

Run: `node tools/typecheck-player.mjs home`
Expected: 0 条诊断
DevEco 构建 + 真机验收：导出成功 → 看到「已保存 · 查看作品」→ 回到首页时停在「我的剪辑」Tab，且新作品在最上面。

- [ ] **Step 4: 提交**

```bash
git add entry/src/main/ets/constants/PendingNavigation.ets entry/src/main/ets/pages/Editor.ets entry/src/main/ets/pages/Index.ets
git commit -m "feat(export): 导出成功后引导跳转我的剪辑"
```

---

## Task 12: 清理旧记录机制

**Files:**
- Delete: `entry/src/main/ets/model/EditRecord.ets`
- Delete: `entry/src/main/ets/service/EditHistoryService.ets`
- Delete: `entry/src/ohosTest/ets/test/EditHistoryCases.ets`、`EditHistory.test.ets`
- Modify: `entry/src/main/ets/service/PreferencesService.ets`（删 `loadEditRecords` / `saveEditRecords` / `isEditRecordsDurable` / `KEY_EDIT_RECORDS`）
- Modify: `entry/src/main/ets/viewmodel/EditorViewModel.ets`、`entry/src/main/ets/pages/Editor.ets`、`entry/src/main/ets/pages/Index.ets`（清掉残留 import 与 `overwritePromptText` 里 `recordId` 的分支）
- Modify: `entry/src/ohosTest/ets/test/List.test.ets`、`tools/offline-test.mjs`、`tools/typecheck-player.mjs`

**Interfaces:**
- Produces: 无新接口。`pref_edit_records` 这个 key **停止读写但不删除**（spec 4.10：清除不可逆，等新版稳定后再单独清）。

- [ ] **Step 1: 删除**

删上面列出的文件与方法。`Editor.overwritePromptText`（`:725`）合并成一条分支（覆盖目标已在 Task 6 改成 `WorkMeta`，这里把 `overwriteCount` 与 `workId` 两条分支统一）。清掉 `EditorViewModel` / `Editor` / `Index` 里所有指向 `EditRecord` / `EditHistoryService` 的 import 与残留字段。

- [ ] **Step 2: 全量验证**

Run: `node tools/offline-test.mjs`
Expected: PASS，且收集模块数比基线少（`EditRecord.ets` / `EditHistoryService.ets` 已不在依赖图里）
Run: `node tools/typecheck-player.mjs player && node tools/typecheck-player.mjs bridge && node tools/typecheck-player.mjs export && node tools/typecheck-player.mjs home`
Expected: 四组各 0 条诊断
DevEco 构建 + 真机验收：整机冒烟 —— 行程库能扫出行程 → 进剪辑页 → 导出 → 列表出现新作品 → 点进去还原 → 改一处 → 覆盖导出 → 封面刷新且列表仍只一条 → 保存到相册 → 删除作品（相册那份还在）。

- [ ] **Step 3: 提交**

```bash
git add entry/src/main/ets/model/EditRecord.ets entry/src/main/ets/service/EditHistoryService.ets entry/src/main/ets/service/PreferencesService.ets entry/src/main/ets/viewmodel/EditorViewModel.ets entry/src/main/ets/pages/Editor.ets entry/src/main/ets/pages/Index.ets entry/src/ohosTest/ets/test/EditHistoryCases.ets entry/src/ohosTest/ets/test/EditHistory.test.ets entry/src/ohosTest/ets/test/List.test.ets tools/offline-test.mjs tools/typecheck-player.mjs
git commit -m "refactor(works): 移除 preferences 记录表与孤儿检测"
```

**不要用 `git add -A`** —— 工作区里可能有 `.device/` 之类的真机验收产物，会被一起带进提交。

---

## 遗留待办（不在本计划内）

- **风险 1（最高优先级）**：沙盒 mp4 能否交给系统播放器。真机验证；读不到就按 spec 4.11 去掉 ▶。
- **风险 3**：`statvfs.getFreeSize` 在沙盒路径上的行为。
- **风险 6**：`DvrScannerService.parseDvrFileName` 的 native 与 JS 两条路径产出的文件名是否一致 —— 这决定 Task 9 的判定是否成立，**应在 Task 9 开工前先验**。
- **风险 7**：`module.json5` 里 `READ_MEDIA` / `WRITE_MEDIA` 自 API 22 起已废弃，值得顺手清理。
