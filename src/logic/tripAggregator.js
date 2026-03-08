/**
 * (整理师) 将成百上千个 1 分钟的切片视频，按时间连续性“缝合”成一个完整的行程对象。
 */
import { randomUUID } from 'node:crypto'
import { CameraPosition } from '../model/types.js'

export const DEFAULT_GAP_THRESHOLD_MS = 2 * 60 * 1000

function createTripFromGroups(groups) {
  const tracks = new Map()

  for (const group of groups) {
    for (const segment of group.segments) {
      if (!tracks.has(segment.cameraPosition)) {
        tracks.set(segment.cameraPosition, {
          cameraPosition: segment.cameraPosition,
          segments: [],
          syncOffset: 0
        })
      }
      tracks.get(segment.cameraPosition).segments.push({
        filePath: segment.filePath,
        fileName: segment.fileName,
        startTime: segment.startTime,
        duration: segment.duration
      })
    }
  }

  const firstGroup = groups[0]
  const lastGroup = groups[groups.length - 1]
  const maxDuration = lastGroup.segments.reduce(
    (acc, item) => Math.max(acc, item.duration),
    60
  )
  const startTime = new Date(firstGroup.timestamp)
  const endTime = new Date(lastGroup.timestamp + maxDuration * 1000)
  const frontTrack = tracks.get(CameraPosition.FRONT)
  const thumbnailUrl = frontTrack?.segments[0]?.filePath ?? groups[0].segments[0].filePath

  return {
    id: randomUUID(),
    startTime,
    endTime,
    duration: Math.max(0, Math.round((endTime - startTime) / 1000)),
    videoTracks: [...tracks.values()].map(track => ({
      ...track,
      segments: [...track.segments].sort((a, b) => a.startTime - b.startTime)
    })),
    thumbnailUrl
  }
}

function buildSliceGroups(segments) {
  const groupMap = new Map()

  for (const segment of segments) {
    const key = segment.startTime.getTime()
    if (!groupMap.has(key)) {
      groupMap.set(key, {
        timestamp: key,
        segments: []
      })
    }
    groupMap.get(key).segments.push(segment)
  }

  return [...groupMap.values()].sort((a, b) => a.timestamp - b.timestamp)
}

export function aggregateTrips(segments, thresholdMs = DEFAULT_GAP_THRESHOLD_MS) {
  const validSegments = [...segments].filter(Boolean).sort((a, b) => a.startTime - b.startTime)
  if (validSegments.length === 0) {
    return []
  }

  const groups = buildSliceGroups(validSegments)
  const trips = []
  let currentGroups = []

  for (const group of groups) {
    const previous = currentGroups[currentGroups.length - 1]
    if (!previous) {
      currentGroups.push(group)
      continue
    }

    const gap = group.timestamp - previous.timestamp
    if (gap > thresholdMs) {
      trips.push(createTripFromGroups(currentGroups))
      currentGroups = [group]
      continue
    }
    currentGroups.push(group)
  }

  if (currentGroups.length > 0) {
    trips.push(createTripFromGroups(currentGroups))
  }

  return trips
}
