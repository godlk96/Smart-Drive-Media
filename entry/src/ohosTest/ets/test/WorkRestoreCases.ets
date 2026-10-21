/**
 * `WorkRestore` 的用例：轨道记录、片段级缺失判定、快照合成。
 *
 * 不含 hypium 依赖，同一份用例既跑设备也跑 tools/offline-test.mjs。
 * run() 返回 '' 表示通过。
 *
 * 为什么这些用例值得钉死：还原的身份锚是「导出那一刻真正送进 native 的四条轨道」
 * （有序、含重复），而不是行程标题 + 起点。旧的 `snapshotMatchesTrip` 只比标题与起点，
 * 用户删掉中间某个源片段时它照样通过 —— 用户拿到一条看着对、其实从删除点起整体错位的
 * 成片。下面「差集：缺中间片段被检出」就是那条静默错的回归测试（设计稿 3.2）。
 */

import { WorkMeta, WorkTracks } from '../../../main/ets/model/WorkMeta'
import { DvrMeta, ExportComposeRequest, TripSnapshot } from '../../../main/ets/model/TripModels'
import { TemplateId } from '../../../main/ets/model/Models'
import { collectWorkTracks, collectTrackClipNames, findMissingClipNames,
  collectLiveFileNames, buildRestoredTripSnapshot,
  exportSnapshotFromWorkMeta } from '../../../main/ets/model/WorkRestore'
import { TimelineCase, expectString, expectNumber, expectTrue,
  firstError } from './TestSupport'

function makeCase(name: string, run: () => string): TimelineCase {
  const item = new TimelineCase()
  item.name = name
  item.run = run
  return item
}

/** 源片段的 URI 由文件名派生，用例里用 `uriOf` 反查即可，不必手写一长串路径。 */
function uriOf(fileName: string): string {
  return `file://clip/${fileName}`
}

function makeClip(fileName: string, camera: string, timestamp: number, uri: string): DvrMeta {
  const clip = new DvrMeta()
  clip.fileName = fileName
  clip.camera = camera
  clip.timestamp = timestamp
  clip.uri = uri
  return clip
}

/** `[fileName, camera, timestamp]` → 一条现场片段（uri 由文件名派生）。 */
function makeClips(entries: Array<[string, string, number]>): Array<DvrMeta> {
  const clips: Array<DvrMeta> = []
  for (let i = 0; i < entries.length; i++) {
    const entry = entries[i]
    clips.push(makeClip(entry[0], entry[1], entry[2], uriOf(entry[0])))
  }
  return clips
}

function makeTracks(front: Array<string>, back: Array<string>, side: Array<string>,
  side2: Array<string>): WorkTracks {
  const tracks = new WorkTracks()
  tracks.front = front
  tracks.back = back
  tracks.side = side
  tracks.side2 = side2
  return tracks
}

/** 一条最小可用的作品：只填「还原判定」真正读到的字段，轨道默认引用 a.mp4。 */
function makeWorkMeta(id: string, durationMs: number): WorkMeta {
  const meta = new WorkMeta()
  meta.id = id
  meta.durationMs = durationMs
  meta.tracks = makeTracks(['a.mp4'], [], [], [])
  return meta
}

/** 逐位比较字符串数组：顺序与重复都不许丢。 */
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

export function workRestoreCases(): Array<TimelineCase> {
  const cases: Array<TimelineCase> = []

  cases.push(makeCase('collectWorkTracks 按顺序反查文件名', () => {
    const clips = makeClips([['a.mp4', 'Front', 1], ['b.mp4', 'Front', 2]])
    const request = new ExportComposeRequest()
    request.frontUris = [uriOf('a.mp4'), uriOf('b.mp4')]
    const tracks = collectWorkTracks(clips, request)
    return expectStringArray(tracks.front, ['a.mp4', 'b.mp4'], 'front 轨道')
  }))

  cases.push(makeCase('collectWorkTracks 保留重复', () => {
    const clips = makeClips([['a.mp4', 'Front', 1], ['b.mp4', 'Front', 2]])
    const request = new ExportComposeRequest()
    request.frontUris = [uriOf('a.mp4'), uriOf('b.mp4'), uriOf('a.mp4')]
    const tracks = collectWorkTracks(clips, request)
    return firstError([
      expectNumber(tracks.front.length, 3, '长度'),
      expectString(tracks.front[2], tracks.front[0], '第 3 项等于第 1 项')
    ])
  }))

  cases.push(makeCase('collectWorkTracks 查不到的 URI 放空串', () => {
    const clips = makeClips([['a.mp4', 'Front', 1]])
    const request = new ExportComposeRequest()
    request.frontUris = [uriOf('missing.mp4')]
    const tracks = collectWorkTracks(clips, request)
    return expectString(tracks.front[0], '', '未命中放空串')
  }))

  cases.push(makeCase('四轨合并去重', () => {
    const tracks = makeTracks(['a.mp4', 'a.mp4'], [], ['a.mp4', 'b.mp4'], [])
    return expectNumber(collectTrackClipNames(tracks).length, 2, '去重后数量')
  }))

  cases.push(makeCase('差集：全部命中为空', () => {
    const tracks = makeTracks(['a.mp4'], [], ['b.mp4'], [])
    return expectNumber(findMissingClipNames(tracks, ['a.mp4', 'b.mp4']).length, 0, '无缺失')
  }))

  cases.push(makeCase('差集：缺中间片段被检出', () => {
    const tracks = makeTracks(['a.mp4', 'b.mp4', 'c.mp4'], [], [], [])
    const missing = findMissingClipNames(tracks, ['a.mp4', 'c.mp4'])
    return expectStringArray(missing, ['b.mp4'], '缺失')
  }))

  cases.push(makeCase('差集：缺最早片段也被检出', () => {
    const tracks = makeTracks(['a.mp4', 'b.mp4'], [], [], [])
    const missing = findMissingClipNames(tracks, ['b.mp4'])
    return expectTrue(missing.indexOf('a.mp4') >= 0, '含 a.mp4')
  }))

  cases.push(makeCase('差集：空串算缺失', () => {
    const tracks = makeTracks([''], [], [], [])
    return expectStringArray(findMissingClipNames(tracks, ['a.mp4']), [''], '空串算缺失')
  }))

  cases.push(makeCase('差集保持首次出现顺序', () => {
    const tracks = makeTracks(['c.mp4', 'a.mp4'], [], [], [])
    return expectStringArray(findMissingClipNames(tracks, []), ['c.mp4', 'a.mp4'], '顺序')
  }))

  cases.push(makeCase('空 URI 的现场片段：算缺失且不进 clips 并集', () => {
    const meta = makeWorkMeta('w-empty-uri', 1000)
    const clips: Array<DvrMeta> = [makeClip('a.mp4', 'Front', 1, '')]
    const missing = findMissingClipNames(meta.tracks, collectLiveFileNames(clips))
    const snapshot = buildRestoredTripSnapshot(meta, clips)
    return firstError([
      expectTrue(missing.indexOf('a.mp4') >= 0, '空 URI 算缺失'),
      expectNumber(snapshot.clips.length, 0, '空 URI 不进并集')
    ])
  }))

  cases.push(makeCase('合成快照的 durationSec 取自 meta', () => {
    const meta = makeWorkMeta('w-dur', 32000)
    const snapshot = buildRestoredTripSnapshot(meta, makeClips([['a.mp4', 'Front', 1]]))
    return expectNumber(snapshot.durationSec, 32, '时长取自 meta')
  }))

  cases.push(makeCase('合成快照的 id 稳定可复现', () => {
    const meta = makeWorkMeta('w-id', 1000)
    const clips = makeClips([['a.mp4', 'Front', 1]])
    const first = buildRestoredTripSnapshot(meta, clips)
    const second = buildRestoredTripSnapshot(meta, clips)
    return firstError([
      expectString(first.id, second.id, '两次一致'),
      expectString(first.id, 'trip-restored-w-id', 'id 形态')
    ])
  }))

  cases.push(makeCase('合成快照的 clips 是命中并集且升序', () => {
    const meta = makeWorkMeta('w-clips', 1000)
    meta.tracks = makeTracks(['a.mp4', 'c.mp4'], [], [], [])
    const clips = makeClips([['c.mp4', 'Left', 3], ['b.mp4', 'Front', 9], ['a.mp4', 'Front', 1]])
    const snapshot = buildRestoredTripSnapshot(meta, clips)
    return firstError([
      expectNumber(snapshot.clips.length, 2, '只留命中的两个'),
      expectTrue(snapshot.clips[0].timestamp <= snapshot.clips[1].timestamp, 'timestamp 升序')
    ])
  }))

  cases.push(makeCase('合成快照的 clips 同名多份只留一条', () => {
    const meta = makeWorkMeta('w-dup', 1000)
    const clips: Array<DvrMeta> = [
      makeClip('a.mp4', 'Front', 2, uriOf('a-late.mp4')),
      makeClip('a.mp4', 'Front', 1, uriOf('a-early.mp4'))
    ]
    const snapshot = buildRestoredTripSnapshot(meta, clips)
    return firstError([
      expectNumber(snapshot.clips.length, 1, '同名只留一条'),
      expectString(snapshot.clips[0].uri, uriOf('a-early.mp4'), '取时间戳最早那条')
    ])
  }))

  cases.push(makeCase('合成快照的 timeline 留空', () => {
    const meta = makeWorkMeta('w-tl', 1000)
    const snapshot = buildRestoredTripSnapshot(meta, makeClips([['a.mp4', 'Front', 1]]))
    return expectNumber(snapshot.timeline.length, 0, 'timeline 留空')
  }))

  cases.push(makeCase('exportSnapshotFromWorkMeta 的模板走归一化', () => {
    const meta = makeWorkMeta('w-tpl', 1000)
    meta.templateId = 'T5'
    const snapshot = exportSnapshotFromWorkMeta(meta, new TripSnapshot())
    return expectString(snapshot.selectedTemplateId, TemplateId.T5, 'T5')
  }))

  cases.push(makeCase('exportSnapshotFromWorkMeta 的未知模板回落到默认', () => {
    const meta = makeWorkMeta('w-tpl2', 1000)
    meta.templateId = 'ZZ'
    const snapshot = exportSnapshotFromWorkMeta(meta, new TripSnapshot())
    return expectString(snapshot.selectedTemplateId, TemplateId.T1, '回落 T1')
  }))

  cases.push(makeCase('exportSnapshotFromWorkMeta 透传 playback 与水印', () => {
    const meta = makeWorkMeta('w-pb', 1000)
    meta.playback = { playheadMs: 4500, segments: [] }
    meta.watermarkEnabled = true
    const snapshot = exportSnapshotFromWorkMeta(meta, new TripSnapshot())
    return firstError([
      expectNumber(snapshot.playback.playheadMs, 4500, '播放头'),
      expectTrue(snapshot.brand.watermarkEnabled, '水印')
    ])
  }))

  return cases
}
