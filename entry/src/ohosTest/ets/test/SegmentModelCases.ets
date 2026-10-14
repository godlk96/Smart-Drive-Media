import { Segment, createFullSegment, canSplitAt, canToggleSegment, cycleSpeedLabel, enabledCount,
  exportDurationSec, formatSegmentDuration, isAllDisabled, outputDurationSec, playbackSkipTargetSec,
  segmentDurationSec, segmentIndexAtSec, setSegmentMuted, setSegmentSpeed, speedEnumForRate, speedFactor,
  splitSegmentAt, toExportSegments, toggleSegmentEnabled,
  MIN_SEGMENT_SEC, DEFAULT_CLIP_WINDOW_SEC,
  adjustSegmentStart, adjustSegmentEnd, removeSegment, canSplitOrInsertAt, splitOrInsertAt }
  from '../../../main/ets/model/SegmentModel'
import { TimelineCase, expectNumber, expectString, expectTrue, firstError } from './TestSupport'

function makeCase(name: string, run: () => string): TimelineCase {
  const item = new TimelineCase()
  item.name = name
  item.run = run
  return item
}

function makeSegment(id: number, startSec: number, endSec: number, speedLabel: string = '1.0X', muted: boolean = false): Segment {
  const seg = new Segment()
  seg.id = id
  seg.startSec = startSec
  seg.endSec = endSec
  seg.speedLabel = speedLabel
  seg.muted = muted
  seg.enabled = true
  return seg
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
    let segments = splitSegmentAt(createFullSegment(60), 30, 60)
    segments = toggleSegmentEnabled(segments, segments[0].id)
    const after = splitSegmentAt(segments, 15, 60)
    const inserted = after.filter((item) => item.startSec === 15)
    return firstError([
      expectNumber(inserted.length, 1, '新增段数量'),
      expectNumber(inserted[0].endSec, 30, '新增段终点=下一个边界'),
      expectTrue(inserted[0].enabled, '新增段启用'),
      expectNumber(enabledCount(after), 2, '启用段数')
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

  cases.push(makeCase('切出短于 10 秒的段被拒绝', () => {
    const segments = splitSegmentAt(createFullSegment(60), 5, 60)
    return firstError([
      expectTrue(!canSplitAt(createFullSegment(60), 5, 60), '5 秒应拒绝'),
      expectTrue(!canSplitAt(createFullSegment(60), 9, 60), '9 秒应拒绝'),
      expectTrue(!canSplitAt(createFullSegment(60), 51, 60), '51 秒应拒绝'),
      expectNumber(segments.length, 1, '拒绝时不改结构')
    ])
  }))

  cases.push(makeCase('恰好 10 秒放行（边界含等号）', () => {
    return firstError([
      expectTrue(canSplitAt(createFullSegment(60), 10, 60), '起点侧 10 秒'),
      expectTrue(canSplitAt(createFullSegment(60), 50, 60), '终点侧 10 秒')
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
      expectTrue(!canToggleSegment(segments, 0), '单段不可关'),
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
      expectTrue(!canToggleSegment(two, two[1].id), '只剩 1 个启用段时不可再关'),
      expectTrue(stillTwo[1].enabled, '第二次关不掉'),
      expectTrue(!isAllDisabled(stillTwo), '永远至少 1 个启用段')
    ])
  }))

  cases.push(makeCase('段时长文案向上取整到秒', () => {
    const whole = new Segment()
    whole.startSec = 0
    whole.endSec = 15
    const fractional = new Segment()
    fractional.startSec = 0
    fractional.endSec = 15.4
    return firstError([
      expectString(formatSegmentDuration(whole), '15s', '整数秒'),
      expectString(formatSegmentDuration(fractional), '16s', '向上取整'),
      expectString(formatSegmentDuration(createFullSegment(59.4)[0]), '60s', '非整数片长')
    ])
  }))

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

  cases.push(makeCase('成片时长按每段倍速求和', () => {
    const two = splitSegmentAt(createFullSegment(60), 30, 60)
    const tuned = setSegmentSpeed(two, two[1].id, '2.0X')
    return firstError([
      expectNumber(exportDurationSec(toExportSegments(tuned)), 45, '30 + 30/2'),
      expectNumber(exportDurationSec(toExportSegments(createFullSegment(12))), 12, '单段 1.0x')
    ])
  }))

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

  cases.push(makeCase('片段常量：MIN_SEGMENT_SEC 为 10 秒，DEFAULT_CLIP_WINDOW_SEC 为 15 秒', () => {
    return firstError([
      expectNumber(MIN_SEGMENT_SEC, 10, 'MIN_SEGMENT_SEC'),
      expectNumber(DEFAULT_CLIP_WINDOW_SEC, 15, 'DEFAULT_CLIP_WINDOW_SEC')
    ])
  }))

  cases.push(makeCase('adjustSegmentStart：首段向左夹取至 0', () => {
    const segments = [makeSegment(0, 10, 30)]
    const clampedNeg = adjustSegmentStart(segments, 0, -5, 60)
    const clampedZero = adjustSegmentStart(segments, 0, 0, 60)
    const normal = adjustSegmentStart(segments, 0, 8, 60)
    return firstError([
      expectNumber(clampedNeg[0].startSec, 0, '负数夹取至 0'),
      expectNumber(clampedZero[0].startSec, 0, '0 秒夹取至 0'),
      expectNumber(normal[0].startSec, 8, '正常调整')
    ])
  }))

  cases.push(makeCase('adjustSegmentStart：前有片段时向左硬阻挡于前段终点', () => {
    const segments = [makeSegment(0, 0, 15), makeSegment(1, 30, 50)]
    const clampedStop = adjustSegmentStart(segments, 1, 10, 60)
    const clampedNear = adjustSegmentStart(segments, 1, 14.9, 60)
    const normal = adjustSegmentStart(segments, 1, 20, 60)
    return firstError([
      expectNumber(clampedStop[1].startSec, 15, '向左硬阻挡于 15'),
      expectNumber(clampedNear[1].startSec, 15, '向左硬阻挡于 15'),
      expectNumber(normal[1].startSec, 20, '20 秒合法')
    ])
  }))

  cases.push(makeCase('adjustSegmentStart：向右不能超过 endSec - 10', () => {
    const segments = [makeSegment(0, 0, 15), makeSegment(1, 30, 50)]
    const clampedMax = adjustSegmentStart(segments, 1, 45, 60)
    const clampedOver = adjustSegmentStart(segments, 1, 55, 60)
    const normal = adjustSegmentStart(segments, 1, 38, 60)
    return firstError([
      expectNumber(clampedMax[1].startSec, 40, '不能超过 endSec - 10 (40)'),
      expectNumber(clampedOver[1].startSec, 40, '超过 endSec 仍夹取至 40'),
      expectNumber(normal[1].startSec, 38, '38 秒合法')
    ])
  }))

  cases.push(makeCase('adjustSegmentEnd：向左不能低于 startSec + 10', () => {
    const segments = [makeSegment(0, 10, 30)]
    const clampedMin = adjustSegmentEnd(segments, 0, 15, 60)
    const clampedBelow = adjustSegmentEnd(segments, 0, 5, 60)
    const normal = adjustSegmentEnd(segments, 0, 25, 60)
    return firstError([
      expectNumber(clampedMin[0].endSec, 20, '不能低于 startSec + 10 (20)'),
      expectNumber(clampedBelow[0].endSec, 20, '低于 startSec 仍夹取至 20'),
      expectNumber(normal[0].endSec, 25, '25 秒合法')
    ])
  }))

  cases.push(makeCase('adjustSegmentEnd：后有片段时向右硬阻挡于后段起点', () => {
    const segments = [makeSegment(0, 0, 15), makeSegment(1, 30, 50)]
    const clampedStop = adjustSegmentEnd(segments, 0, 35, 60)
    const clampedBorder = adjustSegmentEnd(segments, 0, 30, 60)
    const normal = adjustSegmentEnd(segments, 0, 22, 60)
    return firstError([
      expectNumber(clampedStop[0].endSec, 30, '向右硬阻挡于 30'),
      expectNumber(clampedBorder[0].endSec, 30, '边界 30 秒'),
      expectNumber(normal[0].endSec, 22, '22 秒合法')
    ])
  }))

  cases.push(makeCase('adjustSegmentEnd：末段向右夹取至 totalDurationSec', () => {
    const segments = [makeSegment(0, 0, 15), makeSegment(1, 30, 50)]
    const clampedTotal = adjustSegmentEnd(segments, 1, 70, 60)
    const normal = adjustSegmentEnd(segments, 1, 58, 60)
    return firstError([
      expectNumber(clampedTotal[1].endSec, 60, '向右夹取至总时长 60'),
      expectNumber(normal[1].endSec, 58, '58 秒合法')
    ])
  }))

  cases.push(makeCase('removeSegment：物理移除片段并保持剩余片段有序', () => {
    const segments = [makeSegment(0, 0, 15), makeSegment(1, 20, 35), makeSegment(2, 40, 55)]
    const after = removeSegment(segments, 1)
    const empty = removeSegment([makeSegment(0, 10, 25)], 0)
    const unchanged = removeSegment(segments, 99)
    return firstError([
      expectNumber(after.length, 2, '移除中间段后剩余 2 段'),
      expectNumber(after[0].id, 0, '第一段留存'),
      expectNumber(after[1].id, 2, '第三段留存'),
      expectNumber(empty.length, 0, '单段移除后为空数组'),
      expectNumber(unchanged.length, 3, '不存在 id 不受影响')
    ])
  }))

  cases.push(makeCase('canSplitOrInsertAt：全片模式判定（片尾保底 10 秒）', () => {
    const segments = createFullSegment(60)
    return firstError([
      expectTrue(canSplitOrInsertAt(segments, 0, 60, true), '0 秒允许'),
      expectTrue(canSplitOrInsertAt(segments, 45, 60, true), '45 秒允许'),
      expectTrue(canSplitOrInsertAt(segments, 50, 60, true), '50 秒恰好剩 10 秒允许'),
      expectTrue(!canSplitOrInsertAt(segments, 51, 60, true), '51 秒剩 9 秒拒绝'),
      expectTrue(!canSplitOrInsertAt(segments, 55, 60, true), '55 秒剩 5 秒拒绝'),
      expectTrue(!canSplitOrInsertAt(segments, -1, 60, true), '负数拒绝'),
      expectTrue(!canSplitOrInsertAt(segments, 60, 60, true), '片尾拒绝')
    ])
  }))

  cases.push(makeCase('canSplitOrInsertAt：多片段模式段内切分与空档插入判定', () => {
    const shortSeg = [makeSegment(0, 0, 15)]
    const longSeg = [makeSegment(0, 0, 30)]
    const twoSegs = [makeSegment(0, 0, 15), makeSegment(1, 25, 40)]
    const threeSegs = [makeSegment(0, 0, 15), makeSegment(1, 20, 35), makeSegment(2, 40, 55)]
    return firstError([
      // 短于 20 秒段内无法两端均 >= 10 秒
      expectTrue(!canSplitOrInsertAt(shortSeg, 10, 60, false), '短于20秒段内拒绝'),
      expectTrue(!canSplitOrInsertAt(shortSeg, 5, 60, false), '短于20秒段内拒绝'),
      // >= 20 秒段内两端均 >= 10 秒
      expectTrue(!canSplitOrInsertAt(longSeg, 9, 60, false), '前侧不足10秒拒绝'),
      expectTrue(canSplitOrInsertAt(longSeg, 10, 60, false), '前侧刚好10秒允许'),
      expectTrue(canSplitOrInsertAt(longSeg, 15, 60, false), '中间允许'),
      expectTrue(canSplitOrInsertAt(longSeg, 20, 60, false), '后侧刚好10秒允许'),
      expectTrue(!canSplitOrInsertAt(longSeg, 21, 60, false), '后侧不足10秒拒绝'),
      // 空档中落刀
      expectTrue(canSplitOrInsertAt(twoSegs, 15, 60, false), '空档 15 秒距后段 10 秒允许'),
      expectTrue(!canSplitOrInsertAt(twoSegs, 16, 60, false), '空档 16 秒距后段 9 秒拒绝'),
      expectTrue(canSplitOrInsertAt(twoSegs, 50, 60, false), '末段后 50 秒距片尾 10 秒允许'),
      expectTrue(!canSplitOrInsertAt(twoSegs, 51, 60, false), '末段后 51 秒距片尾 9 秒拒绝'),
      // 达到上限 3 段拒绝
      expectTrue(!canSplitOrInsertAt(threeSegs, 16, 60, false), '已满3段拒绝落刀')
    ])
  }))

  cases.push(makeCase('splitOrInsertAt：全片模式生成默认 15 秒高光选区', () => {
    const raw = createFullSegment(60)
    const at10 = splitOrInsertAt(raw, 10, 60, true)
    const at50 = splitOrInsertAt(raw, 50, 60, true)
    const rejected = splitOrInsertAt(raw, 55, 60, true)
    return firstError([
      expectNumber(at10.length, 1, '生成单一高光选区'),
      expectNumber(at10[0].id, 0, '高光选区 id 为 0'),
      expectNumber(at10[0].startSec, 10, '起点为落刀点 10'),
      expectNumber(at10[0].endSec, 25, '终点为 10 + 15 = 25'),
      expectNumber(at50[0].startSec, 50, '起点 50'),
      expectNumber(at50[0].endSec, 60, '剩余不足 15 秒延伸至片尾 60'),
      expectNumber(rejected.length, 1, '不足10秒拒绝时原样返回'),
      expectNumber(rejected[0].endSec, 60, '结构不变')
    ])
  }))

  cases.push(makeCase('splitOrInsertAt：多片段模式段内切分与空档插入执行', () => {
    const longSeg = [makeSegment(0, 0, 30)]
    const splitResult = splitOrInsertAt(longSeg, 12, 60, false)

    const wideSegs = [makeSegment(0, 0, 15), makeSegment(1, 40, 55)]
    const gapInsert1 = splitOrInsertAt(wideSegs, 18, 60, false)

    const tightSegs = [makeSegment(0, 0, 15), makeSegment(1, 28, 55)]
    const gapInsert2 = splitOrInsertAt(tightSegs, 18, 60, false)

    const twoSegs = [makeSegment(0, 0, 15), makeSegment(1, 25, 40)]
    const tailInsert = splitOrInsertAt(twoSegs, 50, 60, false)

    return firstError([
      // 段内一分为二
      expectNumber(splitResult.length, 2, '切分成两段'),
      expectNumber(splitResult[0].id, 0, '前半段保留 id 0'),
      expectNumber(splitResult[0].startSec, 0, '前半段起点 0'),
      expectNumber(splitResult[0].endSec, 12, '前半段终点 12'),
      expectNumber(splitResult[1].id, 1, '后半段新 id 1'),
      expectNumber(splitResult[1].startSec, 12, '后半段起点 12'),
      expectNumber(splitResult[1].endSec, 30, '后半段终点 30'),
      // 空档插入默认 15 秒 (18 + 15 = 33 < 40)
      expectNumber(gapInsert1.length, 3, '空档插入后 3 段'),
      expectNumber(gapInsert1[1].startSec, 18, '新段起点 18'),
      expectNumber(gapInsert1[1].endSec, 33, '新段终点 18 + 15 = 33'),
      // 空档插入受后段阻挡截断 (18 + 15 = 33 > 28 -> 28)
      expectNumber(gapInsert2[1].startSec, 18, '紧凑空档新段起点 18'),
      expectNumber(gapInsert2[1].endSec, 28, '紧凑空档新段终点截断于 28'),
      // 片尾空档插入 (50 + 15 = 65 > 60 -> 60)
      expectNumber(tailInsert[2].startSec, 50, '片尾空档起点 50'),
      expectNumber(tailInsert[2].endSec, 60, '片尾空档终点 60')
    ])
  }))

  return cases
}
