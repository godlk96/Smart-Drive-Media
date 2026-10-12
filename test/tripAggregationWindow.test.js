import test from 'node:test'
import assert from 'node:assert/strict'

const CLIP_DURATION_SEC = 60
const TRIP_GAP_THRESHOLD_MS = 120 * 1000 // 120s

function clusterMetasIntoTrips(metas) {
  if (!metas || metas.length === 0) {
    return []
  }
  const sorted = [...metas].sort((a, b) => a.timestamp - b.timestamp)
  const slicesMap = new Map()
  sorted.forEach((item) => {
    const list = slicesMap.get(item.timestamp) ?? []
    list.push(item)
    slicesMap.set(item.timestamp, list)
  })
  const sortedTimestamps = Array.from(slicesMap.keys()).sort((a, b) => a - b)

  const tripSliceGroups = []
  let currentGroup = []
  let lastSliceEndTs = -1

  sortedTimestamps.forEach((ts) => {
    const slice = slicesMap.get(ts) ?? []
    const sliceEndTs = ts + CLIP_DURATION_SEC * 1000
    if (currentGroup.length === 0) {
      currentGroup.push(slice)
      lastSliceEndTs = sliceEndTs
    } else {
      if (ts - lastSliceEndTs <= TRIP_GAP_THRESHOLD_MS) {
        currentGroup.push(slice)
        lastSliceEndTs = sliceEndTs
      } else {
        tripSliceGroups.push(currentGroup)
        currentGroup = [slice]
        lastSliceEndTs = sliceEndTs
      }
    }
  })
  if (currentGroup.length > 0) {
    tripSliceGroups.push(currentGroup)
  }

  return tripSliceGroups.map((group, index) => {
    const allClips = []
    group.forEach((slice) => allClips.push(...slice))
    const startTs = group[0][0].timestamp
    const endTs = group[group.length - 1][0].timestamp + CLIP_DURATION_SEC * 1000
    const durationSec = Math.max(CLIP_DURATION_SEC, Math.round((endTs - startTs) / 1000))
    return {
      index,
      startTs,
      endTs,
      durationSec,
      clipCount: allClips.length,
      sliceCount: group.length
    }
  })
}

test('Continuous 60s clips without gap cluster into a single trip', () => {
  const baseTs = 1700000000000
  const metas = [
    { camera: 'Front', timestamp: baseTs, uri: 'f1.mp4' },
    { camera: 'Back', timestamp: baseTs, uri: 'b1.mp4' },
    { camera: 'Front', timestamp: baseTs + 60000, uri: 'f2.mp4' },
    { camera: 'Back', timestamp: baseTs + 60000, uri: 'b2.mp4' },
    { camera: 'Front', timestamp: baseTs + 120000, uri: 'f3.mp4' },
    { camera: 'Back', timestamp: baseTs + 120000, uri: 'b3.mp4' }
  ]

  const trips = clusterMetasIntoTrips(metas)
  assert.equal(trips.length, 1)
  assert.equal(trips[0].durationSec, 180)
  assert.equal(trips[0].clipCount, 6)
  assert.equal(trips[0].sliceCount, 3)
})

test('Clips with minor gap within 120s cluster into single trip', () => {
  const baseTs = 1700000000000
  // First clip: 0 - 60s. Second clip starts at 90s (gap is 30s <= 120s)
  const metas = [
    { camera: 'Front', timestamp: baseTs, uri: 'f1.mp4' },
    { camera: 'Front', timestamp: baseTs + 90000, uri: 'f2.mp4' }
  ]

  const trips = clusterMetasIntoTrips(metas)
  assert.equal(trips.length, 1)
  assert.equal(trips[0].durationSec, 150) // 0s to 150s (90s + 60s)
  assert.equal(trips[0].clipCount, 2)
})

test('Clips with large gap (> 120s) separate into different trips', () => {
  const baseTs = 1700000000000
  // First clip: 0 - 60s. Second clip starts 10 minutes later (gap = 540s > 120s)
  const metas = [
    { camera: 'Front', timestamp: baseTs, uri: 'f1.mp4' },
    { camera: 'Front', timestamp: baseTs + 600000, uri: 'f2.mp4' }
  ]

  const trips = clusterMetasIntoTrips(metas)
  assert.equal(trips.length, 2)
  assert.equal(trips[0].durationSec, 60)
  assert.equal(trips[1].durationSec, 60)
})
