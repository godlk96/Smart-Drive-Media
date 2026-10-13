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
