import test from 'node:test'
import assert from 'node:assert/strict'
import { parseDvrFile, isDvrCandidate } from '../src/logic/fileParser.js'
import { CameraPosition } from '../src/model/types.js'

test('isDvrCandidate can identify valid naming rule', () => {
  assert.equal(
    isDvrCandidate('C:/videos/DVR_LoopRecording_2026-03-01_08-30-20_Front.mp4'),
    true
  )
  assert.equal(
    isDvrCandidate('C:/videos/VID_1772807031_360_DVR_LoopRecording_2026-03-01_08-30-20_left_rear_camera.mp4'),
    true
  )
  assert.equal(isDvrCandidate('C:/videos/holiday.mp4'), false)
})

test('parseDvrFile parses date time and camera position', () => {
  const parsed = parseDvrFile(
    'C:/videos/DVR_LoopRecording_2026-03-01_08-30-20_RightFront.ts',
    70
  )

  assert.ok(parsed)
  assert.equal(parsed.cameraPosition, CameraPosition.RIGHT_FRONT)
  assert.equal(parsed.duration, 70)
  assert.equal(parsed.startTime.getFullYear(), 2026)
  assert.equal(parsed.startTime.getMonth(), 2)
  assert.equal(parsed.startTime.getDate(), 1)
  assert.equal(parsed.startTime.getHours(), 8)
  assert.equal(parsed.startTime.getMinutes(), 30)
  assert.equal(parsed.startTime.getSeconds(), 20)
})

test('parseDvrFile supports prefixed names and rear aliases normalization', () => {
  const leftRear = parseDvrFile(
    'C:/videos/VID_1772807031_360_DVR_LoopRecording_2026-03-01_08-30-20_left_rear_camera.mp4',
    60
  )
  const rightRear = parseDvrFile(
    'C:/videos/ABC_DVR_LoopRecording_2026-03-01_08-31-20_right_rear.mov',
    60
  )

  assert.ok(leftRear)
  assert.ok(rightRear)
  assert.equal(leftRear.cameraPosition, CameraPosition.LEFT)
  assert.equal(rightRear.cameraPosition, CameraPosition.RIGHT)
})
