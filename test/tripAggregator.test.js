import test from 'node:test'
import assert from 'node:assert/strict'
import { aggregateTrips } from '../src/logic/tripAggregator.js'
import { CameraPosition } from '../src/model/types.js'

function createSegment(fileName, cameraPosition, date, duration = 60) {
  return {
    filePath: `C:/videos/${fileName}`,
    fileName,
    cameraPosition,
    startTime: new Date(date),
    duration
  }
}

test('aggregateTrips groups same-second files into one trip', () => {
  const segments = [
    createSegment(
      'DVR_LoopRecording_2026-03-01_08-30-20_Front.mp4',
      CameraPosition.FRONT,
      '2026-03-01T08:30:20'
    ),
    createSegment(
      'DVR_LoopRecording_2026-03-01_08-30-20_Back.mp4',
      CameraPosition.BACK,
      '2026-03-01T08:30:20'
    ),
    createSegment(
      'DVR_LoopRecording_2026-03-01_08-31-20_Front.mp4',
      CameraPosition.FRONT,
      '2026-03-01T08:31:20'
    )
  ]

  const trips = aggregateTrips(segments)
  assert.equal(trips.length, 1)
  assert.equal(trips[0].videoTracks.length, 2)
  assert.equal(trips[0].duration, 120)
})

test('aggregateTrips splits trip when gap larger than 2 minutes', () => {
  const segments = [
    createSegment(
      'DVR_LoopRecording_2026-03-01_08-30-20_Front.mp4',
      CameraPosition.FRONT,
      '2026-03-01T08:30:20'
    ),
    createSegment(
      'DVR_LoopRecording_2026-03-01_08-33-21_Front.mp4',
      CameraPosition.FRONT,
      '2026-03-01T08:33:21'
    )
  ]

  const trips = aggregateTrips(segments)
  assert.equal(trips.length, 2)
})
