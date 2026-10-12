import { describe, it, expect } from '@ohos/hypium'
import { createEditorStateFromSnapshot, deepCloneExportSnapshot, EditorState } from '../../../main/ets/model/Models'
import { DvrMeta, TripSnapshot } from '../../../main/ets/model/TripModels'

function buildTripSnapshot(): TripSnapshot {
  const snapshot = new TripSnapshot()
  snapshot.id = 'trip-unit-test'
  snapshot.tripTitle = '单元测试行程'
  snapshot.tripRange = '00:00:00 - 00:02:00'
  snapshot.durationSec = 120
  snapshot.startTs = 1000
  snapshot.endTs = 121000
  const clip = new DvrMeta()
  clip.fileName = 'DVR_LoopRecording_camera.mp4'
  clip.uri = '/data/storage/el2/base/files/front_0.mp4'
  clip.camera = 'Front'
  clip.timestamp = 1000
  snapshot.clips = [clip]
  snapshot.timeline = [{ cameraPosition: 'Front', segmentCount: 1, degraded: false }]
  return snapshot
}

function buildState(hideSpeed: boolean, hideGps: boolean, hideVin: boolean): EditorState {
  return createEditorStateFromSnapshot(
    buildTripSnapshot(),
    'session-1',
    'T2',
    '1.0X',
    false,
    true,
    hideSpeed,
    hideGps,
    hideVin,
    true,
    '待导出'
  )
}

export default function privacyMaskTest(): void {
  describe('Privacy.maskDecoupling', () => {
    it('隐私状态同时具备 hideGps 与独立的 hideTime 字段', 0, () => {
      const state = buildState(true, true, true)
      expect(state.privacy.hideGps).assertTrue()
      expect(state.privacy.hideTime).assertTrue()
      expect(state.privacy.hideSpeed).assertTrue()
      expect(state.privacy.hideVin).assertTrue()
    })

    it('关闭 GPS 打码时 hideGps 变为 false，且 hideTime 可独立表达', 0, () => {
      const state = buildState(true, false, true)
      expect(state.privacy.hideGps).assertFalse()
      // hideTime 不再被强制绑定为 hideGps（此前 maskTime/maskGps 同源是缺陷）
      const cloned = deepCloneExportSnapshot(state)
      expect(cloned.privacy.hideGps).assertFalse()
      expect(cloned.privacy.hideTime !== undefined).assertTrue()
    })

    it('导出快照深拷贝保留 hideTime 字段', 0, () => {
      const state = buildState(true, true, false)
      const snapshot = deepCloneExportSnapshot(state)
      expect(snapshot.privacy.hideTime !== undefined).assertTrue()
      expect(snapshot.privacy.hideVin).assertFalse()
      expect(snapshot.sessionId).assertEqual('session-1')
    })
  })
}
