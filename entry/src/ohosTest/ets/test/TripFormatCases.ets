import { TripCardModel } from '../../../main/ets/model/AppState'
import { formatTripDay, formatTripDuration, getTripStartTime, isTripComplete }
  from '../../../main/ets/utils/TripFormat'
import { TimelineCase, expectString, expectTrue, expectFalse, firstError } from './TestSupport'

function makeCase(name: string, run: () => string): TimelineCase {
  const item = new TimelineCase()
  item.name = name
  item.run = run
  return item
}

/** 只填首页时间轴真正会读到的那两个字段 */
function makeCard(subtitle: string, previewUri: string): TripCardModel {
  const card: TripCardModel = {
    id: 'trip-1',
    title: '2026-10-01',
    subtitle: subtitle,
    durationText: '754s',
    durationSec: 754,
    previewUri: previewUri,
    previewFrameUri: previewUri.length > 0 ? '/tmp/frame.jpg' : '',
    previewCamera: 'Front'
  }
  return card
}

export function tripFormatCases(): Array<TimelineCase> {
  const cases: Array<TimelineCase> = []

  cases.push(makeCase('从副标题区间里取出开始时间', () => {
    return expectString(getTripStartTime(makeCard('13:28 - 13:40 · 6 视角', 'file://a.mp4')), '13:28', '开始时间')
  }))

  cases.push(makeCase('副标题没有区间时整串当开始时间', () => {
    return expectString(getTripStartTime(makeCard('13:28', 'file://a.mp4')), '13:28', '开始时间')
  }))

  cases.push(makeCase('副标题为空时给占位串，时间轴不塌', () => {
    return expectString(getTripStartTime(makeCard('', 'file://a.mp4')), '--:--', '开始时间')
  }))

  cases.push(makeCase('副标题只有空白时也给占位串', () => {
    return expectString(getTripStartTime(makeCard('   ', 'file://a.mp4')), '--:--', '开始时间')
  }))

  cases.push(makeCase('封面命中视频即视为机位齐全', () => {
    return expectTrue(isTripComplete(makeCard('13:28 - 13:40 · 6 视角', 'file://a.mp4')), '完整')
  }))

  cases.push(makeCase('封面没命中视频即缺机位，时间轴画空心点', () => {
    return expectFalse(isTripComplete(makeCard('13:28 - 13:40 · 6 视角', '')), '缺机位')
  }))

  cases.push(makeCase('日期转成月日加星期', () => {
    return expectString(formatTripDay('2026-10-01'), '10月1日 周四', '日期')
  }))

  cases.push(makeCase('日期不补零，9 月显示成 9月12日', () => {
    return expectString(formatTripDay('2026-09-12'), '9月12日 周六', '日期')
  }))

  cases.push(makeCase('闰日也能转', () => {
    return expectString(formatTripDay('2024-02-29'), '2月29日 周四', '日期')
  }))

  cases.push(makeCase('日期格式不对时原样返回，不抛错', () => {
    return expectString(formatTripDay('今天'), '今天', '日期')
  }))

  cases.push(makeCase('日期里混进非数字时原样返回', () => {
    // Number.parseInt('1x') 会安静地返回 1，所以这里必须严格校验
    return expectString(formatTripDay('2026-1x-01'), '2026-1x-01', '日期')
  }))

  cases.push(makeCase('月份越界时原样返回，不让 Date 滚到次年', () => {
    return expectString(formatTripDay('2026-13-01'), '2026-13-01', '日期')
  }))

  cases.push(makeCase('秒转分秒，分钟不补零', () => {
    return expectString(formatTripDuration(754), '12:34', '时长')
  }))

  cases.push(makeCase('个位秒补零', () => {
    return expectString(formatTripDuration(65), '1:05', '时长')
  }))

  cases.push(makeCase('不足一分钟', () => {
    return expectString(formatTripDuration(5), '0:05', '时长')
  }))

  cases.push(makeCase('零与负数都落到 0:00', () => {
    return firstError([
      expectString(formatTripDuration(0), '0:00', '零'),
      expectString(formatTripDuration(-5), '0:00', '负数')
    ])
  }))

  cases.push(makeCase('非整数秒四舍五入', () => {
    return expectString(formatTripDuration(754.6), '12:35', '时长')
  }))

  return cases
}
