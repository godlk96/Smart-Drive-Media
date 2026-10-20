/**
 * 「作品库」的 sidecar 数据模型与文件名契约。
 *
 * 一件作品 = `filesDir/exports/` 下三个**同名**文件：
 *   - `<id>.mp4`：成片本体；
 *   - `<id>.json`：本文件定义的 `WorkMeta`（sidecar，元数据权威来源）；
 *   - `<id>.jpg`：封面首帧。
 * 列表页扫一遍目录，凡是满足 `isWorkVideoFileName` 的 mp4 就算一件作品，
 * 同名 json 有则完整卡片、无则降级卡片。
 *
 * 本文件**不得**导入 @ohos.* / @kit.*：它是纯数据 + 纯函数，要被
 * tools/offline-test.mjs 直接跑（离线桩遇到裸导入会直接抛错）。
 * 唯一的外部依赖是 `./Models` 的 `PlaybackState` 类型（编译期擦除，不进运行时）。
 *
 * 为什么 `templateId` 存 `string` 而不是 `TemplateId`：sidecar 是**外部数据**，
 * 可能被手工改、被旧版本写，含未知值。收敛成合法模板是 Task 3 的事，这里只保证
 * 「读得进来、不抛错」。
 */

import { PlaybackState } from './Models'

/** sidecar 结构的版本号。将来改字段时靠它做迁移。 */
export const WORK_META_SCHEMA_VERSION: number = 1

/**
 * 四条轨道：与 `ExportComposeRequest` 的 frontUris/backUris/sideUris/side2Uris 一一对应。
 *
 * 元素是**实际送进 native 的源片段文件名**，有序、含重复 —— 这是还原时的身份锚。
 * 刻意不记「机位 → 全部片段」：`resolveTemplateTracks` / `alignSideUrisByFront`
 * 对着导出那一刻的现场片段列表跑，按机位分组装不回那条带重复的轨道（设计稿 3.2）。
 */
export class WorkTracks {
  front: Array<string> = []
  back: Array<string> = []
  side: Array<string> = []
  side2: Array<string> = []
}

export class WorkMeta {
  schemaVersion: number = WORK_META_SCHEMA_VERSION
  /** 作品 id = 文件基名 */
  id: string = ''
  /** 首次导出时刻（覆盖不刷新） */
  createdAt: number = 0
  /** 最近一次导出时刻（覆盖会刷新），列表按它倒序 */
  exportedAt: number = 0
  /** 「10月1日 周三」/「10月1日 合并行程」，卡片展示用 */
  tripTitle: string = ''
  tripStartTs: number = 0
  tripEndTs: number = 0
  tracks: WorkTracks = new WorkTracks()
  /** T1..T6；存 string 以容纳未知值（见文件头注释） */
  templateId: string = ''
  /**
   * 用户改的那部分参数（对应 `ExportSnapshot.playback`）。
   * **非空**：缺 playback 的 sidecar 一律判为损坏（`parseWorkMeta` 返回 undefined），
   * 所以这里给一个空兜底，调用方不必到处判空。
   */
  playback: PlaybackState = { playheadMs: 0, segments: [] }
  watermarkEnabled: boolean = false
  /** 卡片展示用；从 playback.segments 推导亦可，存下来省一次计算 */
  segmentCount: number = 0
  durationMs: number = 0
}

/**
 * 作品视频名的**严格**契约：`SmartDrive_Export_YYYYMMDD_HHMMSS[_n].mp4`。
 *
 * 必须锚定整串（^...$）而不是「以 .mp4 结尾且不含 .tmp」这类宽松规则：
 * native 的 concat 中间态（`<out>.mp4.tmp.front.concat.mp4`）和 JS 的素材落地副本
 * （`input_<ts>_<n>.mp4`）都以 .mp4 结尾，宽松过滤拦不住，会把合成垃圾当作品列出来。
 * 撞名后缀 `_n` 是同一秒内导出第二件时补的序号。
 */
const WORK_VIDEO_NAME_PATTERN: RegExp = /^SmartDrive_Export_\d{8}_\d{6}(_\d+)?\.mp4$/

/** 从文件名里抠出 `YYYYMMDD_HHMMSS`（不锚定尾部，容忍撞名后缀与扩展名）。 */
const EXPORT_STAMP_PATTERN: RegExp = /SmartDrive_Export_(\d{8})_(\d{6})/

export function isWorkVideoFileName(name: string): boolean {
  return WORK_VIDEO_NAME_PATTERN.test(name)
}

/** 作品 id = 去掉扩展名的文件基名（`<id>.mp4` → `<id>`）。 */
export function workIdFromFileName(name: string): string {
  const dot = name.lastIndexOf('.')
  return dot > 0 ? name.substring(0, dot) : name
}

/**
 * 从文件名解析导出时刻（毫秒时间戳）。解析不出或月/日/时越界时返回 0。
 *
 * 越界必须自己拦：`new Date(9999, 99, ...)` 会悄悄滚到下个世纪，
 * 排序键会因此把垃圾文件顶到最前。用 `Date` 的本地时区构造，与展示层一致。
 */
export function exportTimeFromFileName(name: string): number {
  const matched = name.match(EXPORT_STAMP_PATTERN)
  if (!matched) {
    return 0
  }
  const datePart = matched[1]
  const timePart = matched[2]
  const year = Number.parseInt(datePart.substring(0, 4), 10)
  const month = Number.parseInt(datePart.substring(4, 6), 10)
  const day = Number.parseInt(datePart.substring(6, 8), 10)
  const hour = Number.parseInt(timePart.substring(0, 2), 10)
  const minute = Number.parseInt(timePart.substring(2, 4), 10)
  const second = Number.parseInt(timePart.substring(4, 6), 10)
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 59) {
    return 0
  }
  return new Date(year, month - 1, day, hour, minute, second).getTime()
}

/** 把来源数组收敛成「只含字符串」的数组：非数组退化成空，混入的非串元素丢掉。 */
function normalizeTrack(source: Array<string> | undefined): Array<string> {
  const out: Array<string> = []
  if (!Array.isArray(source)) {
    return out
  }
  for (let i = 0; i < source.length; i++) {
    const item = source[i]
    if (typeof item === 'string') {
      out.push(item)
    }
  }
  return out
}

function normalizeTracks(source: WorkTracks | undefined): WorkTracks {
  const tracks = new WorkTracks()
  if (!source) {
    return tracks
  }
  tracks.front = normalizeTrack(source.front)
  tracks.back = normalizeTrack(source.back)
  tracks.side = normalizeTrack(source.side)
  tracks.side2 = normalizeTrack(source.side2)
  return tracks
}

/**
 * 解析单条 sidecar。**永不抛错**。
 *
 * 这份数据来自磁盘，可能因版本回退、手工改文件、写到一半被杀而损坏。
 * 坏 JSON / 缺 id / 缺 playback / playback.segments 非数组 一律返回 undefined，
 * 只让这一条作品降级，不牵连整个列表（旧记录链是整表解析，坏一个就返回空列表，隔离性差得多）。
 * 其余字段逐字段按类型收敛，缺项/错型退回默认值 —— 页面因此不必到处判空。
 */
export function parseWorkMeta(raw: string): WorkMeta | undefined {
  if (raw.length === 0) {
    return undefined
  }
  let source: WorkMeta
  try {
    source = JSON.parse(raw) as WorkMeta
  } catch (error) {
    return undefined
  }
  if (!source) {
    return undefined
  }
  const id = typeof source.id === 'string' ? source.id : ''
  if (id.length === 0) {
    return undefined
  }
  const sourcePlayback = source.playback
  if (!sourcePlayback) {
    return undefined
  }
  const segments = sourcePlayback.segments
  if (!Array.isArray(segments)) {
    return undefined
  }
  const meta = new WorkMeta()
  meta.schemaVersion =
    typeof source.schemaVersion === 'number' ? source.schemaVersion : WORK_META_SCHEMA_VERSION
  meta.id = id
  meta.createdAt = typeof source.createdAt === 'number' ? source.createdAt : 0
  meta.exportedAt = typeof source.exportedAt === 'number' ? source.exportedAt : 0
  meta.tripTitle = typeof source.tripTitle === 'string' ? source.tripTitle : ''
  meta.tripStartTs = typeof source.tripStartTs === 'number' ? source.tripStartTs : 0
  meta.tripEndTs = typeof source.tripEndTs === 'number' ? source.tripEndTs : 0
  meta.tracks = normalizeTracks(source.tracks)
  meta.templateId = typeof source.templateId === 'string' ? source.templateId : ''
  meta.playback = {
    playheadMs: typeof sourcePlayback.playheadMs === 'number' ? sourcePlayback.playheadMs : 0,
    segments: segments
  }
  meta.watermarkEnabled =
    typeof source.watermarkEnabled === 'boolean' ? source.watermarkEnabled : false
  meta.segmentCount = typeof source.segmentCount === 'number' ? source.segmentCount : 0
  meta.durationMs = typeof source.durationMs === 'number' ? source.durationMs : 0
  return meta
}

export function serializeWorkMeta(meta: WorkMeta): string {
  return JSON.stringify(meta)
}

/**
 * 按「标题 + 起点」**软匹配**一件作品，取 `exportedAt` 最新的那条。
 *
 * 只用于导出前「问不问覆盖」：不能只信 id（覆盖时 id 会沿用被覆盖那条），
 * 也不该按 tripId（会因源素材增删整体重编号）。标题为空一律判不匹配 ——
 * 那说明作品本身就残缺，宁可当作「没有同源作品」也不要猜。
 */
export function findWorkByTrip(
  metas: Array<WorkMeta>,
  tripTitle: string,
  tripStartTs: number
): WorkMeta | undefined {
  if (tripTitle.length === 0) {
    return undefined
  }
  let best: WorkMeta | undefined = undefined
  for (let i = 0; i < metas.length; i++) {
    const meta = metas[i]
    if (meta.tripTitle !== tripTitle || meta.tripStartTs !== tripStartTs) {
      continue
    }
    if (!best || meta.exportedAt > best.exportedAt) {
      best = meta
    }
  }
  return best
}

/** 列表排序键：有 sidecar 用 `exportedAt`，没有则退回文件名里的时刻。 */
export function workSortKey(meta: WorkMeta | undefined, fileName: string): number {
  if (meta) {
    return meta.exportedAt
  }
  return exportTimeFromFileName(fileName)
}

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`
}

/**
 * 以下展示格式化函数**从旧的记录模型原样搬来**，行为不许变 —— 卡片渲染依赖这些格式。
 */

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

/**
 * 模板画出几个画面格子 = 用了几个机位。
 *
 * 与 Models.ets 的 `slotBindings` 一一对应（T1 上下双录 2、T2 倒品字 3、
 * T3 左右分屏 2、T4 三分屏 3、T5 单视角 1、T6 四宫格 4）。这里写成纯查表
 * 而不是 import `TEMPLATE_DEFINITION_MAP`，是因为本文件要能被
 * tools/offline-test.mjs 直接跑，不能拖进 Models 的运行时依赖。
 */
export function templateSlotCount(templateId: string): number {
  if (templateId === 'T1') {
    return 2
  }
  if (templateId === 'T2') {
    return 3
  }
  if (templateId === 'T3') {
    return 2
  }
  if (templateId === 'T4') {
    return 3
  }
  if (templateId === 'T5') {
    return 1
  }
  if (templateId === 'T6') {
    return 4
  }
  return 0
}

/** 「4 机位」。模板未知时给空串，调用方据此整行不画。 */
export function formatRecordSlotCount(templateId: string): string {
  const count = templateSlotCount(templateId)
  if (count <= 0) {
    return ''
  }
  return `${count} 机位`
}

/**
 * 模板画布的宽高比（宽/高），= 成片的真实画面比例。
 *
 * 与 Models.ets 各模板的 `canvasWidth / canvasHeight` 一致。取首帧时要拿它算
 * 目标高度，否则 `fetchFrameByTime` 会把 32:9 的 T3/T4 硬压成 16:9，卡片上看着
 * 就是横向拉扁了。未知模板返回 0，调用方退回 16:9。
 */
export function templateAspectRatio(templateId: string): number {
  if (templateId === 'T1') {
    return 1920 / 2160
  }
  if (templateId === 'T2') {
    return 1920 / 1620
  }
  if (templateId === 'T3') {
    return 3840 / 1080
  }
  if (templateId === 'T4') {
    return 3840 / 1080
  }
  if (templateId === 'T5') {
    return 1920 / 1080
  }
  if (templateId === 'T6') {
    return 3840 / 2160
  }
  return 0
}
