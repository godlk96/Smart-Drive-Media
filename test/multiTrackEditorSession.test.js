import test from 'node:test'
import assert from 'node:assert/strict'
import { MultiTrackEditorSession, SYNC_DRIFT_THRESHOLD_MS } from '../src/logic/multiTrackEditorSession.js'
import { CameraPosition } from '../src/model/types.js'

test('MultiTrackEditorSession loads six-track timeline', () => {
  const session = new MultiTrackEditorSession()
  const timeline = session.loadTrip({
    videoTracks: [
      {
        cameraPosition: CameraPosition.FRONT,
        segments: [{ filePath: 'front.mp4', startTime: new Date(), duration: 60 }]
      },
      {
        cameraPosition: CameraPosition.BACK,
        segments: [{ filePath: 'back.mp4', startTime: new Date(), duration: 60 }]
      }
    ]
  })

  assert.equal(timeline.length, 6)
  const frontTrack = timeline.find(item => item.cameraPosition === CameraPosition.FRONT)
  assert.equal(frontTrack.segments.length, 1)
  const rightTrack = timeline.find(item => item.cameraPosition === CameraPosition.RIGHT)
  assert.equal(rightTrack.degraded, true)
})

test('MultiTrackEditorSession applies correction only when drift exceeds threshold', () => {
  const session = new MultiTrackEditorSession()
  const corrections = session.applySync(10_000, {
    [CameraPosition.BACK]: 9_000,
    [CameraPosition.LEFT]: 9_950
  })

  assert.equal(corrections.length, 1)
  assert.equal(corrections[0].cameraPosition, CameraPosition.BACK)
  assert.equal(corrections[0].driftMs > SYNC_DRIFT_THRESHOLD_MS, true)
})
