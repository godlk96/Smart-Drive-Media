/**
 * `WorkMeta` 纯模型与作品文件名契约的用例。
 *
 * 不含 hypium 依赖，同一份用例既跑设备也跑 tools/offline-test.mjs。
 * run() 返回 '' 表示通过。
 *
 * 为什么这些用例值得钉死：sidecar 是**外部数据**（可能被手工改、被旧版本写、
 * 被写到一半杀进程），解析必须永不抛错；而「哪些文件算作品」由文件名契约决定，
 * native 的 concat 中间态与 JS 的素材落地副本都以 .mp4 结尾，宽松过滤拦不住。
 */

import { WorkMeta, parseWorkMeta, serializeWorkMeta, isWorkVideoFileName,
  workIdFromFileName, exportTimeFromFileName, findWorkByTrip, workSortKey,
  formatExportTime, formatClockDuration, formatRecordSummary, templateSlotCount,
  formatRecordSlotCount } from '../../../main/ets/model/WorkMeta'
import { TimelineCase, expectString, expectNumber, expectTrue, expectFalse, firstError } from './TestSupport'

function makeCase(name: string, run: () => string): TimelineCase {
  const item = new TimelineCase()
  item.name = name
  item.run = run
  return item
}

/** 一条最小可用的作品：软匹配用例共用。 */
function makeMeta(id: string, tripTitle: string, tripStartTs: number, exportedAt: number): WorkMeta {
  const meta = new WorkMeta()
  meta.id = id
  meta.tripTitle = tripTitle
  meta.tripStartTs = tripStartTs
  meta.exportedAt = exportedAt
  return meta
}

/** 逐位比较字符串数组：往返不许丢顺序，也不许把重复项去重。 */
function expectStringArray(actual: Array<string>, expected: Array<string>, label: string): string {
  if (actual.length !== expected.length) {
    return `${label}: 期望长度 ${expected.length}，实际 ${actual.length}`
  }
  for (let i = 0; i < expected.length; i++) {
    if (actual[i] !== expected[i]) {
      return `${label}[${i}]: 期望 "${expected[i]}"，实际 "${actual[i]}"`
    }
  }
  return ''
}

export function workMetaCases(): Array<TimelineCase> {
  const cases: Array<TimelineCase> = []

  cases.push(makeCase('空串返回 undefined', () => {
    return expectTrue(parseWorkMeta('') === undefined, '空串')
  }))

  cases.push(makeCase('坏 JSON 返回 undefined', () => {
    return expectTrue(parseWorkMeta('{oops') === undefined, '坏 JSON')
  }))

  cases.push(makeCase('缺 id 返回 undefined', () => {
    return expectTrue(parseWorkMeta('{"tripTitle":"x"}') === undefined, '缺 id')
  }))

  cases.push(makeCase('缺 playback 返回 undefined', () => {
    return expectTrue(parseWorkMeta('{"id":"w1"}') === undefined, '缺 playback')
  }))

  cases.push(makeCase('playback.segments 非数组返回 undefined', () => {
    return expectTrue(parseWorkMeta('{"id":"w1","playback":{"segments":1}}') === undefined, 'segments 非数组')
  }))

  cases.push(makeCase('合法条目补齐默认值', () => {
    const meta = parseWorkMeta('{"id":"w1","playback":{"playheadMs":0,"segments":[]}}')
    if (!meta) {
      return '解析失败'
    }
    return firstError([
      expectNumber(meta.tracks.front.length, 0, 'tracks.front'),
      expectNumber(meta.exportedAt, 0, 'exportedAt'),
      expectNumber(meta.schemaVersion, 1, 'schemaVersion'),
      expectString(meta.templateId, '', 'templateId')
    ])
  }))

  cases.push(makeCase('序列化→解析往返保真', () => {
    const meta = new WorkMeta()
    meta.id = 'w-rt'
    meta.exportedAt = 1759296000000
    meta.templateId = 'T3'
    const back = parseWorkMeta(serializeWorkMeta(meta))
    if (!back) {
      return '往返解析失败'
    }
    return firstError([
      expectString(back.id, 'w-rt', 'id'),
      expectNumber(back.exportedAt, 1759296000000, 'exportedAt'),
      expectString(back.templateId, 'T3', 'templateId')
    ])
  }))

  cases.push(makeCase('轨道顺序与重复往返不丢', () => {
    const meta = new WorkMeta()
    meta.id = 'w-track'
    meta.tracks.front = ['a.mp4', 'b.mp4', 'a.mp4']
    const back = parseWorkMeta(serializeWorkMeta(meta))
    if (!back) {
      return '往返解析失败'
    }
    return expectStringArray(back.tracks.front, ['a.mp4', 'b.mp4', 'a.mp4'], 'front 轨道')
  }))

  cases.push(makeCase('作品视频名严格匹配', () => {
    return expectTrue(isWorkVideoFileName('SmartDrive_Export_20261018_210400.mp4'), '标准名')
  }))

  cases.push(makeCase('带后缀的作品名也匹配', () => {
    return expectTrue(isWorkVideoFileName('SmartDrive_Export_20261018_210400_1.mp4'), '撞名后缀')
  }))

  cases.push(makeCase('native 的 concat 残留不匹配', () => {
    return expectFalse(
      isWorkVideoFileName('SmartDrive_Export_20261018_210400.mp4.tmp.front.concat.mp4'),
      'concat 残留'
    )
  }))

  cases.push(makeCase('JS 的素材落地副本不匹配', () => {
    return expectFalse(isWorkVideoFileName('input_1759296000000_0.mp4'), '素材副本')
  }))

  cases.push(makeCase('sidecar / 封面不是视频', () => {
    return firstError([
      expectFalse(isWorkVideoFileName('SmartDrive_Export_20261018_210400.json'), 'json'),
      expectFalse(isWorkVideoFileName('SmartDrive_Export_20261018_210400.jpg'), 'jpg')
    ])
  }))

  cases.push(makeCase('空串与乱码不匹配', () => {
    return firstError([
      expectFalse(isWorkVideoFileName(''), '空串'),
      expectFalse(isWorkVideoFileName('SmartDrive_Export_2026.mp4'), '位数不足')
    ])
  }))

  cases.push(makeCase('取作品 id', () => {
    return expectString(
      workIdFromFileName('SmartDrive_Export_20261018_210400.mp4'),
      'SmartDrive_Export_20261018_210400',
      'id'
    )
  }))

  cases.push(makeCase('从文件名取导出时刻', () => {
    const expected = new Date(2026, 9, 18, 21, 4, 0)
    return expectNumber(
      exportTimeFromFileName('SmartDrive_Export_20261018_210400.mp4'),
      expected.getTime(),
      '时刻'
    )
  }))

  cases.push(makeCase('文件名时间戳非法返回 0', () => {
    return expectNumber(exportTimeFromFileName('SmartDrive_Export_99999999_999999.mp4'), 0, '非法')
  }))

  cases.push(makeCase('软匹配命中同标题同起点', () => {
    const meta = makeMeta('w1', '10月1日 周三', 1759296000000, 100)
    const hit = findWorkByTrip([meta], '10月1日 周三', 1759296000000)
    return expectTrue(hit !== undefined && hit.id === 'w1', '命中')
  }))

  cases.push(makeCase('软匹配取最近一条', () => {
    const older = makeMeta('old', '10月1日 周三', 1759296000000, 100)
    const newer = makeMeta('new', '10月1日 周三', 1759296000000, 200)
    const hit = findWorkByTrip([older, newer], '10月1日 周三', 1759296000000)
    return expectString(hit ? hit.id : '', 'new', '最近一条')
  }))

  cases.push(makeCase('软匹配不命中返回 undefined', () => {
    const meta = makeMeta('w1', '10月1日 周三', 1759296000000, 100)
    return expectTrue(findWorkByTrip([meta], '10月1日 周三', 1759296000001) === undefined, '起点差 1ms')
  }))

  cases.push(makeCase('软匹配标题为空直接不命中', () => {
    const meta = makeMeta('w1', '10月1日 周三', 1759296000000, 100)
    return expectTrue(findWorkByTrip([meta], '', 1759296000000) === undefined, '标题空')
  }))

  cases.push(makeCase('排序键：有 meta 用 exportedAt', () => {
    const meta = new WorkMeta()
    meta.exportedAt = 123456
    return expectNumber(workSortKey(meta, 'anything.mp4'), 123456, '有 meta')
  }))

  cases.push(makeCase('排序键：无 meta 用文件名时刻', () => {
    const expected = new Date(2026, 9, 18, 21, 4, 0)
    return expectNumber(
      workSortKey(undefined, 'SmartDrive_Export_20261018_210400.mp4'),
      expected.getTime(),
      '无 meta'
    )
  }))

  cases.push(makeCase('展示格式化沿用旧值', () => {
    return firstError([
      expectString(formatExportTime(0), '导出时间未知', '导出时间'),
      expectString(formatClockDuration(32000), '00:32', '时长'),
      expectString(formatRecordSummary(2, 32000), '2 段 · 00:32', '摘要'),
      expectNumber(templateSlotCount('T5'), 1, '机位数'),
      expectString(formatRecordSlotCount('T5'), '1 机位', '机位串'),
      expectString(formatRecordSlotCount('TX'), '', '未知模板')
    ])
  }))

  return cases
}
