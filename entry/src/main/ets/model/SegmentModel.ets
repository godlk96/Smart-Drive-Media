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
