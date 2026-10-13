import { describe, it, expect } from '@ohos/hypium'
import { createEditorStateFromSnapshot, deepCloneExportSnapshot, ExportSnapshot } from '../../../main/ets/model/Models'
import { DvrMeta, TripSnapshot } from '../../../main/ets/model/TripModels'

function buildSnapshotWithClips(clipCount: number): TripSnapshot {
  const snapshot = new TripSnapshot()
  snapshot.id = 'trip-export-test'
  snapshot.tripTitle = '导出链路单元测试'
  snapshot.tripRange = '00:00:00 - 00:01:00'
  snapshot.durationSec = clipCount * 60
  snapshot.startTs = 0
  snapshot.endTs = clipCount * 60000
  const clips: Array<DvrMeta> = []
  for (let i = 0; i < clipCount; i++) {
    const clip = new DvrMeta()
    clip.fileName = `clip_${i}.mp4`
    clip.uri = `/data/storage/el2/base/files/front_${i}.mp4`
    clip.camera = 'Front'
    clip.timestamp = i * 60000
    clips.push(clip)
  }
  snapshot.clips = clips
  snapshot.timeline = [{ cameraPosition: 'Front', segmentCount: clipCount, degraded: false }]
  return snapshot
}

export default function exportPayloadTest(): void {
  describe('Export.payload', () => {
    it('导出快照携带行程全部片段（裁剪由 range 参数在 native 侧执行）', 0, () => {
      const state = createEditorStateFromSnapshot(
        buildSnapshotWithClips(2), 'session-2', 'T2', '1.0X', false, true, true, '待导出'
      )
      const snapshot: ExportSnapshot = deepCloneExportSnapshot(state)
      const frontTrack = snapshot.trip.tracks.FRONT
      expect(frontTrack.segments.length).assertEqual(2)
    })

    it('导出快照默认区间为整条行程（0 ~ durationMs）', 0, () => {
      const state = createEditorStateFromSnapshot(
        buildSnapshotWithClips(2), 'session-3', 'T2', '1.0X', false, true, true, '待导出'
      )
      const snapshot = deepCloneExportSnapshot(state)
      expect(snapshot.playback.rangeStartMs).assertEqual(0)
      expect(snapshot.playback.rangeEndMs).assertEqual(120000)
    })

    it('区间可被赋值为非零起点，且深拷贝后保持独立（不共享引用）', 0, () => {
      const state = createEditorStateFromSnapshot(
        buildSnapshotWithClips(2), 'session-4', 'T2', '1.0X', false, true, true, '待导出'
      )
      state.playback.rangeStartMs = 30000
      state.playback.rangeEndMs = 90000
      const snapshot = deepCloneExportSnapshot(state)
      expect(snapshot.playback.rangeStartMs).assertEqual(30000)
      expect(snapshot.playback.rangeEndMs).assertEqual(90000)
      snapshot.playback.rangeStartMs = 1
      expect(state.playback.rangeStartMs).assertEqual(30000)
    })

    it('导出快照携带模板与水印开关', 0, () => {
      const state = createEditorStateFromSnapshot(
        buildSnapshotWithClips(1), 'session-5', 'T5', '1.0X', false, true, true, '待导出'
      )
      const snapshot = deepCloneExportSnapshot(state)
      expect(snapshot.selectedTemplateId).assertEqual('T5')
      expect(snapshot.brand.watermarkEnabled).assertTrue()
    })
  })
}
