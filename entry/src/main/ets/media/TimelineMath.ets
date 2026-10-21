/**
 * 预览时间轴的纯函数层。
 *
 * 这个文件刻意不依赖任何 @ohos / ArkUI 能力，也不持有任何状态：
 * 它只做"全局时间 → 该播哪一段的哪一毫秒"的换算。
 * 因此它可以被离线单测覆盖（见 tools/offline-test.mjs 与 ohosTest/ets/test/TimelineMath.test.ets），
 * 而播放器里最容易出错的地方正是这里的边界条件。
 *
 * 关键语义（与 CoreBridge / 原生导出契约一致）：
 *   - 所有机位共享同一套「墙钟网格」：网格起点是行程内最早切片的时间戳，
 *     第 i 个槽位是 [grid.startMs + i*60000, grid.startMs + (i+1)*60000)。
 *     网格槽位数由**墙钟跨度**决定，中间缺失的分钟仍然占一个槽位。
 *   - 机位缺某个切片时，它自己的段序列出现「空洞」——这是该机位的事实，不是模型的错误。
 *   - 因此段与段之间**不保证连续**，segmentAt() 必须显式返回 gap，绝不能"跳回第 0 段"。
 *
 * 为什么不能用"出现过的时间戳去重"当网格：
 *   若 Front 缺第 2 分钟、Back 有，则去重后 t=121000 在 Front 的序列里落到第 1 位（60s），
 *   在 Back 的序列里落到第 2 位（120s）——同一时刻的两路画面被摆到不同全局时间，
 *   分屏就会"两个机位播的不是同一时刻"。同时总时长被静默压缩 60s，
 *   与 CoreBridge 的 segmentCount = ceil(墙钟时长/60) 以及导出的边界标记不一致。
 *   墙钟网格从根上消除这两类偏差（"统一视角延续"的前提）。
 */

import { DvrMeta } from '../model/TripModels'

/** 每个 DVR 切片的标称时长（毫秒）。与 CoreBridge.CLIP_DURATION_SEC 同源。 */
export const SLICE_MS: number = 60000

/**
 * 同一段连续录制内，相邻切片允许的最大间隔。
 * 与 CoreBridge 的行程分组阈值（TRIP_GAP_THRESHOLD_MS）**必须同源**：
 * 超过它就说明中间断了一段录制，属于**两段不同的录制**，不能再共用同一条时间轴。
 */
export const RUN_GAP_MS: number = 120 * 1000

/** 一段连续录制在合并时间轴上的位置。 */
export class GridRun {
  /** 该段最早切片的墙钟时间戳。 */
  firstTs: number = 0
  /** 该段的槽位数（按墙钟跨度算，中间缺的分钟仍占位）。 */
  slotCount: number = 1
  /** 该段第一个槽位在**合并**时间轴上的序号。 */
  baseSlot: number = 0
}

/**
 * 行程的共享时间网格。
 *
 * 关键语义（这是 2026-10-13 真机日志暴露的 bug 的修复）：
 * 网格由**若干"连续录制段"依次拼接**而成，而不是拿全部切片的墙钟 min/max 拉一条轴。
 * 因为"合并行程"会把相隔几天甚至几个月的行程拼在一起：
 *   - 旧做法：min/max 跨天 → 3 分钟的合并行程变成 **190 小时**的时间轴，
 *     播完第一段后时钟要"跳过" 19 小时才到下一段 → 三轨全部重载（约 300~370ms 静音），
 *     而 UI 的总时长是各段之和（180s）→ 进度条被钳到 100% 并卡住；
 *   - 新做法：每段自己的墙钟网格按顺序首尾相接 → 3 分钟的合并行程就是 180 秒、3 个相邻槽位。
 *
 * 段**内**仍然共用同一套墙钟索引网格（这是"统一视角延续"的前提：
 * 某机位缺某一分钟时，它的段序列出现空洞，而不是把后面的段往前挪）。
 */
export class TimeGrid {
  /** 网格起点（= 全部切片中最早的墙钟时间戳）。 */
  startMs: number = 0
  /** 合并后的槽位总数，至少 1。 */
  sliceCount: number = 1
  /** 网格总时长 = sliceCount * SLICE_MS。 */
  durationMs: number = SLICE_MS
  /** 连续录制段，按墙钟升序；单段行程只有 1 个。 */
  runs: Array<GridRun> = []
}

/** 一段连续可播的媒体：全局时间落在 [startMs, startMs + durationMs) 时播放 uri。 */
export class SegmentSpan {
  uri: string = ''
  startMs: number = 0
  durationMs: number = 0
}

export enum SegmentKind {
  /** 该时刻本机位有素材 */
  CONTENT = 'content',
  /** 该时刻本机位确实没有素材（切片缺失），或已越过末尾 */
  GAP = 'gap'
}

export class SegmentTarget {
  kind: SegmentKind = SegmentKind.GAP
  /** CONTENT：段索引。GAP：**下一个**内容段的索引（可能是 segments.length，表示越过末尾）。 */
  index: number = -1
  /** 段内偏移（毫秒），仅 CONTENT 有意义。 */
  offsetMs: number = 0
  segmentStartMs: number = 0
  segmentDurationMs: number = 0
}

export function clampMs(ms: number, durationMs: number): number {
  if (!Number.isFinite(ms)) {
    return 0
  }
  if (ms < 0) {
    return 0
  }
  if (ms > durationMs) {
    return durationMs
  }
  return ms
}

/** 网格总时长：按**槽位数**算，而不是按 (末片 - 首片) 的墙钟差算（后者会漏掉尾部那一分钟）。 */
export function computeGridDurationMs(uniqueSliceCount: number): number {
  const count = uniqueSliceCount > 0 ? uniqueSliceCount : 1
  return count * SLICE_MS
}

/**
 * 由行程内**全部机位**的切片建立共享时间网格。
 *
 * 先把时间戳按 RUN_GAP_MS 切成若干"连续录制段"，再让各段依次首尾相接：
 *   段内槽位数 = round((段内最晚 - 段内最早) / 60000) + 1（中间缺失的分钟照样占位）；
 *   合并后总槽位数 = 各段槽位数之和；总时长 = 总槽位数 * 60000。
 *
 * 单段行程（绝大多数情况）结果与旧实现完全一致；只有"合并行程"才会不同 ——
 * 而旧实现在合并跨天行程时会把时间轴拉成几天长（真机实测 190 小时）。
 */
export function buildTimeGrid(clips: Array<DvrMeta>): TimeGrid {
  const grid = new TimeGrid()
  const stamps: Array<number> = []
  for (let i = 0; i < clips.length; i++) {
    const ts = clips[i].timestamp
    if (Number.isFinite(ts)) {
      stamps.push(ts)
    }
  }
  if (stamps.length === 0) {
    // 没有任何可用切片：退化为 1 个槽位、起点 0。
    const only = new GridRun()
    only.firstTs = 0
    only.slotCount = 1
    only.baseSlot = 0
    grid.runs = [only]
    grid.startMs = 0
    grid.sliceCount = 1
    grid.durationMs = SLICE_MS
    return grid
  }
  stamps.sort((a: number, b: number) => a - b)
  // 去重（同一时间戳可能来自多机位）
  const unique: Array<number> = []
  for (let i = 0; i < stamps.length; i++) {
    if (unique.length === 0 || unique[unique.length - 1] !== stamps[i]) {
      unique.push(stamps[i])
    }
  }

  const runs: Array<GridRun> = []
  let baseSlot = 0
  let i = 0
  while (i < unique.length) {
    const runFirstTs = unique[i]
    let runLastTs = unique[i]
    let j = i + 1
    while (j < unique.length) {
      const prevEndTs = unique[j - 1] + SLICE_MS
      if (unique[j] - prevEndTs <= RUN_GAP_MS) {
        runLastTs = unique[j]
        j += 1
      } else {
        break
      }
    }
    const slotCount = Math.max(1, Math.round((runLastTs - runFirstTs) / SLICE_MS) + 1)
    const run = new GridRun()
    run.firstTs = runFirstTs
    run.slotCount = slotCount
    run.baseSlot = baseSlot
    runs.push(run)
    baseSlot += slotCount
    i = j
  }

  grid.runs = runs
  grid.startMs = unique[0]
  grid.sliceCount = baseSlot
  grid.durationMs = computeGridDurationMs(baseSlot)
  return grid
}

/**
 * 时间戳 → **合并**时间轴上的槽位序号。
 *
 * 先定位它落在哪个"连续录制段"（用就近取整，容差半格 ±30000ms：
 * DVR 切片常有秒级漂移，严格相等匹配会把合法切片判为"不在网格"而整段丢弃），
 * 再换算成该段的局部槽位，最后加上该段的 baseSlot。
 * 落在段与段之间的空隙（例如合并行程里两段相隔几天）返回 -1，不猜测位置。
 */
export function gridIndexAt(grid: TimeGrid, timestamp: number): number {
  if (!Number.isFinite(timestamp)) {
    return -1
  }
  if (grid.runs.length === 0) {
    // 兼容：没有段信息时按单段处理。
    const fallback = Math.round((timestamp - grid.startMs) / SLICE_MS)
    if (fallback < 0 || fallback >= grid.sliceCount) {
      return -1
    }
    return fallback
  }
  for (let r = 0; r < grid.runs.length; r++) {
    const run = grid.runs[r]
    const local = Math.round((timestamp - run.firstTs) / SLICE_MS)
    if (local >= 0 && local < run.slotCount) {
      return run.baseSlot + local
    }
  }
  return -1
}

/** 槽位 i 的全局起始毫秒。 */
export function gridSlotStartMs(grid: TimeGrid, index: number): number {
  return index * SLICE_MS
}

/**
 * 把某机位的切片映射到共享网格上。
 * startMs 由切片在**墙钟网格**中的槽位序号决定，而不是由累积时长、也不是由"出现过的时间戳序号"决定——
 * 这样多个机位即使各自缺不同的分钟，同一全局时间对应的仍是同一时刻（统一视角延续的前提）。
 *
 * 同一机位两个切片落到同一槽位时（重复录制/文件重叠）只保留时间戳较早的那个，
 * 避免出现两个 startMs 相同的段让 segmentAt 变成不确定。
 */
export function buildSegmentSpans(
  clips: Array<DvrMeta>,
  camera: string,
  grid: TimeGrid
): Array<SegmentSpan> {
  const matched: Array<DvrMeta> = clips.filter((clip: DvrMeta) => clip.camera === camera && clip.uri.length > 0)
  matched.sort((a: DvrMeta, b: DvrMeta) => a.timestamp - b.timestamp)
  const spans: Array<SegmentSpan> = []
  const usedIndex: Array<number> = []
  for (let i = 0; i < matched.length; i++) {
    const sliceIndex = gridIndexAt(grid, matched[i].timestamp)
    if (sliceIndex < 0) {
      // 不在网格里的切片（理论上不会发生）：跳过而不是猜测位置。
      continue
    }
    if (usedIndex.indexOf(sliceIndex) >= 0) {
      continue
    }
    usedIndex.push(sliceIndex)
    const startMs = gridSlotStartMs(grid, sliceIndex)
    const remaining = grid.durationMs - startMs
    const span = new SegmentSpan()
    span.uri = matched[i].uri
    span.startMs = startMs
    span.durationMs = Math.min(SLICE_MS, Math.max(1000, remaining))
    spans.push(span)
  }
  spans.sort((a: SegmentSpan, b: SegmentSpan) => a.startMs - b.startMs)
  return spans
}

/**
 * 全局时间 → 本轨目标。无副作用，可离线单测。
 * 找不到内容时明确返回 GAP，**不再回退到第 0 段**（旧的 resolveSegment 兜底会让画面跳回行程开头）。
 *
 * GAP 的 index 语义 = 「下一个内容段的索引」，越过末尾时为 segments.length。
 * 这样 gapHoldIndex() = index - 1 恰好是"应保持的上一帧"的段索引，末尾空洞时指向最后一段。
 */
export function segmentAt(segments: Array<SegmentSpan>, globalMs: number): SegmentTarget {
  const target = new SegmentTarget()
  if (segments.length === 0) {
    return target
  }
  for (let i = 0; i < segments.length; i++) {
    const span = segments[i]
    if (globalMs >= span.startMs && globalMs < span.startMs + span.durationMs) {
      target.kind = SegmentKind.CONTENT
      target.index = i
      target.offsetMs = globalMs - span.startMs
      target.segmentStartMs = span.startMs
      target.segmentDurationMs = span.durationMs
      return target
    }
    if (globalMs < span.startMs) {
      // 落在第 i 段之前：处于空洞（或全局起点之前）。前一内容段是 i-1，用它保持上一帧。
      target.kind = SegmentKind.GAP
      target.index = i
      return target
    }
  }
  target.kind = SegmentKind.GAP
  target.index = segments.length
  return target
}

/**
 * GAP 时应保持的段索引：返回 -1 表示该机位此前从未有过画面（开头即空洞 → 黑场）。
 */
export function gapHoldIndex(target: SegmentTarget): number {
  if (target.kind === SegmentKind.CONTENT) {
    return target.index
  }
  return target.index - 1
}

/** 段在全局时间轴上的结束时刻。 */
export function segmentEndMs(span: SegmentSpan): number {
  return span.startMs + span.durationMs
}

/**
 * 该全局时刻是否被**至少一条轨**的段覆盖。
 *
 * 为什么需要它：时钟只能由"正在播放的轨"推进。若某一分钟只有模板之外的机位录到了
 * （例如 T3 用 Front/Left/Right，而这一分钟只有 RightFront 有文件），那么所有轨在该时刻
 * 都只能"保持上一帧"，没有任何轨能驱动时钟 —— 播放头会永久停住。
 * 协调器用本函数识别这种"无人覆盖"的时刻并跳过它，而不是僵在那里。
 */
export function isCoveredMs(trackSpans: Array<Array<SegmentSpan>>, globalMs: number): boolean {
  for (let t = 0; t < trackSpans.length; t++) {
    const spans = trackSpans[t]
    for (let i = 0; i < spans.length; i++) {
      const span = spans[i]
      if (globalMs >= span.startMs && globalMs < span.startMs + span.durationMs) {
        return true
      }
    }
  }
  return false
}

/**
 * 从 globalMs 起（含）**最早被覆盖**的时刻；若此后再无任何覆盖则返回 durationMs（表示已到尽头）。
 *
 * 只向前找（span.startMs >= globalMs），保证调用方一定能越过空洞，
 * 不会在同一个空洞里原地打转。返回值可能是当前时刻本身（已覆盖时）。
 */
export function nextCoveredMs(
  trackSpans: Array<Array<SegmentSpan>>,
  globalMs: number,
  durationMs: number
): number {
  let best = durationMs
  for (let t = 0; t < trackSpans.length; t++) {
    const spans = trackSpans[t]
    for (let i = 0; i < spans.length; i++) {
      const span = spans[i]
      if (span.startMs >= globalMs && span.startMs < best) {
        best = span.startMs
      }
    }
  }
  return best
}

// ------------------------------------------------------------------
// seek 决策（纯函数，可离线单测）
//
// 为什么这段策略要放在纯函数层：它是"播放中该不该动播放器"的判据，
// 而旧实现正是在这里出了一个把整页预览拖垮的错 —— 见 checkSeek() 的注释。
// ------------------------------------------------------------------

/**
 * 同一段内，播放器**实际**位置与目标位置的偏差超过该值才考虑 seek。
 * 容差存在的意义：timeUpdate 是**离散**上报的，两条轨的上报时刻天然错开，
 * 于是"同一瞬间"比较两路位置必然带上一个上报周期的假偏差。
 */
export const SEEK_TOLERANCE_MS: number = 300

/**
 * 偏差必须**连续持续**这么久才真正 seek。
 *
 * 为什么不能一超容差就 seek（旧实现的 bug）：旧代码拿"上次 seek 的目标"当基准，
 * 而目标会随着播放被甩在身后，偏差于是**恒定增长** —— 每积累一个容差就 seek 一次，
 * 播放中约 3~5 次/秒。每次 seek 都要冲刷解码器（听感 = 声音断断续续），
 * 且 seek 期间该轨不上报进度（观感 = 进度条一顿一顿）。
 *
 * 换成"以播放器实际位置为基准"后，驱动时钟的那条轨偏差恒为 0，正常播放不再 seek。
 * 这个确认窗口再挡掉一类残余假偏差：上报时刻错开造成的瞬时偏差会在下一条
 * timeUpdate 到达时自行消失，撑不过一个确认窗口；而**真实**的卡住/失步会一直撑下去。
 */
export const DRIFT_CONFIRM_MS: number = 700

/** checkSeek() 的结果。 */
export class SeekCheck {
  /** 是否应当发起 seek。 */
  seek: boolean = false
  /** 调用方原样保存，下一轮作为 driftHeldMs 传回。0 表示当前偏差在容差内。 */
  nextDriftHeldMs: number = 0
}

/**
 * 判断是否需要 seek。纯函数：同样的入参永远得到同样的结果。
 *
 * @param observedOffsetMs 播放器**实际**报告的位置（-1 表示还没收到过 timeUpdate）。
 * @param wantedOffsetMs 目标位置。
 * @param forceSeek 强制重定位（用户跳转 / 换段 / 时钟 seek）；无视容差与确认窗口。
 * @param driftHeldMs 上一轮返回的 nextDriftHeldMs。
 * @param elapsedMs 距离上一轮检查经过的毫秒数。
 */
export function checkSeek(
  observedOffsetMs: number,
  wantedOffsetMs: number,
  forceSeek: boolean,
  driftHeldMs: number,
  elapsedMs: number
): SeekCheck {
  const result = new SeekCheck()
  if (forceSeek) {
    result.seek = true
    result.nextDriftHeldMs = 0
    return result
  }
  // 还没收到过 timeUpdate 时，播放器的位置就是文件开头（载入/prepare 之后）。
  const observed = observedOffsetMs >= 0 ? observedOffsetMs : 0
  if (Math.abs(observed - wantedOffsetMs) <= SEEK_TOLERANCE_MS) {
    // 回到容差内：确认窗口清零 —— 偏差必须是**连续**的才算数。
    result.nextDriftHeldMs = 0
    return result
  }
  const held = driftHeldMs + (elapsedMs > 0 ? elapsedMs : 0)
  if (held >= DRIFT_CONFIRM_MS) {
    result.seek = true
    // 已发起 seek：确认窗口重新计时，避免连续补 seek。
    result.nextDriftHeldMs = 0
    return result
  }
  result.nextDriftHeldMs = held
  return result
}
