/**
 * 「我的剪辑」历史记录纯函数用例。
 *
 * 与其它 *Cases.ets 一样**不含 hypium 依赖**：同一份用例既能被
 * entry/src/ohosTest 的 hypium 包装跑在设备上，也能被 tools/offline-test.mjs
 * 直接跑在本机。run() 返回 '' 表示通过，否则返回失败原因。
 */

import { EditRecord, EDIT_RECORD_SCHEMA_VERSION, makeRecordId, parseEditRecords,
  serializeEditRecords, sortRecordsNewestFirst, findRecordById, recordsForTrip,
  findLatestRecordForTrip, upsertRecord, removeRecords, recordMatchesTrip,
  formatExportTime, formatClockDuration, formatRecordSummary,
  templateSlotCount, formatRecordSlotCount,
  limitRecords, fitRecordsUnderBytes } from '../../../main/ets/model/EditRecord'
import { TimelineCase, expectString, expectNumber, expectTrue, expectFalse, firstError } from './TestSupport'

function makeCase(name: string, run: () => string): TimelineCase {
  const item = new TimelineCase()
  item.name = name
  item.run = run
  return item
}

/** 本地补零。EditRecord 内部的 pad2 不导出，这里自己写一份。 */
function two(value: number): string {
  return value < 10 ? `0${value}` : `${value}`
}

/** 只填用例真正会读到的字段，其余留类默认值 */
function makeRecord(id: string, tripId: string, exportedAt: number): EditRecord {
  const record = new EditRecord()
  record.id = id
  record.tripId = tripId
  record.tripTitle = '10月1日 周三'
  record.tripStartTs = 1759296000000
  record.tripEndTs = 1759296720000
  record.albumUri = `file://media/Photo/${id}/IMG.mp4`
  record.fileName = 'SmartDrive_Export_20261018_210400.mp4'
  record.exportedAt = exportedAt
  record.durationMs = 32000
  record.segmentCount = 2
  record.templateId = 'T5'
  record.snapshot = '{}'
  return record
}

export function editHistoryCases(): Array<TimelineCase> {
  const cases: Array<TimelineCase> = []

  cases.push(makeCase('坏 JSON 返回空列表', () => {
    return expectNumber(parseEditRecords('{oops').length, 0, '坏 JSON')
  }))

  cases.push(makeCase('非数组 JSON 返回空列表', () => {
    return expectNumber(parseEditRecords('{"a":1}').length, 0, '非数组')
  }))

  cases.push(makeCase('空串返回空列表', () => {
    return expectNumber(parseEditRecords('').length, 0, '空串')
  }))

  cases.push(makeCase('缺 id 的条目被丢弃', () => {
    return expectNumber(parseEditRecords('[{"tripId":"t"}]').length, 0, '缺 id')
  }))

  cases.push(makeCase('合法条目补齐默认值', () => {
    const parsed = parseEditRecords('[{"id":"r1"}]')
    return firstError([
      expectNumber(parsed.length, 1, '长度'),
      expectString(parsed[0].tripTitle, '', '标题默认空串'),
      expectNumber(parsed[0].exportedAt, 0, '导出时间默认 0'),
      expectNumber(parsed[0].schemaVersion, EDIT_RECORD_SCHEMA_VERSION, 'schema 版本')
    ])
  }))

  cases.push(makeCase('解析结果按导出时间倒序', () => {
    const old = makeRecord('old', 'tripA', 1000)
    const fresh = makeRecord('new', 'tripA', 2000)
    const input: Array<EditRecord> = [old, fresh]
    const parsed = parseEditRecords(serializeEditRecords([old, fresh]))
    const sorted = sortRecordsNewestFirst(input)
    return firstError([
      expectString(parsed[0].id, 'new', '解析后倒序'),
      expectString(sorted[0].id, 'new', '排序函数倒序'),
      expectNumber(sorted.length, 2, '排序不改长度'),
      expectString(input[0].id, 'old', '入参未被原地排序')
    ])
  }))

  cases.push(makeCase('序列化→解析往返保真', () => {
    const record = makeRecord('r1', 'tripA', 1000)
    const back = parseEditRecords(serializeEditRecords([record]))
    return firstError([
      expectNumber(back.length, 1, '长度'),
      expectNumber(back[0].tripStartTs, 1759296000000, '起点时间'),
      expectNumber(back[0].durationMs, 32000, '成片时长'),
      expectString(back[0].albumUri, record.albumUri, '相册 URI')
    ])
  }))

  cases.push(makeCase('同 id 覆盖后只留一条', () => {
    const a = makeRecord('a', 'tripA', 1000)
    const a2 = makeRecord('a', 'tripA', 5000)
    const merged = upsertRecord([a], a2)
    return firstError([
      expectNumber(merged.length, 1, '只留一条'),
      expectNumber(merged[0].exportedAt, 5000, '取到新值')
    ])
  }))

  cases.push(makeCase('覆盖后重排到最前', () => {
    const old = makeRecord('old', 'tripA', 1000)
    const mid = makeRecord('mid', 'tripA', 2000)
    const oldNew = makeRecord('old', 'tripA', 3000)
    const merged = upsertRecord([old, mid], oldNew)
    return firstError([
      expectNumber(merged.length, 2, '长度不变'),
      expectString(merged[0].id, 'old', '重排到最前'),
      expectNumber(merged[0].exportedAt, 3000, '用新值')
    ])
  }))

  cases.push(makeCase('新 id 追加', () => {
    const a = makeRecord('a', 'tripA', 1000)
    const b = makeRecord('b', 'tripA', 2000)
    return expectNumber(upsertRecord([a], b).length, 2, '追加')
  }))

  cases.push(makeCase('删除按 id 列表生效', () => {
    const a = makeRecord('a', 'tripA', 1000)
    const b = makeRecord('b', 'tripA', 2000)
    const left = removeRecords([a, b], ['a'])
    return firstError([
      expectNumber(left.length, 1, '剩一条'),
      expectString(left[0].id, 'b', '剩下 b')
    ])
  }))

  cases.push(makeCase('删除不存在的 id 无副作用', () => {
    const a = makeRecord('a', 'tripA', 1000)
    return expectNumber(removeRecords([a], ['zzz']).length, 1, '无副作用')
  }))

  cases.push(makeCase('按行程取记录按时间倒序', () => {
    const a1 = makeRecord('a1', 'tripA', 1000)
    const a2 = makeRecord('a2', 'tripA', 3000)
    const b = makeRecord('b', 'tripB', 2000)
    const mine = recordsForTrip([a1, a2, b], 'tripA')
    return firstError([
      expectNumber(mine.length, 2, '只取本行程'),
      expectString(mine[0].id, 'a2', '倒序取最新')
    ])
  }))

  cases.push(makeCase('取最近一条', () => {
    const a1 = makeRecord('a1', 'tripA', 1000)
    const a2 = makeRecord('a2', 'tripA', 3000)
    const latest = findLatestRecordForTrip([a1, a2], 'tripA')
    return expectString(latest ? latest.id : '', 'a2', '最近一条')
  }))

  cases.push(makeCase('无记录时取最近返回 undefined', () => {
    return expectTrue(findLatestRecordForTrip([], 'tripA') === undefined, '空列表')
  }))

  cases.push(makeCase('按 id 查找', () => {
    const a = makeRecord('a', 'tripA', 1000)
    const b = makeRecord('b', 'tripA', 2000)
    const found = findRecordById([a, b], 'b')
    return expectString(found ? found.id : '', 'b', '按 id 查找')
  }))

  cases.push(makeCase('身份校验：标题+起点都对才通过', () => {
    const record = makeRecord('a', 'tripA', 1000)
    return expectTrue(recordMatchesTrip(record, '10月1日 周三', 1759296000000), '匹配')
  }))

  cases.push(makeCase('身份校验：起点差 1ms 就不通过', () => {
    const record = makeRecord('a', 'tripA', 1000)
    return expectFalse(recordMatchesTrip(record, '10月1日 周三', 1759296000001), '起点漂移')
  }))

  cases.push(makeCase('身份校验：标题为空直接不通过', () => {
    const record = makeRecord('a', 'tripA', 1000)
    return expectFalse(recordMatchesTrip(record, '', 1759296000000), '空标题')
  }))

  cases.push(makeCase('导出时间文案：日期用本机时区算', () => {
    const stamp = 1759296000000
    const date = new Date(stamp)
    const expected = `${date.getMonth() + 1}月${date.getDate()}日 ${two(date.getHours())}:${two(date.getMinutes())} 导出`
    return expectString(formatExportTime(stamp), expected, '时间')
  }))

  cases.push(makeCase('导出时间文案以「 导出」结尾', () => {
    return expectTrue(formatExportTime(1759296000000).endsWith(' 导出'), '后缀')
  }))

  cases.push(makeCase('导出时间为 0 给占位', () => {
    return expectString(formatExportTime(0), '导出时间未知', '占位')
  }))

  cases.push(makeCase('时长不足 1 小时', () => {
    return expectString(formatClockDuration(32000), '00:32', 'mm:ss')
  }))

  cases.push(makeCase('时长跨小时', () => {
    return expectString(formatClockDuration(3723000), '1:02:03', 'h:mm:ss')
  }))

  cases.push(makeCase('负数时长兜底 0', () => {
    return expectString(formatClockDuration(-5), '00:00', '负数')
  }))

  cases.push(makeCase('段数摘要', () => {
    return expectString(formatRecordSummary(2, 32000), '2 段 · 00:32', '摘要')
  }))

  cases.push(makeCase('段数为 0 也给 0 段', () => {
    return expectString(formatRecordSummary(0, 0), '0 段 · 00:00', '零段')
  }))

  // ---- 机位数文案（卡片上只剩「导出时间 / N 机位」两行）----

  cases.push(makeCase('机位数与模板槽位一致', () => {
    return firstError([
      expectNumber(templateSlotCount('T1'), 2, 'T1 上下双录'),
      expectNumber(templateSlotCount('T2'), 3, 'T2 倒品字'),
      expectNumber(templateSlotCount('T3'), 2, 'T3 左右分屏'),
      expectNumber(templateSlotCount('T4'), 3, 'T4 三分屏'),
      expectNumber(templateSlotCount('T5'), 1, 'T5 单视角'),
      expectNumber(templateSlotCount('T6'), 4, 'T6 四机位')
    ])
  }))

  cases.push(makeCase('未知模板机位数为 0', () => {
    return firstError([
      expectNumber(templateSlotCount(''), 0, '空串'),
      expectNumber(templateSlotCount('T99'), 0, '不存在的模板')
    ])
  }))

  cases.push(makeCase('机位文案', () => {
    return firstError([
      expectString(formatRecordSlotCount('T6'), '4 机位', '四机位'),
      expectString(formatRecordSlotCount('T5'), '1 机位', '单机位')
    ])
  }))

  cases.push(makeCase('未知模板的机位文案为空串，好让卡片整行不画', () => {
    return expectString(formatRecordSlotCount('T99'), '', '空串')
  }))

  cases.push(makeCase('生成的 id 带前缀且唯一', () => {
    const first = makeRecordId(1000, 0.5)
    const second = makeRecordId(1000, 0.25)
    return firstError([
      expectTrue(first.startsWith('rec_'), '前缀'),
      expectTrue(first !== second, '唯一'),
      expectString(makeRecordId(1234567890, 0.5), 'rec_1234567890_500', '确定格式')
    ])
  }))

  // ---- 条数上限与体积裁剪（spec：「记录列表必须自我约束」）----
  // 全部记录存在 preferences 的**一个** value 里，而 preferences 有单值上限。
  // 不裁剪的话，导出次数一多，写入会开始失败，历史记录整批停更。

  cases.push(makeCase('未超上限时原样返回', () => {
    const records: Array<EditRecord> = [makeRecord('rec_a', 'trip-1', 300),
      makeRecord('rec_b', 'trip-1', 200)]
    const out = limitRecords(records, 50)
    return firstError([
      expectNumber(out.length, 2, '条数'),
      expectString(out[0].id, 'rec_a', '首条不变')
    ])
  }))

  cases.push(makeCase('超上限时淘汰最旧的，保留最新在前的顺序', () => {
    const records: Array<EditRecord> = [makeRecord('rec_new', 'trip-1', 300),
      makeRecord('rec_mid', 'trip-1', 200),
      makeRecord('rec_old', 'trip-1', 100)]
    const out = limitRecords(records, 2)
    return firstError([
      expectNumber(out.length, 2, '条数'),
      expectString(out[0].id, 'rec_new', '最新还在'),
      expectString(out[1].id, 'rec_mid', '次新还在'),
      expectTrue(records.length === 3, '不修改入参')
    ])
  }))

  cases.push(makeCase('max 非正数时不裁剪', () => {
    const records: Array<EditRecord> = [makeRecord('rec_a', 'trip-1', 300),
      makeRecord('rec_b', 'trip-1', 200)]
    return expectNumber(limitRecords(records, 0).length, 2, 'max=0')
  }))

  cases.push(makeCase('体积超预算时从最旧的开始丢', () => {
    const records: Array<EditRecord> = []
    for (let i = 0; i < 5; i++) {
      // 每条约 1KB 的 snapshot，5 条远大于 2KB 预算
      const item = makeRecord(`rec_${i}`, 'trip-1', 500 - i)
      item.snapshot = `{"pad":"${'x'.repeat(1000)}"}`
      records.push(item)
    }
    const budget = 2200
    const out = fitRecordsUnderBytes(records, budget)
    return firstError([
      expectTrue(out.length < 5, '确实丢了'),
      expectTrue(out.length >= 1, '至少留一条'),
      expectString(out[0].id, 'rec_0', '丢的是尾部最旧的'),
      expectTrue(serializeEditRecords(out).length <= budget, '裁剪后不超预算')
    ])
  }))

  cases.push(makeCase('体积裁剪至少留一条，哪怕一条就超预算', () => {
    const item = makeRecord('rec_huge', 'trip-1', 100)
    item.snapshot = `{"pad":"${'x'.repeat(5000)}"}`
    const out = fitRecordsUnderBytes([item], 10)
    return firstError([
      expectNumber(out.length, 1, '保住最后一条'),
      expectString(out[0].id, 'rec_huge', '就是它')
    ])
  }))

  cases.push(makeCase('体积预算非正数时原样返回', () => {
    const records: Array<EditRecord> = [makeRecord('rec_a', 'trip-1', 300)]
    return expectNumber(fitRecordsUnderBytes(records, 0).length, 1, 'budget=0')
  }))

  return cases
}
