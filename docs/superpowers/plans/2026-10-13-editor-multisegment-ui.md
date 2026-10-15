# 剪辑页多片段 UI 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把剪辑页从「单区间 + 深色三强调色」改成「多片段 + 纸白外壳」，每段独立倍速与声音，导出按段生效。

**Architecture:** 新增纯函数模块 `model/SegmentModel.ets` 承载全部片段算法（落刀切分、段数/段长上限、成片时长换算），用 `tools/offline-test.mjs` 离线 TDD；`EditorStateModel` 用 `segments` 取代单区间与全局倍速/静音；页面拆成三个 ArkUI 组件；导出契约扩成「一串带参数的区间」，native 侧 `napi_init.cpp` + `export_engine.cpp` 逐段渲染。

**Tech Stack:** HarmonyOS ArkTS（API 22，compatibleSdkVersion 26.0.0）、Hypium 1.0.26、Node 离线测试桩（复用 DevEco 自带 tsc）、C++ NAPI + FFmpeg（`entry/src/main/cpp`）。

**Spec:** `docs/superpowers/specs/2026-10-13-editor-multisegment-ui-design.md`

## Global Constraints

- 全部验证命令在仓库根目录执行。下文 `NODE` 指 `C:\Users\gzr\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe`。
- 当前基线（改动前必须复现）：`NODE tools/offline-test.mjs` → `离线纯函数测试：82/82 通过`；`NODE tools/typecheck-player.mjs` → `无类型错误`。
- 纯逻辑模块（`model/SegmentModel.ets`、`model/Models.ets`、`model/AppState.ets`、`model/TripModels.ets`、`media/*.ets`、`viewmodel/EditorViewModel.ets` 里被离线收集到的部分）**不得 import `@ohos.*` / `@kit.*`**：`tools/offline-test.mjs:93-107` 遇到裸导入会直接抛错，不静默跳过。
- 新增纯函数用例文件必须**同时**登记到两处，否则设备端与离线端会漂移：`tools/offline-test.mjs` 的 `SUITES`（`:39-43`）与 `entry/src/ohosTest/ets/test/List.test.ets`（配一个 `*.test.ets` hypium 包装，模式照抄 `entry/src/ohosTest/ets/test/TimelineMath.test.ets`）。
- 颜色一律走 `$r('app.color.<name>')`。页面与组件里**不得**出现十六进制色值（Task 9 有守卫）。
- ArkTS 严格模式：禁 `any`，函数与字段写显式类型，对象字面量必须有已声明的接口/类类型。
- 无新依赖：`oh-package.json5` 的 `dependencies` 保持为空，`devDependencies` 只留 `@ohos/hypium: 1.0.26`。
- **本沙箱跑不了 hvigor 全量构建**（它要在工作区外创建 symlink，被沙箱 + Windows 权限拒绝），`entry/src/ohosTest` 的 hypium 用例也跑不了（`hdc list targets` 为空）。因此 ArkUI 组件与页面（Task 8、9）的验收只能靠 DevEco Studio 构建 + 真机预览，计划里已标明；纯逻辑一律靠离线桩验证。
- **预览必须所见即所得**：每段的倍速与静音不仅要进导出，**也要进播放器预览**（Task 10）。只改导出、预览不动 = 没做完。
- **native / ffmpeg 交互排在最后**（Task 11、12），且必须在代码里写清备注：这两个 task 会动 `entry/src/main/cpp/`，当前**导出本身是坏的**（用户实测导不出来），修 native 之前先把其余部分全部做完。
- 复用既有工具，不堆屎山：片段算法一律进 `model/SegmentModel.ets`（纯函数、离线可测），页面只做渲染与转发；颜色一律走资源令牌；不要在 `Editor.ets` 里再写业务判断。
- 每个 Task 结束提交一次。

## Review Focus

以下五类输入 spec 没写、但没有一条 task 的测试覆盖它 —— 每条都已在「归属 task」里配了测试：

1. **反复点 ✕ 想把段全关掉**：期望最后一段关不掉（`canToggleSegment` 为假），因此「0 个启用段 → 导出空文件」这条路径不存在。测试在 Task 4。
2. **在 0 秒或片尾落刀**：期望拒绝并提示，不产生 0 秒段。
3. **源片总时长不是整数秒**（如 59.4s）：最后一段终点不被截断，成片时长不出现负值。
4. **段长刚好 2.000 秒时落刀**：按「≥2 秒」放行，不因浮点误差误拒。
5. **单段 + 倍速 2.0× 导出**：`expectedDurationSec` 必须是源时长 ÷ 2。

---

## File Structure

**新建**

| 文件 | 职责 |
|---|---|
| `entry/src/main/ets/model/SegmentModel.ets` | 片段算法的唯一实现：数据结构、落刀切分、段数/段长上限、成片时长、播放跳过、倍速循环。**不依赖 @ohos** |
| `entry/src/ohosTest/ets/test/SegmentModelCases.ets` | 上述模块的用例本体（无 hypium 依赖） |
| `entry/src/ohosTest/ets/test/SegmentModel.test.ets` | hypium 包装，设备端执行同一份用例 |
| `entry/src/main/ets/components/SegmentParamRow.ets` | 参数行：段名 · 时长 · 倍速胶囊 · 声音图标 · ✕（spec §6.5） |
| `entry/src/main/ets/components/SegmentTrack.ets` | 片段轨道 + 画面区底部浮层（进度条、两端时间、剪刀）（spec §6.4、§6.6） |
| `entry/src/main/ets/components/TemplateStrip.ets` | 模板横向滚动行（spec §6.7） |

**修改**

| 文件 | 改动 |
|---|---|
| `entry/src/main/resources/base/element/color.json` | 落 17 个颜色令牌（spec §6.9） |
| `tools/offline-test.mjs` | `SUITES` 加一行；新增 `checkColorTokens()` 与 `checkNoLegacyColors()` |
| `entry/src/ohosTest/ets/test/List.test.ets` | 注册 `segmentModelTest()` |
| `entry/src/main/ets/model/AppState.ets` | `EditorStateModel` 用 `segments` 取代单区间 + 全局 `speedLabel`/`muted` |
| `entry/src/main/ets/model/Models.ets` | `createEditorStateFromSnapshot` 签名换成 `segments`；`PlaybackState` 增 `segments` |
| `entry/src/main/ets/model/TripModels.ets` | `ExportComposeRequest` 增 `segments: Array<ExportSegment>` |
| `entry/src/main/ets/service/ExportService.ets` | `buildComposeRequestByService` 产出多段 |
| `entry/src/main/ets/viewmodel/EditorViewModel.ets` | 派生：段时长文案、选中段、成片时长 |
| `entry/src/main/ets/bridge/CoreBridge.ets` | `EDITOR_SPEEDS` 加 `'0.75X'`；段操作委托给 `SegmentModel` |
| `entry/src/main/ets/media/SingleTrackController.ets` | `:1406-1416` 的倍速枚举 if/else 换成 `speedEnumForRate()`（补 1.5X） |
| `entry/src/main/ets/pages/Editor.ets` | `build()` 621-975 整段重做（spec §6） |
| `entry/src/main/cpp/napi_init.cpp` | 解析 `segments` 数组 |
| `entry/src/main/cpp/export_engine.h` / `export_engine.cpp` | 逐段 trim + 倍速 + 静音 |

---

### Task 1: 主题色板落到资源文件

**Files:**
- Modify: `entry/src/main/resources/base/element/color.json`
- Modify: `tools/offline-test.mjs`（新增 `checkColorTokens()`）

**Interfaces:**
- Produces: 下表 17 个颜色资源名。Task 8、9 通过 `$r('app.color.<name>')` 引用。

| name | 值 | | name | 值 |
|---|---|---|---|---|
| `page_bg` | `#F7F6F3` | | `text_disabled` | `#B5B0A6` |
| `card_bg` | `#FFFFFF` | | `ink` | `#111111` |
| `page_border` | `#EAE8E3` | | `amber` | `#D98324` |
| `card_border` | `#EDEAE4` | | `amber_soft` | `#FDF6EC` |
| `track_bg` | `#F4F2ED` | | `stage_bg` | `#14120F` |
| `segment_border` | `#E4E1DA` | | `stage_divider` | `#1E1B17` |
| `text_primary` | `#1C1B18` | | `segment_off_bg` | `#EFEDE8` |
| `text_secondary` | `#57534A` | | `segment_off_border` | `#E7E4DE` |
| `text_tertiary` | `#8A867D` | | | |

- [ ] **Step 1: 写失败的检查**

在 `tools/offline-test.mjs` 里加一个函数，并把它并入 `main()` 的 `failures`（照 `checkNativeContract()` 的形状：返回 `{name, ok:true}` 或 `{name, detail}`）：

```js
const REQUIRED_COLOR_TOKENS = new Map([
  ['page_bg', '#F7F6F3'], ['card_bg', '#FFFFFF'], ['page_border', '#EAE8E3'],
  ['card_border', '#EDEAE4'], ['track_bg', '#F4F2ED'], ['segment_border', '#E4E1DA'],
  ['text_primary', '#1C1B18'], ['text_secondary', '#57534A'], ['text_tertiary', '#8A867D'],
  ['text_disabled', '#B5B0A6'], ['ink', '#111111'], ['amber', '#D98324'],
  ['amber_soft', '#FDF6EC'], ['stage_bg', '#14120F'], ['stage_divider', '#1E1B17'],
  ['segment_off_bg', '#EFEDE8'], ['segment_off_border', '#E7E4DE']
])

function checkColorTokens() {
  const name = '颜色令牌齐全且取值正确'
  const raw = JSON.parse(readFileSync(join(ROOT, 'entry/src/main/resources/base/element/color.json'), 'utf8'))
  const actual = new Map((raw.color ?? []).map((item) => [item.name, String(item.value).toUpperCase()]))
  const problems = []
  for (const [token, expected] of REQUIRED_COLOR_TOKENS) {
    const got = actual.get(token)
    if (got === undefined) problems.push(`${token} 缺失`)
    else if (got !== expected) problems.push(`${token} 期望 ${expected}，实际 ${got}`)
  }
  return problems.length > 0 ? { name, detail: problems.join('; ') } : { name, ok: true }
}
```

- [ ] **Step 2: 运行，确认失败**

Run: `NODE tools/offline-test.mjs`
Expected: FAIL，出现 `✗ 颜色令牌齐全且取值正确`，明细里列出 17 个 `缺失`。

- [ ] **Step 3: 写入色板**

在 `entry/src/main/resources/base/element/color.json` 的 `color` 数组里保留现有 `start_window_background`，追加上表 17 条。格式与现有一致：`{ "name": "page_bg", "value": "#F7F6F3" }`。

- [ ] **Step 4: 运行，确认通过**

Run: `NODE tools/offline-test.mjs`
Expected: PASS，`离线纯函数测试：83/83 通过`。

- [ ] **Step 5: 提交**

```bash
git add entry/src/main/resources/base/element/color.json tools/offline-test.mjs
git commit -m "feat(ui): 落主题色板到 color.json 并加令牌守卫"
```

---

### Task 2: SegmentModel —— 数据结构、默认整段、时长换算

**Files:**
- Create: `entry/src/main/ets/model/SegmentModel.ets`
- Create: `entry/src/ohosTest/ets/test/SegmentModelCases.ets`
- Create: `entry/src/ohosTest/ets/test/SegmentModel.test.ets`
- Modify: `tools/offline-test.mjs:39-43`（`SUITES` 加一行）
- Modify: `entry/src/ohosTest/ets/test/List.test.ets`

**Interfaces:**
- Produces（全部来自 `entry/src/main/ets/model/SegmentModel.ets`，Task 3/4/5/6/7/9 都消费这些名字）：

```ts
export const MAX_SEGMENTS: number = 3
export const MIN_SEGMENT_SEC: number = 2
export const SPEED_CYCLE: Array<string> = ['0.75X', '1.0X', '1.25X', '1.5X', '2.0X']

export class Segment {
  id: number = 0
  startSec: number = 0
  endSec: number = 0
  speedLabel: string = '1.0X'
  muted: boolean = false
  enabled: boolean = true
}

export function createFullSegment(totalDurationSec: number): Array<Segment>
export function segmentDurationSec(segment: Segment): number
export function enabledSegments(segments: Array<Segment>): Array<Segment>
export function enabledCount(segments: Array<Segment>): number
export function segmentIndexAtSec(segments: Array<Segment>, sec: number): number
export function speedFactor(speedLabel: string): number
export function outputDurationSec(segments: Array<Segment>): number
```

- 语义钉死：`segments` 是**升序、互不重叠**的区间列表；段之间的空档是隐式灰段（不占 `MAX_SEGMENTS` 名额，`MAX_SEGMENTS` 只数 `enabled === true` 的段）。默认状态是 `createFullSegment(total)` 返回的**一段** `[0, total]`，`speedLabel='1.0X'`、`muted=false`、`enabled=true`、`id=0`。
- `speedFactor` 解析 `'2.0X'` → `2.0`；非法或超范围（`<0.75` 或 `>2.0`）→ `1.0`。

- [ ] **Step 1: 写失败用例**

`entry/src/ohosTest/ets/test/SegmentModelCases.ets`：

```ts
import { Segment, createFullSegment, enabledCount, outputDurationSec, segmentDurationSec,
  segmentIndexAtSec, speedFactor } from '../../../main/ets/model/SegmentModel'
import { TimelineCase, expectNumber, expectString, expectTrue, firstError } from './TestSupport'

function makeCase(name: string, run: () => string): TimelineCase {
  const item = new TimelineCase()
  item.name = name
  item.run = run
  return item
}

export function segmentModelCases(): Array<TimelineCase> {
  const cases: Array<TimelineCase> = []

  cases.push(makeCase('默认状态是一整段覆盖全片', () => {
    const segments = createFullSegment(60)
    return firstError([
      expectNumber(segments.length, 1, '段数'),
      expectNumber(segments[0].id, 0, 'id'),
      expectNumber(segments[0].startSec, 0, '起点'),
      expectNumber(segments[0].endSec, 60, '终点'),
      expectString(segments[0].speedLabel, '1.0X', '倍速'),
      expectTrue(segments[0].enabled, '默认启用'),
      expectTrue(!segments[0].muted, '默认有声')
    ])
  }))

  cases.push(makeCase('非整数片长不被截断', () => {
    const segments = createFullSegment(59.4)
    return firstError([
      expectNumber(segments[0].endSec, 59.4, '终点'),
      expectNumber(outputDurationSec(segments), 59.4, '成片时长')
    ])
  }))

  cases.push(makeCase('段时长与成片时长按倍速换算', () => {
    const segments = createFullSegment(12)
    segments[0].speedLabel = '2.0X'
    return firstError([
      expectNumber(segmentDurationSec(segments[0]), 12, '源段长'),
      expectNumber(outputDurationSec(segments), 6, '成片时长')
    ])
  }))

  cases.push(makeCase('0.75X 参与换算', () => {
    const segments = createFullSegment(12)
    segments[0].speedLabel = '0.75X'
    return firstError([
      expectNumber(speedFactor('0.75X'), 0.75, '倍速因子'),
      expectNumber(outputDurationSec(segments), 16, '成片时长')
    ])
  }))

  cases.push(makeCase('非法倍速回落 1.0', () => {
    return firstError([
      expectNumber(speedFactor('3.0X'), 1, '越界'),
      expectNumber(speedFactor('abc'), 1, '非数字')
    ])
  }))

  cases.push(makeCase('按秒定位所属段', () => {
    const segments = createFullSegment(60)
    return firstError([
      expectNumber(segmentIndexAtSec(segments, 30), 0, '段内'),
      expectNumber(segmentIndexAtSec(segments, 60), 0, '终点算最后一段'),
      expectNumber(segmentIndexAtSec(segments, -1), -1, '越界返回 -1'),
      expectNumber(enabledCount(segments), 1, '启用段数')
    ])
  }))

  return cases
}
```

`entry/src/ohosTest/ets/test/SegmentModel.test.ets`（照抄 `TimelineMath.test.ets` 的形状，只换名字）：

```ts
import { describe, it, expect } from '@ohos/hypium'
import { TimelineCase } from './TestSupport'
import { segmentModelCases } from './SegmentModelCases'

export default function segmentModelTest(): void {
  describe('SegmentModel.pureFunctions', () => {
    const cases: Array<TimelineCase> = segmentModelCases()
    cases.forEach((testCase: TimelineCase) => {
      it(testCase.name, 0, () => {
        const failure: string = testCase.run()
        expect(failure).assertEqual('')
      })
    })
  })
}
```

`tools/offline-test.mjs` 的 `SUITES` 加：

```js
  { path: 'entry/src/ohosTest/ets/test/SegmentModelCases.ets', exportName: 'segmentModelCases' }
```

`entry/src/ohosTest/ets/test/List.test.ets` 加 `import segmentModelTest from './SegmentModel.test'` 与函数体里的 `segmentModelTest()`。

- [ ] **Step 2: 运行，确认失败**

Run: `NODE tools/offline-test.mjs`
Expected: FAIL —— `找不到模块：entry/src/ohosTest/ets/test/SegmentModelCases.ets`（模块还没建）。

- [ ] **Step 3: 实现 `entry/src/main/ets/model/SegmentModel.ets`**

按上面的 Interfaces 写。要点：`outputDurationSec` 只累加 `enabled` 段，逐段 `(endSec - startSec) / speedFactor(speedLabel)`；`segmentIndexAtSec` 用 `sec >= startSec && sec <= endSec`（终点归前一段，保证边界不歧义），不在任何段内返回 `-1`；`createFullSegment` 用 `totalDurationSec <= 0 ? 1 : totalDurationSec` 兜底，避免 0 长度段。文件顶部**不得**出现 `@ohos` 导入。

- [ ] **Step 4: 运行，确认通过**

Run: `NODE tools/offline-test.mjs`
Expected: PASS，`离线纯函数测试：89/89 通过`（83 + 6 条新用例）。

- [ ] **Step 5: 提交**

```bash
git add entry/src/main/ets/model/SegmentModel.ets entry/src/ohosTest/ets/test/SegmentModelCases.ets entry/src/ohosTest/ets/test/SegmentModel.test.ets tools/offline-test.mjs entry/src/ohosTest/ets/test/List.test.ets
git commit -m "feat(segment): 片段模型的数据结构与时长换算"
```

---

### Task 3: SegmentModel —— 落刀切分与上限

**Files:**
- Modify: `entry/src/main/ets/model/SegmentModel.ets`
- Modify: `entry/src/ohosTest/ets/test/SegmentModelCases.ets`

**Interfaces:**
- Consumes: Task 2 的 `Segment`、`enabledCount`、`segmentIndexAtSec`、`MIN_SEGMENT_SEC`、`MAX_SEGMENTS`。
- Produces:

```ts
export function canSplitAt(segments: Array<Segment>, sec: number, totalDurationSec: number): boolean
export function splitSegmentAt(segments: Array<Segment>, sec: number, totalDurationSec: number): Array<Segment>
```

- 落刀规则（spec §5.3）：
  - `sec` 落在**启用段** `[a,b]` 内 → 变成 `[a,sec]` + `[sec,b]`，两段都启用，倍速与静音都继承原段。
  - `sec` 落在**灰段**（`enabled === false` 的段）内 → `[a,sec]` 仍是灰段，`[sec,b]` 变启用，参数继承原段。
  - `sec` 落在**空档**里 → 插入新段 `[sec, 下一个边界]`，启用、`1.0X`、有声；`下一个边界` = 之后第一个段的 `startSec`，没有则 `totalDurationSec`。
- 拒绝条件（`canSplitAt` 为 `false`）：`enabledCount >= MAX_SEGMENTS`；`sec <= 0`；`sec >= totalDurationSec`；切分后**任一启用段**短于 `MIN_SEGMENT_SEC`。
- 新增段的 `id` = 当前所有段 `id` 的最大值 + 1。

- [ ] **Step 1: 写失败用例**

追加到 `SegmentModelCases.ets`（补上 `canSplitAt`、`splitSegmentAt` 的 import）：

```ts
  cases.push(makeCase('启用段内落刀切成两段且时长不变', () => {
    const segments = splitSegmentAt(createFullSegment(60), 20, 60)
    return firstError([
      expectNumber(segments.length, 2, '段数'),
      expectNumber(segments[0].endSec, 20, '第一段终点'),
      expectNumber(segments[1].startSec, 20, '第二段起点'),
      expectNumber(segments[1].endSec, 60, '第二段终点'),
      expectNumber(enabledCount(segments), 2, '启用段数'),
      expectNumber(outputDurationSec(segments), 60, '成片时长不变')
    ])
  }))

  cases.push(makeCase('灰段内落刀只把后半段补回来', () => {
    const base = createFullSegment(60)
    const disabled = toggleSegmentEnabled(base, 0)
    const segments = splitSegmentAt(disabled, 20, 60)
    return firstError([
      expectNumber(segments.length, 2, '段数'),
      expectTrue(!segments[0].enabled, '前半段仍灰'),
      expectTrue(segments[1].enabled, '后半段恢复'),
      expectNumber(enabledCount(segments), 1, '启用段数')
    ])
  }))

  cases.push(makeCase('空档里落刀补到下一个边界（用户给的例子）', () => {
    let segments = splitSegmentAt(createFullSegment(59), 15, 59)
    segments = toggleSegmentEnabled(segments, 0)
    segments = splitSegmentAt(segments, 30, 59)
    segments = toggleSegmentEnabled(segments, segments[1].id)
    const after = splitSegmentAt(segments, 20, 59)
    const inserted = after.filter((item) => item.startSec === 20)
    return firstError([
      expectNumber(inserted.length, 1, '新增段数量'),
      expectNumber(inserted[0].endSec, 30, '新增段终点=下一个边界'),
      expectTrue(inserted[0].enabled, '新增段启用'),
      expectNumber(enabledCount(after), 3, '启用段数')
    ])
  }))

  cases.push(makeCase('满 3 段拒绝落刀', () => {
    let segments = createFullSegment(60)
    segments = splitSegmentAt(segments, 20, 60)
    segments = splitSegmentAt(segments, 40, 60)
    return firstError([
      expectNumber(enabledCount(segments), 3, '前置条件'),
      expectTrue(!canSplitAt(segments, 50, 60), '应拒绝'),
      expectNumber(splitSegmentAt(segments, 50, 60).length, 3, '拒绝时不改结构')
    ])
  }))

  cases.push(makeCase('切出短于 2 秒的启用段被拒绝', () => {
    const segments = splitSegmentAt(createFullSegment(60), 1, 60)
    return firstError([
      expectTrue(!canSplitAt(createFullSegment(60), 1, 60), '1 秒应拒绝'),
      expectNumber(segments.length, 1, '拒绝时不改结构')
    ])
  }))

  cases.push(makeCase('恰好 2 秒放行（边界含等号）', () => {
    return firstError([
      expectTrue(canSplitAt(createFullSegment(60), 2, 60), '起点侧 2 秒'),
      expectTrue(canSplitAt(createFullSegment(60), 58, 60), '终点侧 2 秒')
    ])
  }))

  cases.push(makeCase('0 秒与片尾落刀被拒绝', () => {
    return firstError([
      expectTrue(!canSplitAt(createFullSegment(60), 0, 60), '0 秒'),
      expectTrue(!canSplitAt(createFullSegment(60), 60, 60), '片尾'),
      expectTrue(!canSplitAt(createFullSegment(60), 61, 60), '越界')
    ])
  }))
```

- [ ] **Step 2: 运行，确认失败**

Run: `NODE tools/offline-test.mjs`
Expected: FAIL —— `SegmentModelCases.ets 转译失败` 或 `缺少导出`，因为 `canSplitAt`/`splitSegmentAt` 还不存在。

- [ ] **Step 3: 实现两个函数**

`canSplitAt` 先算 `splitSegmentAt` 的结果再比对：`enabledCount(结果) > enabledCount(输入)` 且结果里每个 `enabled` 段都不短于 `MIN_SEGMENT_SEC`。`splitSegmentAt` 在 `canSplitAt` 为假时**原样返回输入**（不改结构）。浮点比较用 `>= MIN_SEGMENT_SEC - 1e-9`，避免 `60 - 58` 这类减法误差误拒（Review Focus 第 4 条）。

- [ ] **Step 4: 运行，确认通过**

Run: `NODE tools/offline-test.mjs`
Expected: PASS，`离线纯函数测试：96/96 通过`。

- [ ] **Step 5: 提交**

```bash
git add entry/src/main/ets/model/SegmentModel.ets entry/src/ohosTest/ets/test/SegmentModelCases.ets
git commit -m "feat(segment): 落刀切分与段数段长上限"
```

---

### Task 4: SegmentModel —— ✕ 开关、倍速循环、播放跳过

**Files:**
- Modify: `entry/src/main/ets/model/SegmentModel.ets`
- Modify: `entry/src/ohosTest/ets/test/SegmentModelCases.ets`

**Interfaces:**
- Consumes: Task 2/3 的全部导出。
- Produces:

```ts
export function cycleSpeedLabel(label: string): string
export function canToggleSegment(segments: Array<Segment>): boolean
export function toggleSegmentEnabled(segments: Array<Segment>, id: number): Array<Segment>
export function setSegmentSpeed(segments: Array<Segment>, id: number, speedLabel: string): Array<Segment>
export function setSegmentMuted(segments: Array<Segment>, id: number, muted: boolean): Array<Segment>
export function playbackSkipTargetSec(segments: Array<Segment>, sec: number, totalDurationSec: number): number
export function isAllDisabled(segments: Array<Segment>): boolean
```

- `cycleSpeedLabel`：沿 `SPEED_CYCLE` 前进一格，`'2.0X'` → `'0.75X'`；入参不在表里则返回 `'1.0X'`。
- `canToggleSegment`：`enabledCount(segments) > 1` 才允许关（spec §5.7「只剩一段时 ✕ 不再生效」）。
- `toggleSegmentEnabled`：`canToggleSegment` 为假时原样返回；否则翻转目标段的 `enabled`（所以再点一次就是恢复 —— spec D13「可恢复」）。
- `playbackSkipTargetSec`：`sec` 落在启用段内返回 `sec`；落在灰段内返回该段 `endSec`；落在空档里返回空档终点（下一个段的 `startSec`，没有则 `totalDurationSec`）。播放到片尾返回 `totalDurationSec`。
- `isAllDisabled`：`enabledCount === 0`。

- [ ] **Step 1: 写失败用例**

```ts
  cases.push(makeCase('倍速按五档循环', () => {
    return firstError([
      expectString(cycleSpeedLabel('1.0X'), '1.25X', '1.0X 后'),
      expectString(cycleSpeedLabel('1.5X'), '2.0X', '1.5X 后'),
      expectString(cycleSpeedLabel('2.0X'), '0.75X', '2.0X 回绕'),
      expectString(cycleSpeedLabel('0.75X'), '1.0X', '0.75X 后'),
      expectString(cycleSpeedLabel('乱码'), '1.0X', '非法输入')
    ])
  }))

  cases.push(makeCase('只剩一段时 ✕ 不生效', () => {
    const segments = createFullSegment(60)
    return firstError([
      expectTrue(!canToggleSegment(segments), '单段不可关'),
      expectTrue(toggleSegmentEnabled(segments, 0)[0].enabled, '仍启用')
    ])
  }))

  cases.push(makeCase('✕ 变灰、再点恢复', () => {
    const two = splitSegmentAt(createFullSegment(60), 30, 60)
    const off = toggleSegmentEnabled(two, two[0].id)
    const back = toggleSegmentEnabled(off, off[0].id)
    return firstError([
      expectTrue(!off[0].enabled, '第一次关'),
      expectTrue(off[1].enabled, '邻段不受影响'),
      expectTrue(back[0].enabled, '第二次恢复'),
      expectNumber(outputDurationSec(off), 30, '关掉后成片只剩后半段')
    ])
  }))

  cases.push(makeCase('每段倍速与静音互不影响', () => {
    const two = splitSegmentAt(createFullSegment(60), 30, 60)
    const tuned = setSegmentMuted(setSegmentSpeed(two, two[1].id, '2.0X'), two[1].id, true)
    return firstError([
      expectString(tuned[0].speedLabel, '1.0X', '第一段倍速不变'),
      expectTrue(!tuned[0].muted, '第一段不受静音影响'),
      expectString(tuned[1].speedLabel, '2.0X', '第二段倍速'),
      expectTrue(tuned[1].muted, '第二段静音'),
      expectNumber(outputDurationSec(tuned), 45, '成片时长=30+15')
    ])
  }))

  cases.push(makeCase('播放跳过灰段与空档', () => {
    const two = splitSegmentAt(createFullSegment(60), 30, 60)
    const off = toggleSegmentEnabled(two, two[0].id)
    return firstError([
      expectNumber(playbackSkipTargetSec(off, 10, 60), 30, '灰段跳到段尾'),
      expectNumber(playbackSkipTargetSec(off, 40, 60), 40, '启用段原地不动'),
      expectNumber(playbackSkipTargetSec(off, 60, 60), 60, '片尾')
    ])
  }))

  cases.push(makeCase('关不到 0 个启用段（不存在空成片路径）', () => {
    let two = splitSegmentAt(createFullSegment(60), 30, 60)
    two = toggleSegmentEnabled(two, two[0].id)
    const stillTwo = toggleSegmentEnabled(two, two[1].id)
    return firstError([
      expectTrue(!canToggleSegment(two), '只剩 1 个启用段时不可再关'),
      expectTrue(stillTwo[1].enabled, '第二次关不掉'),
      expectTrue(!isAllDisabled(stillTwo), '永远至少 1 个启用段')
    ])
  }))
```

- [ ] **Step 2: 运行，确认失败**

Run: `NODE tools/offline-test.mjs`
Expected: FAIL，`SegmentModelCases.ets 转译失败`（`cycleSpeedLabel` 等未导出）。

- [ ] **Step 3: 实现这七个函数**

`setSegmentSpeed` / `setSegmentMuted` / `toggleSegmentEnabled` 都返回**新的数组**（不改入参），保持纯函数可测。`playbackSkipTargetSec` 用 `segmentIndexAtSec` 判断落点：索引 `-1` 表示空档，取「第一个 `startSec > sec` 的段的 `startSec`」，没有则 `totalDurationSec`。

- [ ] **Step 4: 运行，确认通过**

Run: `NODE tools/offline-test.mjs`
Expected: PASS，`离线纯函数测试：102/102 通过`。

- [ ] **Step 5: 提交**

```bash
git add entry/src/main/ets/model/SegmentModel.ets entry/src/ohosTest/ets/test/SegmentModelCases.ets
git commit -m "feat(segment): 段开关、倍速循环与播放跳过"
```

---

### Task 5: EditorStateModel 接入 segments

**Files:**
- Modify: `entry/src/main/ets/model/AppState.ets:70-96`
- Modify: `entry/src/main/ets/model/Models.ets:258-264`（`PlaybackState`）、`:377-410`（`createEditorStateFromSnapshot`）
- Modify: `entry/src/main/ets/viewmodel/EditorViewModel.ets:45-113`
- Modify: `entry/src/ohosTest/ets/test/ExportPayload.test.ets`

**Interfaces:**
- Consumes: `Segment`、`outputDurationSec`、`enabledSegments`（Task 2/4）。
- Produces:
  - `EditorStateModel` 删 `selectionStartSec`、`selectionEndSec`、`speedLabel`、`muted`；增 `segments: Array<Segment>`；保留 `watermarkEnabled`。
  - `PlaybackState` 删 `rangeStartMs`、`rangeEndMs`、`speedLabel`、`muted`；增 `segments: Array<ExportSegment>`（Task 6 定义）。
  - `createEditorStateFromSnapshot(tripSnapshot: TripSnapshot, exportSessionSeed: string, templateId: string, segments: Array<Segment>, watermarkEnabled: boolean, drawerExpanded: boolean, exportStatusText: string): EditorState` —— 入参是**模型层**的 `Segment`，函数内部用 `toExportSegments` 转成 `PlaybackState.segments`。
  - `EditorViewModel` 新增 `getSelectedSegment(state: EditorStateModel): Segment | undefined`、`formatSegmentDuration(segment: Segment): string`（返回 `'15s'` 形式，向上取整）、`getOutputDurationSec(state: EditorStateModel): number`。

> **依赖顺序说明**：本 Task 引用了 Task 6 才定义的 `ExportSegment`。执行顺序上**先做 Task 6 的 `ExportSegment` 定义**，或在本 Task 里先只改 `EditorStateModel`（用 `Segment`），把 `PlaybackState` 的改动留到 Task 6。推荐后者。

- [ ] **Step 1: 写失败用例**

在 `entry/src/ohosTest/ets/test/ExportPayload.test.ets` 里把四处 `createEditorStateFromSnapshot(...)` 调用的 `'1.0X', false` 换成 `createFullSegment(120)`（两段片长 120 秒的行程）。新增一条：

```ts
    it('默认整段覆盖全片', 0, () => {
      const state = createEditorStateFromSnapshot(
        buildSnapshotWithClips(2), 'session-6', 'T2', createFullSegment(120), true, true, '待导出'
      )
      expect(state.segments.length).assertEqual(1)
      expect(state.segments[0].endSec).assertEqual(120)
    })
```

- [ ] **Step 2: 运行，确认失败**

Run: `NODE tools/offline-test.mjs`
Expected: FAIL —— `entry/src/main/ets/model/Models.ets` 类型检查报 `createEditorStateFromSnapshot` 参数个数不符（`ExportPayload.test.ets` 不在离线集合里，所以真正先红的是 `Models.ets` 自身：`PlaybackState` 少了被引用的字段）。

- [ ] **Step 3: 改 `AppState.ets` 与 `Models.ets`**

`EditorStateModel`：删那四个字段，加 `segments: Array<Segment>`（从 `./SegmentModel` import）。`PlaybackState`：删 `rangeStartMs`/`rangeEndMs`/`speedLabel`/`muted`，加 `segments: Array<ExportSegment>`。`createEditorStateFromSnapshot`：按新签名写，`playback.playheadMs` 用 `Math.max(0, Math.min(playheadMs, 总源时长毫秒))`。

- [ ] **Step 4: 改 `EditorViewModel`**

`buildExportSnapshot` 不再读 `state.selectionStartSec` 等，改为把 `state.segments` 映射成 `ExportSegment` 后写进 `draft.playback.segments`。新增的三个方法按 Interfaces 实现；`formatSegmentDuration` 用 `Math.ceil(segmentDurationSec(segment))` 加 `'s'` 后缀（spec D9/D10：只写时长不写起止）。

- [ ] **Step 5: 运行，确认通过**

Run: `NODE tools/offline-test.mjs` → 预期 PASS。
Run: `NODE tools/typecheck-player.mjs` → 预期 `无类型错误`（`SingleTrackController`/`GlobalTimelineManager` 也引用了 `AppState`）。

- [ ] **Step 6: 提交**

```bash
git add entry/src/main/ets/model/AppState.ets entry/src/main/ets/model/Models.ets entry/src/main/ets/viewmodel/EditorViewModel.ets entry/src/ohosTest/ets/test/ExportPayload.test.ets
git commit -m "refactor(state): EditorStateModel 用 segments 取代单区间与全局倍速静音"
```

---

### Task 6: 导出契约扩成多段

**Files:**
- Modify: `entry/src/main/ets/model/TripModels.ets:36-50`
- Modify: `entry/src/main/ets/model/SegmentModel.ets`
- Modify: `entry/src/main/ets/service/ExportService.ets:116-155`
- Modify: `entry/src/ohosTest/ets/test/SegmentModelCases.ets`

**Interfaces:**
- Consumes: `Segment`、`enabledSegments`（Task 2）。
- Produces:

```ts
// entry/src/main/ets/model/TripModels.ets
export class ExportSegment {
  startMs: number = 0
  endMs: number = 0
  speedLabel: string = '1.0X'
  muted: boolean = false
}
// ExportComposeRequest 新增字段
segments: Array<ExportSegment> = []

// entry/src/main/ets/model/SegmentModel.ets
export function toExportSegments(segments: Array<Segment>): Array<ExportSegment>

// entry/src/main/ets/service/ExportService.ets —— 新的签名（旧的 speedLabel/muted/rangeStartMs/rangeEndMs 四个参数删掉）
export function buildComposeRequestByService(
  clips: Array<DvrMeta>,
  fileName: string,
  outputPath: string,
  expectedDurationSec: number,
  templateId: string,
  segments: Array<ExportSegment>,
  watermarkEnabled: boolean
): ExportComposeRequest
```

- `toExportSegments`：只取 `enabled` 段，按 `startSec` 升序，秒 → 毫秒用 `Math.round(sec * 1000)`。
- **过渡兼容**：`ExportComposeRequest` 的 `rangeStartMs` / `rangeEndMs` / `speedLabel` / `muted` 四个旧字段**保留**，由 `buildComposeRequestByService` 填成 `segments[0]` 的值。Task 11 让 native 优先读 `segments`；在 Task 11 完成前，导出行为等价于「只导出第一段」。

- [ ] **Step 1: 写失败用例**

追加到 `SegmentModelCases.ets`：

```ts
  cases.push(makeCase('导出只带启用段且按起点升序', () => {
    const two = splitSegmentAt(createFullSegment(60), 30, 60)
    const tuned = setSegmentMuted(setSegmentSpeed(two, two[0].id, '2.0X'), two[0].id, true)
    const out = toExportSegments(tuned)
    return firstError([
      expectNumber(out.length, 2, '段数'),
      expectNumber(out[0].startMs, 0, '第一段起点毫秒'),
      expectNumber(out[0].endMs, 30000, '第一段终点毫秒'),
      expectString(out[0].speedLabel, '2.0X', '第一段倍速'),
      expectTrue(out[0].muted, '第一段静音'),
      expectString(out[1].speedLabel, '1.0X', '第二段倍速')
    ])
  }))

  cases.push(makeCase('单段 2.0× 时成片时长是源时长的一半', () => {
    const single = createFullSegment(60)
    single[0].speedLabel = '2.0X'
    return firstError([
      expectNumber(toExportSegments(single).length, 1, '段数'),
      expectNumber(outputDurationSec(single), 30, 'expectedDurationSec 取值')
    ])
  }))

  cases.push(makeCase('灰段不进导出', () => {
    const two = splitSegmentAt(createFullSegment(60), 30, 60)
    const off = toggleSegmentEnabled(two, two[0].id)
    const out = toExportSegments(off)
    return firstError([
      expectNumber(out.length, 1, '段数'),
      expectNumber(out[0].startMs, 30000, '只剩后半段')
    ])
  }))
```

- [ ] **Step 2: 运行，确认失败**

Run: `NODE tools/offline-test.mjs`
Expected: FAIL —— `toExportSegments` 未导出。

- [ ] **Step 3: 实现**

`TripModels.ets` 加 `ExportSegment` 类与 `ExportComposeRequest.segments` 字段；`SegmentModel.ets` 加 `toExportSegments`（import `ExportSegment`，`TripModels` 是纯模块，不破坏离线约束）；`ExportService.ets` 改签名并在函数体里写 `request.segments = segments`，同时把四个旧字段填成 `segments[0]` 的值（`segments` 为空时全填 0 / `'1.0X'` / `false`）。

- [ ] **Step 4: 运行，确认通过**

Run: `NODE tools/offline-test.mjs`
Expected: PASS，`离线纯函数测试：104/104 通过`。

- [ ] **Step 5: 提交**

```bash
git add entry/src/main/ets/model/TripModels.ets entry/src/main/ets/model/SegmentModel.ets entry/src/main/ets/service/ExportService.ets entry/src/ohosTest/ets/test/SegmentModelCases.ets
git commit -m "feat(export): 导出契约扩成带参数的多段区间"
```

---

### Task 7: CoreBridge 接入片段操作

**Files:**
- Modify: `entry/src/main/ets/bridge/CoreBridge.ets:36`（`EDITOR_SPEEDS`）、`:670`、`:756`
- Modify: `entry/src/main/ets/model/AppState.ets`（`EditorStateModel` 加 `selectedSegmentId`）
- Modify: `entry/src/main/ets/viewmodel/EditorViewModel.ets`

**Interfaces:**
- Consumes: Task 2/3/4 的全部 `SegmentModel` 导出。
- Produces（`CoreBridge` 与 `EditorViewModel` 各一层，页面只调 `EditorViewModel`）：

```ts
// CoreBridge
cycleSpeed(): EditorStateModel          // 改：循环【选中段】的倍速，不再用全局 speedIndex
toggleMuted(): EditorStateModel         // 改：翻转【选中段】的 muted
splitAtPlayhead(): EditorStateModel     // 新：按 splitSegmentAt(segments, playheadSec, totalDurationSec)
toggleSegmentEnabled(id: number): EditorStateModel   // 新
selectSegment(id: number): EditorStateModel          // 新：写 selectedSegmentId

// EditorViewModel —— 同名转发
splitAtPlayhead(): EditorStateModel
toggleSegmentEnabled(id: number): EditorStateModel
selectSegment(id: number): EditorStateModel
canSplitAtPlayhead(): boolean           // 新：纯读，供剪刀置灰
```

- `EDITOR_SPEEDS`（`CoreBridge.ets:36`）在数组**首位**加 `'0.75X'`，使其与 `SegmentModel.SPEED_CYCLE` 同序。`:756` 的取模循环逻辑不用改。
- `EditorStateModel.selectedSegmentId` 默认 `0`；`splitAtPlayhead` 成功后把 `selectedSegmentId` 设为新段的 `id`；`toggleSegmentEnabled` 关掉当前选中段时把 `selectedSegmentId` 顺延到下一个启用段（没有则保持）。

> **验证说明**：`CoreBridge.ets` 导入 `@ohos.file.photoAccessHelper` 等（`:25-27`），**不在离线集合里**，`tools/typecheck-player.mjs` 也不覆盖它。本 Task 的验收 = 离线套件仍全绿 + DevEco Studio 构建通过 + 真机点按。

- [ ] **Step 1: 先跑基线**

Run: `NODE tools/offline-test.mjs`
Expected: PASS，`104/104`（改动前先确认起点干净）。

- [ ] **Step 2: 改 `EDITOR_SPEEDS` 与状态字段**

`CoreBridge.ets:36` → `['0.75X', '1.0X', '1.25X', '1.5X', '2.0X']`。`AppState.ets` 的 `EditorStateModel` 加 `selectedSegmentId: number`。`CoreBridge.createEditorState` 初始化 `segments = createFullSegment(trip.durationSec)`、`selectedSegmentId = 0`。

- [ ] **Step 3: 把 `cycleSpeed` / `toggleMuted` 改成作用于选中段**

删掉 `speedIndex` 这条全局路径（`:756` 的取模、`:670` 的 `speedLabel: EDITOR_SPEEDS[this.speedIndex]`），改成在 `segments` 上找 `selectedSegmentId` 后调 `setSegmentSpeed` / `setSegmentMuted`。倍速用 `cycleSpeedLabel`，不再走 `speedIndex`。

- [ ] **Step 4: 加四个新方法**

`splitAtPlayhead` / `toggleSegmentEnabled` / `selectSegment` 分别委托 `splitSegmentAt` / `toggleSegmentEnabled` / 直接写 `selectedSegmentId`，然后 `return` 新的 `EditorStateModel`。`EditorViewModel` 里加同名转发与 `canSplitAtPlayhead()`。

- [ ] **Step 5: 运行，确认没把离线层弄红**

Run: `NODE tools/offline-test.mjs` → 预期 PASS `104/104`。
Run: `NODE tools/typecheck-player.mjs` → 预期 `无类型错误`。

- [ ] **Step 6: 提交**

```bash
git add entry/src/main/ets/bridge/CoreBridge.ets entry/src/main/ets/model/AppState.ets entry/src/main/ets/viewmodel/EditorViewModel.ets
git commit -m "feat(bridge): 片段操作接入 CoreBridge，倍速改为按选中段循环"
```

---

### Task 8: 三个 UI 组件

**Files:**
- Create: `entry/src/main/ets/components/SegmentParamRow.ets`
- Create: `entry/src/main/ets/components/SegmentTrack.ets`
- Create: `entry/src/main/ets/components/TemplateStrip.ets`

**Interfaces:**
- Consumes: `Segment`（Task 2）、`TemplateCardModel` / `TimelineTrackModel`（`model/AppState.ets`）、Task 1 的颜色令牌。
- Produces（Task 9 按这些名字装配）：

```ts
@Component export struct SegmentParamRow {
  @Prop segment: Segment
  @Prop canToggle: boolean
  onCycleSpeed: () => void
  onToggleMute: () => void
  onToggleEnabled: () => void
}

@Component export struct SegmentTrack {
  @Prop segments: Array<Segment>
  @Prop playheadSec: number
  @Prop totalDurationSec: number
  @Prop selectedSegmentId: number
  onSelectSegment: (id: number) => void
  onScrubTo: (sec: number) => void
  onScissors: () => void
  canScissors: boolean
}

@Component export struct TemplateStrip {
  @Prop cards: Array<TemplateCardModel>
  @Prop timeline: Array<TimelineTrackModel>
  @Prop activeTemplateId: string
  onSelectTemplate: (id: string) => void
  onRejected: (message: string) => void
}
```

- 尺寸、圆角、字号、色值**逐条**照 spec §6.5（参数行）、§6.4 + §6.6（轨道与浮层）、§6.7（模板行）实现，不要自行发挥。
- 参数行内容顺序：`片段 N` · 时长 · 倍速胶囊 · 声音图标 · `✕`。倍速胶囊显示小写 x（`'1.5X'.replace('X','x')`）；默认值（`'1.0X'` 且非静音）**不做任何视觉强调**（spec §5.6）。
- 声音图标只有两个态、**无边框无文字**、点击区 32；`muted` 为真时画斜线。
- 轨道：~~段间 3vp 缝、每段独立圆角块~~ **⚠️ 2026-10-15 修订：段间不留缝、段块圆角 3**（那道缝让人以为中间丢了画面，spec D12 已作废）、选中段只换 1.5vp 琥珀描边 + 两端拖动手柄（**不铺底色**，spec D11）、灰段加删除线且 `✕` 可点回恢复。
- 浮层：底部 84vp 渐变到透明，进度条线高 2 + 圆钮 14；两端时间 11vp 等宽数字（左＝当前位置、右＝源片总时长）；控制行右侧剪刀圆钮 28。

> **验证说明**：ArkUI 组件在本沙箱**无法构建**（hvigor 需要工作区外 symlink）。本 Task 的验收 = DevEco Studio 构建通过 + 真机预览逐条对照 spec §6.4/§6.5/§6.6/§6.7 的数值。

- [ ] **Step 1: 写三个组件文件**

按上面的 Interfaces 与 spec 数值实现。三个文件都不得出现十六进制色值，一律 `$r('app.color.<name>')`。

- [ ] **Step 2: DevEco 构建**

Run: DevEco Studio → Build → Build Hap(s)/APP(s)
Expected: 构建成功，无 ArkTS 编译错误。

- [ ] **Step 3: 真机对照 spec**

在真机上逐个核对：参数行行高 40 / 元素间距 8；倍速胶囊高 26 圆角 7 描边 1 `card_border`；声音图标 20 且点击区 32；轨道高 52 圆角 9 内边距 3 底 `track_bg`；~~段间缝 3~~ **段间缝 0、段块圆角 3**（⚠️ 2026-10-15）；选中段描边 1.5 `amber`；~~手柄 6×44 圆角 3~~ **手柄＝12vp 圆点、触摸区 44×46、拖动时气泡时间实时变动**（⚠️ 2026-10-15）；灰段底 `segment_off_bg` 描边 `segment_off_border`；浮层高 84、进度线高 2、圆钮 14、剪刀圆钮 28；模板卡宽 72 间距 10、缩略图 72×46 圆角 7、禁用态整卡 40% 不透明。

- [ ] **Step 4: 提交**

```bash
git add entry/src/main/ets/components/SegmentParamRow.ets entry/src/main/ets/components/SegmentTrack.ets entry/src/main/ets/components/TemplateStrip.ets
git commit -m "feat(ui): 参数行、片段轨道与模板行三个组件"
```

---

### Task 9: Editor 页装配 + 无遗留色守卫

**Files:**
- Modify: `entry/src/main/ets/pages/Editor.ets:621-975`（`build()` 整段重做）、`:637`、`:740`
- Modify: `tools/offline-test.mjs`（新增 `checkNoLegacyColors()`）

**Interfaces:**
- Consumes: Task 8 的三个组件、Task 7 的 `EditorViewModel` 方法、Task 1 的颜色令牌。
- Produces: 页面结构按 spec §6.1～§6.3；验收标准 spec §8 第 1～11 条在本 Task 全部落地（第 6、7、9 条另需 Task 11 才算端到端）。

- [ ] **Step 1: 写失败的守卫**

在 `tools/offline-test.mjs` 加：

```js
const LEGACY_COLORS = ['#FF7A00', '#0A59F7', '#FF4444', '#F97316', '#181818', '#282828', '#333333', '#121212', '#1A1A1A']

function checkNoLegacyColors() {
  const name = '剪辑页无遗留硬编码配色'
  const problems = []
  for (const rel of ['entry/src/main/ets/pages/Editor.ets']) {
    const src = readFileSync(join(ROOT, rel), 'utf8')
    for (const color of LEGACY_COLORS) {
      if (src.toUpperCase().includes(color)) problems.push(`${rel} 仍含 ${color}`)
    }
    if (/#[0-9A-Fa-f]{6,8}/.test(src)) problems.push(`${rel} 仍含十六进制色值`)
  }
  return problems.length > 0 ? { name, detail: problems.join('; ') } : { name, ok: true }
}
```

并入 `main()` 的 `failures`。

- [ ] **Step 2: 运行，确认失败**

Run: `NODE tools/offline-test.mjs`
Expected: FAIL —— `✗ 剪辑页无遗留硬编码配色`，明细里列出 `#FF7A00`、`#181818`、`#282828` 等。

- [ ] **Step 3: 重写 `build()`**

按 spec §6.1～§6.3 重做：页面底 `page_bg`、页边距 16、播放器卡（内边距 12 / 圆角 16 / 描边 1 `card_border` / 底 `card_bg`）；顶栏高 52、返回图标 19 `text_secondary`、片名 13 单行省略、导出按钮高 32 圆角 8 左右内边距 14 底 `ink` 白字；卡内依次为画面区（`.aspectRatio(EditorViewModel.getPreviewAspectRatio(activeTemplateId))`）、`SegmentParamRow`、`SegmentTrack`，卡外是 `TemplateStrip`。删掉「剪辑模板（点击查看比例）」「播放剪辑器」「功能设置」三个分区标题。

同时：
- `:637` `Button('导出剪辑')` → `Button('导出')`（spec D15）。
- `:740` 删掉写死的 `.aspectRatio(16 / 9)`，改用 `EditorPreviewArea` 自己的比例（修 spec §3.4 的现存 bug）。
- 导出浮层转圈色 `#F97316` → `amber`，**不加成片时长**（spec D16）。
- 画面区不显示模板名、时间水印、机位计数等文案（spec D18）。
- 倍速 chip 从画面右上角撤掉（已挪进参数行）。
- `addClipMark()`（`:272-287`）**改名并重写为剪刀动作**：删掉 `if (this.clipMarks.length >= 2)` 那条上限，改调 `viewModel.splitAtPlayhead()`；满 3 段时 toast「最多只能添加3个剪辑点」，切出短于 2 秒的段时 toast「片段太短，至少 2 秒」（spec §7.1 + §5.5）。
- `undoClipMark()`（`:289-304`）与 `clipMarks` 字段、`getSegmentInfoText()`（`:344-346`）随打点式交互一起删除；撤销改由「把灰段点回启用」承担（spec §5.7）。
- 顺手确认 `EditorViewModel.getPlaybackRate`（`:181-188`）的解析区间 `0.75–2.0` 已兼容新的 `'0.75X'`，**不需要改**（spec §7.2）。

- [ ] **Step 4: 运行，确认通过**

Run: `NODE tools/offline-test.mjs`
Expected: PASS，`离线纯函数测试：105/105 通过`。

- [ ] **Step 5: DevEco 构建 + 真机走一遍验收标准**

逐条核对 spec §8 的 1～11 条（第 6 条「导出结果不含灰段」与第 7 条「倍速顺序」要等 Task 11 才端到端成立，此处先确认 UI 行为）。

- [ ] **Step 6: 提交**

```bash
git add entry/src/main/ets/pages/Editor.ets tools/offline-test.mjs
git commit -m "feat(ui): 剪辑页按纸白规格重做，去掉全部硬编码配色"
```

---

### Task 10: 预览所见即所得（每段倍速/静音进播放器 + 跳过灰段）

**Files:**
- Modify: `entry/src/main/ets/pages/Editor.ets`（把「当前段」的倍速/静音喂给 `EditorPreviewArea`）
- Modify: `entry/src/main/ets/media/SingleTrackController.ets:1406-1416`（倍速枚举映射补 1.5X）
- Modify: `entry/src/main/ets/model/SegmentModel.ets` + `entry/src/ohosTest/ets/test/SegmentModelCases.ets`

**Interfaces:**
- Consumes: `segmentIndexAtSec`、`playbackSkipTargetSec`、`speedFactor`（Task 2/4）。
- Produces:

```ts
// entry/src/main/ets/model/SegmentModel.ets
export function speedEnumForRate(rate: number): number
// 0.75→0 / 1.0→1 / 1.25→2 / 1.75→3 / 2.0→4 / 1.5→6   （media.PlaybackSpeed 的枚举值）
```

- **已确认的平台事实**：`@ohos.multimedia.media.d.ts:6252-6328` 的 `PlaybackSpeed` 里 **`SPEED_FORWARD_1_50_X = 6` 是存在的**。而 `SingleTrackController.ets:1407-1413` 的映射漏了它：`1.5` 既不 `>=1.6` 也不 `>=1.9`，于是落到 `>=1.2` 分支被当成 **1.25x** 播放。这就是「预览和导出不一致」的根源，必须补上 `>=1.4 → 6`。
- `EditorPreviewArea` 的 `@Prop speedLabel` / `@Prop muted`（`:50-51`）**不用改**：页面改成喂「播放头所在那一段」的值即可，跨段时 `@Watch` 会自然触发 `setPlaybackRate` / `setMuted`。
- 跳过灰段：页面在播放头推进时算 `playbackSkipTargetSec(segments, playheadSec, total)`，与当前值不同就 `seekGlobalPlayhead(目标)`。逻辑留在纯模块里，`GlobalTimelineManager` 不动。
  - ⚠️ **2026-10-15 作废**：预览不再按片段跳段（用户：「期望进度条可以播放整个视频，不受片段影响」）。`playbackSkipTargetSec` 已从 `SegmentModel.ets` 删除（连同它的用例），页面播放头改为连续推进整条源视频；「跳过灰段」只剩导出侧（`toExportSegments` 只取启用段）。本行仅作历史记录。

- [ ] **Step 1: 写失败用例**

追加到 `SegmentModelCases.ets`（import `speedEnumForRate`）：

```ts
  cases.push(makeCase('倍速枚举映射覆盖五档（含 1.5X）', () => {
    return firstError([
      expectNumber(speedEnumForRate(0.75), 0, '0.75X'),
      expectNumber(speedEnumForRate(1.0), 1, '1.0X'),
      expectNumber(speedEnumForRate(1.25), 2, '1.25X'),
      expectNumber(speedEnumForRate(1.75), 3, '1.75X'),
      expectNumber(speedEnumForRate(2.0), 4, '2.0X'),
      expectNumber(speedEnumForRate(1.5), 6, '1.5X 必须走 SPEED_FORWARD_1_50_X')
    ])
  }))
```

- [ ] **Step 2: 运行，确认失败**

Run: `NODE tools/offline-test.mjs`
Expected: FAIL —— `speedEnumForRate` 未导出。

- [ ] **Step 3: 实现映射并让 `SingleTrackController` 复用它**

在 `SegmentModel.ets` 实现 `speedEnumForRate`（阈值从大到小：`>=1.9→4`、`>=1.6→3`、`>=1.4→6`、`>=1.2→2`、`<=0.8→0`、否则 `1`）。`SingleTrackController.ets:1406-1416` 的那段 if/else 删掉，改成调 `speedEnumForRate(this.playbackRate)` 并 `as media.PlaybackSpeed`（`SingleTrackController` 本来就 import 了 media，加一行 `SegmentModel` 的 import 即可，不破坏离线约束 —— `SegmentModel` 是纯模块）。

- [ ] **Step 4: 页面喂当前段的参数**

`Editor.ets` 里把传给 `EditorPreviewArea` 的 `speedLabel` / `muted` 改成「`segmentIndexAtSec(segments, playheadSec)` 那一段的值」；找不到段（落在空档）时用 `'1.0X'` / `false`。播放头推进处加跳过灰段的判断。

- [ ] **Step 5: 运行，确认通过**

Run: `NODE tools/offline-test.mjs` → 预期 PASS，`离线纯函数测试：106/106 通过`。
Run: `NODE tools/typecheck-player.mjs` → 预期 `无类型错误`（这个脚本正好覆盖 `SingleTrackController`）。

- [ ] **Step 6: 真机确认所见即所得**

真机上把某一段设成 `2.0X` + 静音，另设一段 `1.5X`：预览播放时该段应明显更快/无声，且**与导出成片的观感一致**；播放头经过灰段应自动跳过去。

- [ ] **Step 7: 提交**

```bash
git add entry/src/main/ets/model/SegmentModel.ets entry/src/ohosTest/ets/test/SegmentModelCases.ets entry/src/main/ets/media/SingleTrackController.ets entry/src/main/ets/pages/Editor.ets
git commit -m "feat(preview): 预览按段应用倍速与静音，补 1.5X 枚举映射"
```

---

### Task 11: Native —— 解析 segments（暂缓）

> **暂缓说明**：本 task 与 Task 12 是唯一动 `entry/src/main/cpp/` 的部分。用户实测**当前导出是坏的**，且要求先把其余部分做完再碰 ffmpeg 交互。**执行到 Task 9 + Task 10 结束后就停，先交付 UI 与预览，再回来做这两个。**


**Files:**
- Modify: `entry/src/main/cpp/napi_init.cpp:126-135`（请求结构）、`:256-269`（解析）
- Modify: `entry/src/main/cpp/export_engine.h:10-17`

**Interfaces:**
- Consumes: Task 6 的 `ExportSegment` 字段名（`startMs` / `endMs` / `speedLabel` / `muted`）。
- Produces:

```cpp
struct NativeExportSegment {
    double startMs = 0.0;
    double endMs = 0.0;
    double speed = 1.0;
    bool muted = false;
};
// NativeExportPipelineRequest 新增
std::vector<NativeExportSegment> segments;

// export_engine.h —— runExportEnginePipeline 新增末位参数（带默认值，保持旧调用可编译）
std::string runExportEnginePipeline(const std::vector<std::string> &frontUris,
                                    const std::vector<std::string> &backUris,
                                    const std::vector<std::string> &sideUris,
                                    const std::string &templateId,
                                    double expectedDurationSec,
                                    const std::string &outputPath,
                                    double startMs = 0.0,
                                    double endMs = 0.0,
                                    const std::vector<NativeExportSegment> &segments = {});
```

- 解析规则：`segments` 属性存在且是数组时逐项读 `startMs`/`endMs`/`speedLabel`/`muted`；`speedLabel` 形如 `'1.5X'`，取数字部分，钳到 `[0.75, 2.0]`，解析失败取 `1.0`。**缺省或空数组时保持现有单区间行为**（用 `startMs`/`endMs`），保证旧调用不回归。
- 新增错误码 `EXPORT_ERR_SEGMENTS_INVALID = 1007`：数组里出现 `endMs <= startMs` 的项时返回该错误。

> **验证说明**：本沙箱**无法编译 native**（hvigor 构建被沙箱拒绝）。本 Task 的验收 = DevEco Studio 构建出 `libsmartdrive_exporter.so` 成功 + `NODE tools/offline-test.mjs` 的跨语言契约检查仍绿。

- [ ] **Step 1: 先跑基线**

Run: `NODE tools/offline-test.mjs`
Expected: PASS `105/105`（含 `跨语言：ArkTS 模板契约 == 原生导出契约`）。

- [ ] **Step 2: 加结构体与解析**

在 `napi_init.cpp` 加 `NativeExportSegment`；在 `parseExportPipelineRequest` 末尾解析 `segments`（用现成的 `getNamedProperty` + `napi_is_array`/`napi_get_array_length`/`napi_get_element`，字符串读取复用 `readUtf8Arg`，倍速解析照抄 `:100-124` 那套逐字符数字提取）。校验每项 `endMs > startMs`，否则返回 `EXPORT_ERR_SEGMENTS_INVALID`。

- [ ] **Step 3: 串到引擎**

`runPipelineAndWrapResult`（`:289-299`）把 `request.segments` 透传给 `runExportEnginePipeline`；`export_engine.h` 按上面的签名加参数。

- [ ] **Step 4: DevEco 构建**

Run: DevEco Studio → Build → Build Hap(s)
Expected: CMake 编译通过，产出 `entry/build/default/intermediates/libs/default/arm64-v8a/libsmartdrive_exporter.so`。

- [ ] **Step 5: 契约检查仍绿**

Run: `NODE tools/offline-test.mjs`
Expected: PASS，`kNativeTemplateContracts` 解析不受影响。

- [ ] **Step 6: 提交**

```bash
git add entry/src/main/cpp/napi_init.cpp entry/src/main/cpp/export_engine.h
git commit -m "feat(native): NAPI 解析多段导出请求"
```

---

### Task 12: Native —— 逐段渲染（暂缓）

> **暂缓说明**：同 Task 11。开工前先查清「导出失败」的根因（先看 `entry/src/main/cpp/export_engine.cpp` 的日志输出与 `NativeExportManager` 的错误码），把根因写进本次提交的 message 或代码注释，再动多段逻辑。


**Files:**
- Modify: `entry/src/main/cpp/export_engine.cpp:179-181`（trim 过滤器）、`:1510-1530`（区间解析）、`:1570-1640`（轨道拼接）

**Interfaces:**
- Consumes: Task 11 的 `NativeExportSegment`。
- Produces: 导出的成片按 `segments` 逐段裁剪、逐段应用倍速与静音后顺序拼接；`segments` 为空时行为与今天完全一致。

- [ ] **Step 1: 把单区间换成段列表**

`export_engine.cpp:1510-1530` 现在把 `startMs`/`endMs` 算成一对 `startSec`/`endSec`。改成：`segments` 非空时用 `segments`，否则用 `[{startMs, endMs, 1.0, false}]` 兜底（`startMs`/`endMs` 都为 0 时表示整条）。

- [ ] **Step 2: 逐段构造 trim 过滤器**

`:179-181` 的 `trim=start=..:end=..,setpts=PTS-STARTPTS` 改成按段循环：每段一条 `trim` + `setpts`，倍速用 `setpts=PTS/<speed>`，静音用 `volume=0`（仅当该段 `muted`），再 `concat=n=<段数>:v=1:a=1`。音频倍速用 `atempo`（`0.75`～`2.0` 单级 `atempo` 合法，不需要拆多级）。

- [ ] **Step 3: 让 `concatTrackToMp4` 与段序一致**

`:724` 的 `concatTrackToMp4` 按输入顺序拼接；确认三条轨（front/back/side）都按同一段序拼接，段与段之间不留空档。

- [ ] **Step 4: DevEco 构建**

Run: DevEco Studio → Build → Build Hap(s)
Expected: CMake 编译通过。

- [ ] **Step 5: 真机端到端验收**

用两段（第一段 `2.0X` + 静音、第二段 `1.0X` + 有声）导出，核对：
- 成片时长 = 第一段秒数 ÷ 2 + 第二段秒数；
- 第一段听不到声音、画面明显更快；
- 被 ✕ 掉的灰段不出现在成片里；
- 单段 + `1.0X` 的导出结果与改动前一致（回归）。

- [ ] **Step 6: 提交**

```bash
git add entry/src/main/cpp/export_engine.cpp
git commit -m "feat(native): 导出按段裁剪并逐段应用倍速与静音"
```

---

## 验收标准对照（spec §8）

| spec §8 | 落地 Task |
|---|---|
| 1 默认一整段、零操作可导出 | 2（模型）、9（页面） |
| 2 能切出第 2、3 段；满 3 段提示 | 3、9 |
| 3 段短于 2 秒被拒 | 3、9 |
| 4 点段选中 + 进度条跳到段起点 | 4（跳过逻辑）、9 |
| 5 每段倍速与声音互不影响 | 4、7、10（预览生效） |
| 6 ✕ 后变灰划掉、导出不含、播放跳过 | 4、9、10（预览跳过）、12（导出不含） |
| 7 倍速点击顺序 `0.75x→1.0x→1.25x→1.5x→2.0x` | 4、7、10（1.5X 枚举） |
| 8 声音按钮两态切换 | 4、7、8 |
| 9 画面比例跟随模板 | 9 |
| 10 导出浮层只有转圈 + 文字 | 9 |
| 11 全页无遗留强调色 | 1、9（守卫） |

## 未覆盖项

- **水印开关**（spec §9 第 2 条）：`watermarkEnabled` 字段保留但本计划不动其 UI，导出仍按默认值 `true` 传。
- **灰段的参数行**（spec §9 第 3 条）：本计划采用「隐藏倍速与声音按钮、只留段名与时长」；`SegmentParamRow` 的 `canToggle` 之外未再加 `hideTuning` 开关，若真机上发现隐藏后行高跳动，再加。

