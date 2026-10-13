import { Segment, createFullSegment, canSplitAt, enabledCount, outputDurationSec, segmentDurationSec,
  segmentIndexAtSec, speedFactor, splitSegmentAt, toggleSegmentEnabled } from '../../../main/ets/model/SegmentModel'
import { TimelineCase, expectNumber, expectString, expectTrue, firstError } from './TestSupport'

function makeCase(name: string, run: () => string): TimelineCase {
  const item = new TimelineCase()
  item.name = name
  item.run = run
  return item
}

/** 手工造一个带真空档的区间表：[0,15] 与 [30,59] 之间没有任何段 */
function gappedSegments(): Array<Segment> {
  const first = new Segment()
  first.id = 0
  first.startSec = 0
  first.endSec = 15
  const second = new Segment()
  second.id = 1
  second.startSec = 30
  second.endSec = 59
  const segments: Array<Segment> = [first, second]
  return segments
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
    const two = splitSegmentAt(createFullSegment(60), 30, 60)
    const off = toggleSegmentEnabled(two, two[0].id)
    const segments = splitSegmentAt(off, 20, 60)
    return firstError([
      expectNumber(segments.length, 3, '段数'),
      expectTrue(!segments[0].enabled, '前半段仍灰'),
      expectTrue(segments[1].enabled, '后半段恢复'),
      expectNumber(enabledCount(segments), 2, '启用段数')
    ])
  }))

  cases.push(makeCase('灰段里落刀补到下一个边界（用户给的例子）', () => {
    let segments = splitSegmentAt(createFullSegment(59), 15, 59)
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

  cases.push(makeCase('真空档里落刀插入新段', () => {
    const after = splitSegmentAt(gappedSegments(), 20, 59)
    const inserted = after.filter((item) => item.startSec === 20)
    return firstError([
      expectNumber(after.length, 3, '段数'),
      expectNumber(inserted.length, 1, '新增段数量'),
      expectNumber(inserted[0].endSec, 30, '新增段终点=下一个边界'),
      expectTrue(inserted[0].enabled, '新增段启用'),
      expectString(inserted[0].speedLabel, '1.0X', '新增段倍速'),
      expectNumber(enabledCount(after), 3, '启用段数'),
      expectNumber(after[0].endSec, 15, '原段不动')
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

  cases.push(makeCase('已有段边界上落刀不改结构', () => {
    const two = splitSegmentAt(createFullSegment(60), 30, 60)
    return firstError([
      expectTrue(!canSplitAt(two, 30, 60), '边界处应拒绝'),
      expectNumber(splitSegmentAt(two, 30, 60).length, 2, '结构不变')
    ])
  }))

  return cases
}
