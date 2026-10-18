/**
 * 「我的剪辑」的作品记录模型。
 *
 * 一条记录 = 一次导出 = 一件作品。记录里同时握着「成片在哪」（albumUri）
 * 和「怎么剪的」（snapshot 里的 ExportSnapshot JSON）。
 *
 * 本文件**不得**导入 @ohos.* / @kit.*：它是纯数据 + 纯函数，要被
 * tools/offline-test.mjs 直接跑（离线桩遇到裸导入会直接抛错）。
 * 持久化在 service/EditHistoryService.ets，不在这里。
 *
 * 两层数据是隔离的（设计稿 3.2）：
 *   - 记录层（本文件）由 App 自己完全掌控，增删改都做得到；
 *   - 成片层（相册里那条 mp4）受系统受控权限约束，只能就地覆写不能删。
 * 所以记录存的是**指针**，不是视频副本；相册里删了成片，记录就会悬空。
 */

/** 记录结构的版本号。将来改字段时靠它做迁移（设计稿 7.5）。 */
export const EDIT_RECORD_SCHEMA_VERSION: number = 1

/** 记录 id 前缀，便于日志与调试时一眼认出。 */
const RECORD_ID_PREFIX: string = 'rec_'

export class EditRecord {
  /** `rec_<epochMs>_<000-999>` */
  id: string = ''
  /** 仅作线索，**不作为身份依据**（tripId 会因源素材增删而整体重编号，见设计稿 4.4） */
  tripId: string = ''
  /** 「10月1日 周三」，还原时与现场行程交叉校验 */
  tripTitle: string = ''
  /** 身份校验用（毫秒时间戳） */
  tripStartTs: number = 0
  tripEndTs: number = 0
  /** 相册成片 URI —— 覆盖时就是重新打开它并 TRUNC 写入 */
  albumUri: string = ''
  /** 真实的新文件名（覆盖时相册条目的物理名会保留旧的，这个字段记的是新名字） */
  fileName: string = ''
  /** 导出完成时刻（毫秒时间戳），列表按它倒序 */
  exportedAt: number = 0
  /** 成片时长（毫秒） */
  durationMs: number = 0
  segmentCount: number = 0
  /** T1..T6 */
  templateId: string = ''
  /** ExportSnapshot 深拷贝的 JSON 字符串 —— 还原的参数权威来源 */
  snapshot: string = ''
  /** 成片首帧缩略图缓存路径，由列表异步补；空串表示还没取到 */
  coverPath: string = ''
  schemaVersion: number = EDIT_RECORD_SCHEMA_VERSION
}

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`
}

function pad3(value: number): string {
  if (value < 10) {
    return `00${value}`
  }
  if (value < 100) {
    return `0${value}`
  }
  return `${value}`
}

/**
 * 生成记录 id。
 * salt 传 Math.random()，取到千分位即可 —— 同一毫秒内连点两次导出也不会撞。
 */
export function makeRecordId(nowMs: number, salt: number): string {
  const safeMs = Math.max(0, Math.floor(nowMs))
  const safeSalt = Math.max(0, Math.floor(Math.abs(salt) * 1000)) % 1000
  return `${RECORD_ID_PREFIX}${safeMs}_${pad3(safeSalt)}`
}

/** 把来源对象的每个字段按类型收敛，缺项/错型一律退回默认值。 */
function normalizeRecord(source: EditRecord): EditRecord | undefined {
  if (!source) {
    return undefined
  }
  const id = typeof source.id === 'string' ? source.id : ''
  if (id.length === 0) {
    return undefined
  }
  const record = new EditRecord()
  record.id = id
  record.tripId = typeof source.tripId === 'string' ? source.tripId : ''
  record.tripTitle = typeof source.tripTitle === 'string' ? source.tripTitle : ''
  record.tripStartTs = typeof source.tripStartTs === 'number' ? source.tripStartTs : 0
  record.tripEndTs = typeof source.tripEndTs === 'number' ? source.tripEndTs : 0
  record.albumUri = typeof source.albumUri === 'string' ? source.albumUri : ''
  record.fileName = typeof source.fileName === 'string' ? source.fileName : ''
  record.exportedAt = typeof source.exportedAt === 'number' ? source.exportedAt : 0
  record.durationMs = typeof source.durationMs === 'number' ? source.durationMs : 0
  record.segmentCount = typeof source.segmentCount === 'number' ? source.segmentCount : 0
  record.templateId = typeof source.templateId === 'string' ? source.templateId : ''
  record.snapshot = typeof source.snapshot === 'string' ? source.snapshot : ''
  record.coverPath = typeof source.coverPath === 'string' ? source.coverPath : ''
  record.schemaVersion =
    typeof source.schemaVersion === 'number' ? source.schemaVersion : EDIT_RECORD_SCHEMA_VERSION
  return record
}

/**
 * 解析持久化的记录列表。
 *
 * 刻意**永不抛错**：这份数据来自磁盘，可能因为版本回退、手工改文件、
 * 写到一半被杀而损坏。坏数据必须退化成空列表让页面能开，而不是让首页崩掉。
 * 单条损坏只丢那一条，不牵连整个列表。
 */
export function parseEditRecords(raw: string): Array<EditRecord> {
  if (raw.length === 0) {
    return []
  }
  let parsed: Array<EditRecord> = []
  try {
    parsed = JSON.parse(raw) as Array<EditRecord>
  } catch (error) {
    return []
  }
  if (!Array.isArray(parsed)) {
    return []
  }
  const out: Array<EditRecord> = []
  for (let i = 0; i < parsed.length; i++) {
    const record = normalizeRecord(parsed[i])
    if (record) {
      out.push(record)
    }
  }
  return sortRecordsNewestFirst(out)
}

export function serializeEditRecords(records: Array<EditRecord>): string {
  return JSON.stringify(records)
}

/** 导出时间倒序。**不原地改入参** —— 调用方常常传的是列表状态本身。 */
export function sortRecordsNewestFirst(records: Array<EditRecord>): Array<EditRecord> {
  const copy = records.slice()
  copy.sort((a: EditRecord, b: EditRecord) => b.exportedAt - a.exportedAt)
  return copy
}

export function findRecordById(records: Array<EditRecord>, id: string): EditRecord | undefined {
  for (let i = 0; i < records.length; i++) {
    if (records[i].id === id) {
      return records[i]
    }
  }
  return undefined
}

/** 某趟行程的全部作品，按导出时间倒序。 */
export function recordsForTrip(records: Array<EditRecord>, tripId: string): Array<EditRecord> {
  return sortRecordsNewestFirst(records.filter((item: EditRecord) => item.tripId === tripId))
}

/** 覆盖的目标：「该行程最近导出过的那一条」（设计稿 5.1）。 */
export function findLatestRecordForTrip(
  records: Array<EditRecord>,
  tripId: string
): EditRecord | undefined {
  const matched = recordsForTrip(records, tripId)
  return matched.length > 0 ? matched[0] : undefined
}

/**
 * 写入一条记录：同 id 原地替换（覆盖场景，id 必须不变），否则追加。
 * 两种情况下都按导出时间重排，因为覆盖会把 exportedAt 刷新成现在。
 */
export function upsertRecord(
  records: Array<EditRecord>,
  record: EditRecord
): Array<EditRecord> {
  const out: Array<EditRecord> = []
  let replaced = false
  for (let i = 0; i < records.length; i++) {
    if (records[i].id === record.id) {
      out.push(record)
      replaced = true
    } else {
      out.push(records[i])
    }
  }
  if (!replaced) {
    out.push(record)
  }
  return sortRecordsNewestFirst(out)
}

export function removeRecords(
  records: Array<EditRecord>,
  ids: Array<string>
): Array<EditRecord> {
  return records.filter((item: EditRecord) => ids.indexOf(item.id) < 0)
}

/**
 * 记录与现场行程的身份校验。
 *
 * **不能只信 tripId**：它的构造含「该分组在整次扫描里的序号」
 * （CoreBridge.ets:493），用户删掉靠前的源素材，后面的行程会整体重编号，
 * 一个存下来的 tripId 会静默指向另一趟行程。所以用
 * (tripTitle, tripStartTs) 这对更稳定的字段交叉验证。
 * 标题为空一律判不匹配 —— 那说明记录本身就是残缺的，宁可报错也不能猜。
 */
export function recordMatchesTrip(
  record: EditRecord,
  tripTitle: string,
  tripStartTs: number
): boolean {
  if (tripTitle.length === 0) {
    return false
  }
  return record.tripTitle === tripTitle && record.tripStartTs === tripStartTs
}

/** 「10月18日 21:04 导出」。时间戳非法时给占位串，卡片不塌。 */
export function formatExportTime(exportedAt: number): string {
  if (exportedAt <= 0) {
    return '导出时间未知'
  }
  const date = new Date(exportedAt)
  return `${date.getMonth() + 1}月${date.getDate()}日 ${pad2(date.getHours())}:${pad2(date.getMinutes())} 导出`
}

/** `00:32` / `1:02:03`。负数兜底 0。 */
export function formatClockDuration(durationMs: number): string {
  const totalSec = Math.max(0, Math.floor(durationMs / 1000))
  const hour = Math.floor(totalSec / 3600)
  const minute = Math.floor((totalSec % 3600) / 60)
  const second = totalSec % 60
  if (hour > 0) {
    return `${hour}:${pad2(minute)}:${pad2(second)}`
  }
  return `${pad2(minute)}:${pad2(second)}`
}

/** 「2 段 · 00:32」 */
export function formatRecordSummary(segmentCount: number, durationMs: number): string {
  const safeCount = segmentCount > 0 ? Math.floor(segmentCount) : 0
  return `${safeCount} 段 · ${formatClockDuration(durationMs)}`
}
