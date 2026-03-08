import test from 'node:test'
import assert from 'node:assert/strict'
import { buildTrackFallbackPlan } from '../src/logic/trackFallbackPlanner.js'
import { CameraPosition } from '../src/model/types.js'

test('buildTrackFallbackPlan returns degraded placeholders for missing tracks', () => {
  const plan = buildTrackFallbackPlan([
    {
      cameraPosition: CameraPosition.FRONT,
      segments: [{ filePath: 'front.mp4', startTime: new Date(), duration: 60 }]
    }
  ])

  assert.equal(plan.timelineTracks.length, 6)
  assert.equal(plan.degradedTracks.includes(CameraPosition.BACK), true)
  const back = plan.timelineTracks.find(item => item.cameraPosition === CameraPosition.BACK)
  assert.equal(back.mode, 'placeholder')
})
