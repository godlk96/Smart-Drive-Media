/**
 * 片段模型：剪辑页的全部片段算法都在这里。
 *
 * 为什么单独成模块：片段是纯数据 + 纯函数（切分、时长换算、播放跳过），
 * 与 ArkUI 和 @ohos 无关。放在这里就能被 tools/offline-test.mjs 直接跑，
 * 页面只负责渲染与转发，不再自己写业务判断。
 *
 * 本文件**不得**导入 @ohos.* / @kit.*（离线桩遇到裸导入会直接抛错）。
 *
 * 语义：segments 是升序、互不重叠的区间列表；段之间的空档是隐式灰段，
 * 不占 MAX_SEGMENTS 名额（该上限只数 enabled === true 的段）。
 * 默认状态是 createFullSegment(total) 返回的一整段 [0, total]。
 */

import { ExportSegment } from './TripModels'

/** 启用段的数量上限 */
export const MAX_SEGMENTS: number = 3
/** 单段最短时长（秒） */
export const MIN_SEGMENT_SEC: number = 10
/** 首次与空档剪辑默认窗口（秒） */
export const DEFAULT_CLIP_WINDOW_SEC: number = 15
/** 倍速循环顺序，点击单按钮依次切换 */
export const SPEED_CYCLE: Array<string> = ['0.75X', '1.0X', '1.25X', '1.5X', '2.0X']

const SPEED_MIN: number = 0.75
const SPEED_MAX: number = 2.0
const DEFAULT_SPEED_LABEL: string = '1.0X'

export class Segment {
  id: number = 0
  startSec: number = 0
  endSec: number = 0
  speedLabel: string = DEFAULT_SPEED_LABEL
  muted: boolean = false
  enabled: boolean = true
}

/** 默认状态：一整段覆盖全片。片长非法时兜底 1 秒，避免 0 长度段。 */
export function createFullSegment(totalDurationSec: number): Array<Segment> {
  const segment = new Segment()
  segment.id = 0
  segment.startSec = 0
  segment.endSec = totalDurationSec <= 0 ? 1 : totalDurationSec
  segment.speedLabel = DEFAULT_SPEED_LABEL
  segment.muted = false
  segment.enabled = true
  const segments: Array<Segment> = [segment]
  return segments
}

/** 源片区间长度（秒），与倍速无关 */
export function segmentDurationSec(segment: Segment): number {
  return segment.endSec - segment.startSec
}

export function enabledSegments(segments: Array<Segment>): Array<Segment> {
  const out: Array<Segment> = []
  for (let i = 0; i < segments.length; i++) {
    if (segments[i].enabled) {
      out.push(segments[i])
    }
  }
  return out
}

export function enabledCount(segments: Array<Segment>): number {
  return enabledSegments(segments).length
}

/**
 * 定位某一秒落在哪一段。区间取闭区间，升序扫描返回首个命中，
 * 因此段边界归前一段（15s 属于 [0,15] 而不是 [15,30]），边界不歧义。
 * 不在任何段内（含负数、超出片尾）返回 -1。
 */
export function segmentIndexAtSec(segments: Array<Segment>, sec: number): number {
  for (let i = 0; i < segments.length; i++) {
    const segment = segments[i]
    if (sec >= segment.startSec && sec <= segment.endSec) {
      return i
    }
  }
  return -1
}

/** 解析倍速标签为因子。非法或超出 0.75–2.0 一律回落 1.0。 */
export function speedFactor(speedLabel: string): number {
  const parsed = Number.parseFloat(speedLabel)
  if (Number.isNaN(parsed)) {
    return 1
  }
  if (parsed < SPEED_MIN || parsed > SPEED_MAX) {
    return 1
  }
  return parsed
}

/**
 * 倍速因子 → `media.PlaybackSpeed` 枚举值。
 *
 * 为什么放在这里：`SingleTrackController` 原来自己写了一段 if/else，漏了 1.5x
 * （`PlaybackSpeed.SPEED_FORWARD_1_50_X = 6`），1.5 既不到 1.6 也不到 1.9，
 * 于是掉进 1.2 分支被当成 1.25x 播放——这是「预览与导出不一致」的根源。
 * 阈值从大到小判，1.5x 单独走 1.4 这一档。
 */
export function speedEnumForRate(rate: number): number {
  if (rate >= 1.9) {
    return 4
  }
  if (rate >= 1.6) {
    return 3
  }
  if (rate >= 1.4) {
    return 6
  }
  if (rate >= 1.2) {
    return 2
  }
  if (rate <= 0.8) {
    return 0
  }
  return 1
}

/** 成片时长：只累加启用段，逐段按各自倍速换算。 */
export function outputDurationSec(segments: Array<Segment>): number {
  let total = 0
  for (let i = 0; i < segments.length; i++) {
    const segment = segments[i]
    if (!segment.enabled) {
      continue
    }
    total += segmentDurationSec(segment) / speedFactor(segment.speedLabel)
  }
  return total
}

function cloneSegment(segment: Segment): Segment {
  const copy = new Segment()
  copy.id = segment.id
  copy.startSec = segment.startSec
  copy.endSec = segment.endSec
  copy.speedLabel = segment.speedLabel
  copy.muted = segment.muted
  copy.enabled = segment.enabled
  return copy
}

/** 新段 id = 当前所有段 id 的最大值 + 1（空表从 0 起） */
function nextSegmentId(segments: Array<Segment>): number {
  let max = -1
  for (let i = 0; i < segments.length; i++) {
    if (segments[i].id > max) {
      max = segments[i].id
    }
  }
  return max + 1
}

/**
 * 拖动左手柄调整片段起点。
 * - 向左不越过前一段终点（若无前段则为 0）
 * - 向右不越过 endSec - 10
 * - 保持硬阻挡，不挤压前段
 */
export function adjustSegmentStart(
  segments: Array<Segment>,
  id: number,
  targetSec: number,
  totalDurationSec: number
): Array<Segment> {
  let targetIdx = -1
  for (let i = 0; i < segments.length; i++) {
    if (segments[i].id === id) {
      targetIdx = i
      break
    }
  }
  if (targetIdx === -1) {
    const out: Array<Segment> = []
    for (let i = 0; i < segments.length; i++) {
      out.push(cloneSegment(segments[i]))
    }
    return out
  }

  const targetSeg = segments[targetIdx]
  const minSec = targetIdx > 0 ? segments[targetIdx - 1].endSec : 0
  const maxSec = targetSeg.endSec - MIN_SEGMENT_SEC
  const clampedSec = Math.max(minSec, Math.min(targetSec, maxSec))

  const out: Array<Segment> = []
  for (let i = 0; i < segments.length; i++) {
    const copy = cloneSegment(segments[i])
    if (copy.id === id) {
      copy.startSec = clampedSec
    }
    out.push(copy)
  }
  return out
}

/**
 * 拖动右手柄调整片段终点。
 * - 向左不低于 startSec + 10
 * - 向右不越过后一段起点（若无后段则为 totalDurationSec）
 * - 保持硬阻挡，不挤压后段
 */
export function adjustSegmentEnd(
  segments: Array<Segment>,
  id: number,
  targetSec: number,
  totalDurationSec: number
): Array<Segment> {
  let targetIdx = -1
  for (let i = 0; i < segments.length; i++) {
    if (segments[i].id === id) {
      targetIdx = i
      break
    }
  }
  if (targetIdx === -1) {
    const out: Array<Segment> = []
    for (let i = 0; i < segments.length; i++) {
      out.push(cloneSegment(segments[i]))
    }
    return out
  }

  const targetSeg = segments[targetIdx]
  const minSec = targetSeg.startSec + MIN_SEGMENT_SEC
  const maxSec = targetIdx < segments.length - 1 ? segments[targetIdx + 1].startSec : totalDurationSec
  const clampedSec = Math.max(minSec, Math.min(targetSec, maxSec))

  const out: Array<Segment> = []
  for (let i = 0; i < segments.length; i++) {
    const copy = cloneSegment(segments[i])
    if (copy.id === id) {
      copy.endSec = clampedSec
    }
    out.push(copy)
  }
  return out
}

/**
 * 物理移除目标片段并返回新数组，保持剩余片段顺序不变。
 */
export function removeSegment(segments: Array<Segment>, id: number): Array<Segment> {
  const out: Array<Segment> = []
  for (let i = 0; i < segments.length; i++) {
    if (segments[i].id !== id) {
      out.push(cloneSegment(segments[i]))
    }
  }
  return out
}

/**
 * 判断在 sec 处能否执行剪辑（落刀一分为二或空档插入）。
 * - 若 isRawFull 为 true：需满足 sec >= 0 且 totalDurationSec - sec >= 10。
 * - 若 isRawFull 为 false：
 *   - 片段数已达 MAX_SEGMENTS (3) 时返回 false
 *   - sec 超出 [0, totalDurationSec) 时返回 false
 *   - 若落在某个段内 [start, end]：需满足 sec - start >= 10 且 end - sec >= 10（原段长必须 >= 20s）
 *   - 若落在已有段起点 start 上：返回 false
 *   - 若落在空档内：寻找 sec 后方下一个片段起点 nextStart（若无则为 totalDurationSec），需满足 nextStart - sec >= 10
 */
export function canSplitOrInsertAt(
  segments: Array<Segment>,
  sec: number,
  totalDurationSec: number,
  isRawFull: boolean
): boolean {
  if (sec < 0 || sec >= totalDurationSec) {
    return false
  }

  if (isRawFull) {
    return (totalDurationSec - sec) >= (MIN_SEGMENT_SEC - 1e-9)
  }

  if (segments.length >= MAX_SEGMENTS) {
    return false
  }

  // 落在某段内部 (startSec, endSec)
  for (let i = 0; i < segments.length; i++) {
    const seg = segments[i]
    if (sec > seg.startSec && sec < seg.endSec) {
      const leftValid = (sec - seg.startSec) >= (MIN_SEGMENT_SEC - 1e-9)
      const rightValid = (seg.endSec - sec) >= (MIN_SEGMENT_SEC - 1e-9)
      return leftValid && rightValid
    }
  }

  // 已有片段起点处不可落刀
  for (let i = 0; i < segments.length; i++) {
    if (segments[i].startSec === sec) {
      return false
    }
  }

  // 落在空档内（包括前段 endSec），寻找后方第一个起点
  let nextStart = totalDurationSec
  for (let i = 0; i < segments.length; i++) {
    if (segments[i].startSec > sec) {
      nextStart = segments[i].startSec
      break
    }
  }

  return (nextStart - sec) >= (MIN_SEGMENT_SEC - 1e-9)
}

/**
 * 执行剪辑：
 * - isRawFull 为 true：生成 [sec, min(totalDurationSec, sec + 15)] 唯一高光选区，id = 0；
 * - 落在段内：切分成 [start, sec] 与 [sec, end]；
 * - 落在空档：插入 [sec, min(nextStart, sec + 15)]。
 * - 拒绝时原样返回。
 */
export function splitOrInsertAt(
  segments: Array<Segment>,
  sec: number,
  totalDurationSec: number,
  isRawFull: boolean
): Array<Segment> {
  if (!canSplitOrInsertAt(segments, sec, totalDurationSec, isRawFull)) {
    return segments
  }

  if (isRawFull) {
    const seg = new Segment()
    seg.id = 0
    seg.startSec = sec
    seg.endSec = Math.min(totalDurationSec, sec + DEFAULT_CLIP_WINDOW_SEC)
    seg.speedLabel = segments.length > 0 ? segments[0].speedLabel : DEFAULT_SPEED_LABEL
    seg.muted = segments.length > 0 ? segments[0].muted : false
    seg.enabled = true
    return [seg]
  }

  // 落在某段内部 (startSec, endSec)
  let splitIdx = -1
  for (let i = 0; i < segments.length; i++) {
    if (sec > segments[i].startSec && sec < segments[i].endSec) {
      splitIdx = i
      break
    }
  }

  if (splitIdx >= 0) {
    const target = segments[splitIdx]
    const freshId = nextSegmentId(segments)
    const out: Array<Segment> = []
    for (let i = 0; i < segments.length; i++) {
      if (i === splitIdx) {
        const head = cloneSegment(target)
        head.endSec = sec
        const tail = cloneSegment(target)
        tail.id = freshId
        tail.startSec = sec
        tail.enabled = true
        out.push(head)
        out.push(tail)
      } else {
        out.push(cloneSegment(segments[i]))
      }
    }
    return out
  }

  // 落在空档内，计算后方边界并插入
  let nextStart = totalDurationSec
  let insertAt = segments.length
  for (let i = 0; i < segments.length; i++) {
    if (segments[i].startSec > sec) {
      nextStart = segments[i].startSec
      insertAt = i
      break
    }
  }

  const fresh = new Segment()
  fresh.id = nextSegmentId(segments)
  fresh.startSec = sec
  fresh.endSec = Math.min(nextStart, sec + DEFAULT_CLIP_WINDOW_SEC)
  fresh.speedLabel = DEFAULT_SPEED_LABEL
  fresh.muted = false
  fresh.enabled = true

  const out: Array<Segment> = []
  for (let i = 0; i < segments.length; i++) {
    if (i === insertAt) {
      out.push(fresh)
    }
    out.push(cloneSegment(segments[i]))
  }
  if (insertAt === segments.length) {
    out.push(fresh)
  }
  return out
}

/** 兼容旧接口：多片段模式下检查能否切分或插入 */
export function canSplitAt(segments: Array<Segment>, sec: number, totalDurationSec: number): boolean {
  return canSplitOrInsertAt(segments, sec, totalDurationSec, false)
}

/** 兼容旧接口：多片段模式下执行切分或插入 */
export function splitSegmentAt(segments: Array<Segment>, sec: number, totalDurationSec: number): Array<Segment> {
  return splitOrInsertAt(segments, sec, totalDurationSec, false)
}

/**
 * 目标段能否翻转。
 * - 目标已是灰段 → 总能恢复（spec D13「可恢复」）。
 * - 目标是启用段 → 只在还有别的启用段时才允许关掉（spec §5.7「只剩一段时 ✕ 不再生效」），
 *   因此「0 个启用段」不可达。
 */
export function canToggleSegment(segments: Array<Segment>, id: number): boolean {
  for (let i = 0; i < segments.length; i++) {
    if (segments[i].id === id) {
      if (!segments[i].enabled) {
        return true
      }
      return enabledCount(segments) > 1
    }
  }
  return false
}

/** 翻转目标段的 enabled；再点一次就是恢复。 */
export function toggleSegmentEnabled(segments: Array<Segment>, id: number): Array<Segment> {
  if (!canToggleSegment(segments, id)) {
    return segments
  }
  const out: Array<Segment> = []
  for (let i = 0; i < segments.length; i++) {
    const copy = cloneSegment(segments[i])
    if (copy.id === id) {
      copy.enabled = !copy.enabled
    }
    out.push(copy)
  }
  return out
}

/** 沿 SPEED_CYCLE 前进一格，'2.0X' 回绕到 '0.75X'。入参不在表里则返回 '1.0X'。 */
export function cycleSpeedLabel(label: string): string {
  const at = SPEED_CYCLE.indexOf(label)
  if (at < 0) {
    return DEFAULT_SPEED_LABEL
  }
  return SPEED_CYCLE[(at + 1) % SPEED_CYCLE.length]
}

export function setSegmentSpeed(segments: Array<Segment>, id: number, speedLabel: string): Array<Segment> {
  const out: Array<Segment> = []
  for (let i = 0; i < segments.length; i++) {
    const copy = cloneSegment(segments[i])
    if (copy.id === id) {
      copy.speedLabel = speedLabel
    }
    out.push(copy)
  }
  return out
}

export function setSegmentMuted(segments: Array<Segment>, id: number, muted: boolean): Array<Segment> {
  const out: Array<Segment> = []
  for (let i = 0; i < segments.length; i++) {
    const copy = cloneSegment(segments[i])
    if (copy.id === id) {
      copy.muted = muted
    }
    out.push(copy)
  }
  return out
}

/**
 * 播放到 sec 时应该跳到哪一秒（所见即所得：预览与成片都跳过灰段与空档）。
 * 落在启用段内原地不动；落在灰段内跳到该段终点；落在空档里跳到空档终点
 * （之后第一个段的起点，没有则片尾）。
 */
export function playbackSkipTargetSec(segments: Array<Segment>, sec: number, totalDurationSec: number): number {
  const at = segmentIndexAtSec(segments, sec)
  if (at >= 0) {
    const segment = segments[at]
    return segment.enabled ? sec : segment.endSec
  }
  for (let i = 0; i < segments.length; i++) {
    if (segments[i].startSec > sec) {
      return segments[i].startSec
    }
  }
  return totalDurationSec
}

export function isAllDisabled(segments: Array<Segment>): boolean {
  return enabledCount(segments) === 0
}

/** 段时长文案：只写时长不写起止（spec D9/D10），向上取整到秒，如 '15s'。 */
export function formatSegmentDuration(segment: Segment): string {
  return `${Math.ceil(segmentDurationSec(segment))}s`
}

/** 模型层片段 → 导出用区间：只取启用段，按起点升序，秒转毫秒用四舍五入。 */
export function toExportSegments(segments: Array<Segment>): Array<ExportSegment> {
  const out: Array<ExportSegment> = []
  for (let i = 0; i < segments.length; i++) {
    const segment = segments[i]
    if (!segment.enabled) {
      continue
    }
    const item = new ExportSegment()
    item.startMs = Math.round(segment.startSec * 1000)
    item.endMs = Math.round(segment.endSec * 1000)
    item.speedLabel = segment.speedLabel
    item.muted = segment.muted
    out.push(item)
  }
  out.sort((a: ExportSegment, b: ExportSegment) => a.startMs - b.startMs)
  return out
}

/** 导出成片时长（秒）：各段毫秒长度按各自倍速换算后求和。 */
export function exportDurationSec(segments: Array<ExportSegment>): number {
  let total = 0
  for (let i = 0; i < segments.length; i++) {
    const item = segments[i]
    total += (item.endMs - item.startMs) / 1000 / speedFactor(item.speedLabel)
  }
  return total
}
