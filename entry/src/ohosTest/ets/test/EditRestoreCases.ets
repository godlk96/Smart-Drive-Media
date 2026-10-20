/**
 * 「按记录快照还原编辑器状态」的纯函数用例。
 *
 * 不含 hypium 依赖，同一份用例既跑设备也跑 tools/offline-test.mjs。
 * run() 返回 '' 表示通过。
 */

import { TripSnapshot, ExportSegment, DvrMeta } from '../../../main/ets/model/TripModels'
import { ExportSnapshot, EditorState, TemplateId, CameraPosition, deepCloneExportSnapshot,
  createEditorStateFromSnapshot, parseExportSnapshot,
  restoreEditorStateFromSnapshot, tripFromSnapshot } from '../../../main/ets/model/Models'
import { Segment, createFullSegment, toEditorSegments,
  isRawFullSegments } from '../../../main/ets/model/SegmentModel'
import { TimelineCase, expectString, expectNumber, expectTrue, expectFalse, firstError } from './TestSupport'

function makeCase(name: string, run: () => string): TimelineCase {
  const item = new TimelineCase()
  item.name = name
  item.run = run
  return item
}

/** 现场行程：与记录里的标题/起点一致，但素材 URI 是「现在这台机器上的」。 */
function makeLive(): TripSnapshot {
  const live = new TripSnapshot()
  live.id = 'trip-2026-10-01-1759296000000-3'
  live.tripTitle = '10月1日 周三'
  live.tripRange = '13:28 - 13:40'
  live.durationSec = 720
  live.startTs = 1759296000000
  live.endTs = 1759296720000
  live.previewUri = 'file:///data/front.mp4'
  live.previewFrameUri = '/data/thumb.jpg'
  live.previewCamera = 'Front'
  live.clips = []
  live.timeline = []
  return live
}

/** 用户真剪过的段：[30s,120s) + 1.5 倍速。 */
function makeEditedSegment(): Segment {
  const segment = createFullSegment(720)[0]
  segment.startSec = 30
  segment.endSec = 120
  segment.speedLabel = '1.5X'
  return segment
}

/** 存进历史的那份快照：模板 T3、关水印、一个改过边界的段。 */
function makeStored(): ExportSnapshot {
  const live = makeLive()
  const segment = makeEditedSegment()
  return deepCloneExportSnapshot(
    createEditorStateFromSnapshot(live, 's1', 'T3', [segment], false, true, '待导出'))
}

export function editRestoreCases(): Array<TimelineCase> {
  const cases: Array<TimelineCase> = []

  cases.push(makeCase('坏 JSON 快照返回 undefined', () => {
    return expectTrue(parseExportSnapshot('{oops') === undefined, '坏 JSON')
  }))

  cases.push(makeCase('空串返回 undefined', () => {
    return expectTrue(parseExportSnapshot('') === undefined, '空串')
  }))

  cases.push(makeCase('缺 trip 返回 undefined', () => {
    return expectTrue(parseExportSnapshot('{"playback":{"segments":[]}}') === undefined, '缺 trip')
  }))

  cases.push(makeCase('segments 非数组返回 undefined', () => {
    return expectTrue(parseExportSnapshot('{"trip":{},"playback":{"segments":1}}') === undefined,
      'segments 非数组')
  }))

  cases.push(makeCase('合法快照往返可用', () => {
    const stored = makeStored()
    return expectTrue(parseExportSnapshot(JSON.stringify(stored)) !== undefined, '往返')
  }))

  cases.push(makeCase('还原用现场素材不用记录素材', () => {
    const stored = makeStored()
    const live = makeLive()
    const restored: EditorState = restoreEditorStateFromSnapshot(stored, live, 's2', '待导出')
    return expectString(restored.trip.tripId, live.id, '素材以现场为准')
  }))

  cases.push(makeCase('还原用记录模板', () => {
    const stored = makeStored()
    const live = makeLive()
    const restored = restoreEditorStateFromSnapshot(stored, live, 's2', '待导出')
    return expectString(restored.selectedTemplateId, TemplateId.T3, '模板取记录')
  }))

  cases.push(makeCase('还原用记录水印', () => {
    const stored = makeStored()
    const live = makeLive()
    const restored = restoreEditorStateFromSnapshot(stored, live, 's2', '待导出')
    return expectFalse(restored.brand.watermarkEnabled, '水印取记录')
  }))

  cases.push(makeCase('还原用记录分段参数', () => {
    const stored = makeStored()
    const live = makeLive()
    const restored = restoreEditorStateFromSnapshot(stored, live, 's2', '待导出')
    return firstError([
      expectString(restored.playback.segments[0].speedLabel, '1.5X', '倍速取记录'),
      expectNumber(restored.playback.segments[0].startMs, 30000, '起点取记录')
    ])
  }))

  cases.push(makeCase('还原的 exportStatus 可控', () => {
    const stored = makeStored()
    const live = makeLive()
    const restored = restoreEditorStateFromSnapshot(stored, live, 's2', '已还原历史剪辑')
    return expectString(restored.ui.exportStatus, '已还原历史剪辑', '状态文案')
  }))

  cases.push(makeCase('还原不共享记录数组引用', () => {
    const stored = makeStored()
    const live = makeLive()
    const restored = restoreEditorStateFromSnapshot(stored, live, 's2', '待导出')
    restored.playback.segments[0].startMs = 999
    return expectNumber(stored.playback.segments[0].startMs, 30000, '原快照未被改')
  }))

  cases.push(makeCase('ExportSegment→Segment 序号重编', () => {
    const first = new ExportSegment()
    first.startMs = 30000
    first.endMs = 120000
    first.speedLabel = '1.5X'
    first.muted = true
    const second = new ExportSegment()
    second.startMs = 200000
    second.endMs = 260000
    second.speedLabel = '1.0X'
    second.muted = false
    const back = toEditorSegments([first, second])
    return firstError([
      expectNumber(back.length, 2, '段数'),
      expectNumber(back[0].id, 0, '首段 id'),
      expectNumber(back[1].id, 1, '次段 id'),
      expectTrue(back[0].muted, '声音开关照抄'),
      expectTrue(back[0].enabled, '默认启用')
    ])
  }))

  cases.push(makeCase('ExportSegment→Segment 毫秒转秒', () => {
    const only = new ExportSegment()
    only.startMs = 1500
    only.endMs = 4500
    return expectNumber(toEditorSegments([only])[0].startSec, 1.5, '毫秒转秒')
  }))

  cases.push(makeCase('单段覆盖全片算原始态', () => {
    return expectTrue(isRawFullSegments(createFullSegment(720), 720), '原始态')
  }))

  cases.push(makeCase('剪过的段不算原始态', () => {
    return expectFalse(isRawFullSegments([makeEditedSegment()], 720), '剪过')
  }))

  cases.push(makeCase('两段不算原始态', () => {
    const first = new Segment()
    first.id = 0
    first.startSec = 0
    first.endSec = 300
    const second = new Segment()
    second.id = 1
    second.startSec = 300
    second.endSec = 720
    return expectFalse(isRawFullSegments([first, second], 720), '两段拼满')
  }))

  cases.push(makeCase('tripFromSnapshot 保留源片段文件名', () => {
    const live = makeLive()
    const clip = new DvrMeta()
    clip.fileName = 'DVR_LoopRecording_2026-10-01_13-28-18_front_camera.mp4'
    clip.uri = 'file://media/Photo/1/IMG_1/DVR_LoopRecording_2026-10-01_13-28-18_front_camera.mp4'
    clip.camera = 'Front'
    clip.timestamp = 1759296000000
    live.clips = [clip]
    const trip = tripFromSnapshot(live)
    return expectString(trip.tracks[CameraPosition.FRONT].segments[0].fileName,
      clip.fileName, '文件名')
  }))

  cases.push(makeCase('tripFromSnapshot 的空文件名保持空串', () => {
    const live = makeLive()
    const clip = new DvrMeta()
    clip.uri = 'file://media/Photo/1/IMG_1/x.mp4'
    clip.camera = 'Front'
    clip.timestamp = 1759296000000
    live.clips = [clip]
    const trip = tripFromSnapshot(live)
    return expectString(trip.tracks[CameraPosition.FRONT].segments[0].fileName, '', '空文件名')
  }))

  return cases
}
