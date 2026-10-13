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

/** 启用段的数量上限 */
export const MAX_SEGMENTS: number = 3
/** 单段最短时长（秒） */
export const MIN_SEGMENT_SEC: number = 2
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
 * 无条件执行切分或插入，不做任何上限校验（校验归 canSplitAt）。
 * 三条规则见 spec §5.3：启用段内切两半、灰段内只把后半段补回来、
 * 空档里插入 [sec, 下一个边界]。落到已有边界上则结构不变。
 */
function rawSplit(segments: Array<Segment>, sec: number, totalDurationSec: number): Array<Segment> {
  const freshId = nextSegmentId(segments)
  const out: Array<Segment> = []
  let inserted = false

  for (let i = 0; i < segments.length; i++) {
    const segment = segments[i]
    if (sec > segment.startSec && sec < segment.endSec) {
      const head = cloneSegment(segment)
      head.endSec = sec
      const tail = cloneSegment(segment)
      tail.id = freshId
      tail.startSec = sec
      tail.enabled = true
      out.push(head)
      out.push(tail)
      inserted = true
    } else {
      out.push(cloneSegment(segment))
    }
  }
  if (inserted) {
    return out
  }

  let onBoundary = false
  for (let i = 0; i < out.length; i++) {
    if (out[i].startSec === sec || out[i].endSec === sec) {
      onBoundary = true
      break
    }
  }
  if (onBoundary) {
    return out
  }

  let boundary = totalDurationSec
  let at = out.length
  for (let i = 0; i < out.length; i++) {
    if (out[i].startSec > sec) {
      boundary = out[i].startSec
      at = i
      break
    }
  }
  const fresh = new Segment()
  fresh.id = freshId
  fresh.startSec = sec
  fresh.endSec = boundary
  out.splice(at, 0, fresh)
  return out
}

/**
 * 能否在此落刀。拒绝：启用段已满、sec 不在 (0, 总时长) 内、
 * 或切分后会出现短于 MIN_SEGMENT_SEC 的启用段。
 * 用 MIN_SEGMENT_SEC - 1e-9 比较，避免 60 - 58 这类减法误差误拒。
 */
export function canSplitAt(segments: Array<Segment>, sec: number, totalDurationSec: number): boolean {
  if (enabledCount(segments) >= MAX_SEGMENTS) {
    return false
  }
  if (sec <= 0 || sec >= totalDurationSec) {
    return false
  }
  const result = rawSplit(segments, sec, totalDurationSec)
  if (enabledCount(result) <= enabledCount(segments)) {
    return false
  }
  const enabled = enabledSegments(result)
  for (let i = 0; i < enabled.length; i++) {
    if (segmentDurationSec(enabled[i]) < MIN_SEGMENT_SEC - 1e-9) {
      return false
    }
  }
  return true
}

/** 被拒绝时原样返回输入，不改结构。 */
export function splitSegmentAt(segments: Array<Segment>, sec: number, totalDurationSec: number): Array<Segment> {
  if (!canSplitAt(segments, sec, totalDurationSec)) {
    return segments
  }
  return rawSplit(segments, sec, totalDurationSec)
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
