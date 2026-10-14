import { TripCardModel } from '../model/AppState'

const WEEKDAY_LABELS: Array<string> = ['周日', '周一', '周二', '周三', '周四', '周五', '周六']

/**
 * 从副标题 "13:28 - 13:40 · 6 视角" 里取出开始时间。
 * 取不到时返回占位串，避免时间轴上的数字整列塌掉。
 */
export function getTripStartTime(card: TripCardModel): string {
  const subtitle: string = card.subtitle
  const dashIndex: number = subtitle.indexOf(' - ')
  const head: string = dashIndex >= 0 ? subtitle.substring(0, dashIndex) : subtitle
  const trimmed: string = head.trim()
  if (trimmed.length === 0) {
    return '--:--'
  }
  // 副标题里是 "13:28:18"（toTimeText 带秒）。轨道只有 46vp 宽、右侧还要给状态点留 13vp，
  // 装不下 8 个字符 —— 会折成 "13:2 / 8:18" 两行。列表粒度到分钟就够，砍掉秒。
  if (trimmed.length >= 5 && trimmed.charAt(2) === ':') {
    return trimmed.substring(0, 5)
  }
  return trimmed
}

/**
 * 封面命中视频即视为机位齐全。缺机位的行程在时间轴上画空心点 ——
 * 信息不丢，但不再用第三个强调色去喊。
 */
export function isTripComplete(card: TripCardModel): boolean {
  return card.previewUri.length > 0
}

/**
 * 严格解析一段十进制整数：只要混进非数字就判为无效。
 * 不能用 Number.parseInt 直接顶——它遇到 "1x" 会安静地返回 1，
 * 那样 "2026-1x-01" 会被当成 1 月 1 日，比报错更难查。
 */
function parseStrictInt(text: string): number {
  if (text.length === 0) {
    return Number.NaN
  }
  for (let i = 0; i < text.length; i += 1) {
    const ch: string = text.charAt(i)
    if (ch < '0' || ch > '9') {
      return Number.NaN
    }
  }
  return Number.parseInt(text, 10)
}

/**
 * "2026-10-01" → "10月1日 周四"。解析失败原样返回，绝不抛错。
 */
export function formatTripDay(dateText: string): string {
  const parts: Array<string> = dateText.split('-')
  if (parts.length !== 3) {
    return dateText
  }
  const year: number = parseStrictInt(parts[0])
  const month: number = parseStrictInt(parts[1])
  const day: number = parseStrictInt(parts[2])
  if (Number.isNaN(year) || Number.isNaN(month) || Number.isNaN(day)) {
    return dateText
  }
  // 越界会让 Date 悄悄滚到下个月/下一年，宁可原样显示
  if (month < 1 || month > 12 || day < 1 || day > 31) {
    return dateText
  }
  const weekday: string = WEEKDAY_LABELS[new Date(year, month - 1, day).getDay()]
  return `${month}月${day}日 ${weekday}`
}

/**
 * 秒 → "12:34"。分钟不补零，与 PreviewOverlay 的 formatTime 保持一致，
 * 免得同一段时间在首页和剪辑页长得不一样。
 */
export function formatTripDuration(totalSec: number): string {
  const safe: number = totalSec > 0 ? Math.round(totalSec) : 0
  const minutes: number = Math.floor(safe / 60)
  const seconds: number = safe % 60
  return `${minutes}:${seconds < 10 ? '0' : ''}${seconds}`
}
