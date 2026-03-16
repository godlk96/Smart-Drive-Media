import { TimelineTrackModel } from '../model/AppState'
import { DvrMeta } from '../model/TripModels'
import smartdriveExporter from 'libsmartdrive_exporter.so'
import { tryEnsureCoreApiContract } from './CoreApiContract'

const CAMERA_ORDER: Array<string> = ['Front', 'Back', 'Left', 'Right', 'LeftFront', 'RightFront']

function buildTimelineByJs(metas: Array<DvrMeta>): Array<TimelineTrackModel> {
  const counts: Map<string, number> = new Map()
  metas.forEach((item: DvrMeta) => {
    if (item.camera.length === 0) {
      return
    }
    const current = counts.get(item.camera) ?? 0
    counts.set(item.camera, current + 1)
  })
  const tracks: Array<TimelineTrackModel> = []
  CAMERA_ORDER.forEach((camera: string) => {
    const count = counts.get(camera) ?? 0
    if (count <= 0) {
      return
    }
    tracks.push({
      cameraPosition: camera,
      segmentCount: count,
      degraded: count < 2
    })
  })
  return tracks
}

function mergeTimelineByJs(tracks: Array<Array<TimelineTrackModel>>): Array<TimelineTrackModel> {
  const counts: Map<string, number> = new Map()
  tracks.forEach((timeline: Array<TimelineTrackModel>) => {
    timeline.forEach((item: TimelineTrackModel) => {
      if (item.cameraPosition.length === 0 || item.segmentCount <= 0) {
        return
      }
      const current = counts.get(item.cameraPosition) ?? 0
      counts.set(item.cameraPosition, current + item.segmentCount)
    })
  })
  const merged: Array<TimelineTrackModel> = []
  CAMERA_ORDER.forEach((camera: string) => {
    const count = counts.get(camera) ?? 0
    if (count <= 0) {
      return
    }
    merged.push({
      cameraPosition: camera,
      segmentCount: count,
      degraded: false
    })
  })
  return merged
}

export function buildTimeline(metas: Array<DvrMeta>): Array<TimelineTrackModel> {
  if (!tryEnsureCoreApiContract()) {
    return buildTimelineByJs(metas)
  }
  const nativeBuild = smartdriveExporter.buildTimeline as ((camerasCsv: string) => Array<TimelineTrackModel>) | undefined
  if (typeof nativeBuild !== 'function') {
    return buildTimelineByJs(metas)
  }
  const camerasCsv = metas.map((item: DvrMeta) => item.camera).join(',')
  return nativeBuild(camerasCsv) ?? []
}

export function mergeTimeline(tracks: Array<Array<TimelineTrackModel>>): Array<TimelineTrackModel> {
  if (!tryEnsureCoreApiContract()) {
    return mergeTimelineByJs(tracks)
  }
  const nativeMerge = smartdriveExporter.mergeTimeline as ((timelineCsv: string) => Array<TimelineTrackModel>) | undefined
  if (typeof nativeMerge !== 'function') {
    return mergeTimelineByJs(tracks)
  }
  const timelineCsv = tracks.map((timeline: Array<TimelineTrackModel>) => {
    return timeline.map((item: TimelineTrackModel) => `${item.cameraPosition}:${item.segmentCount}`).join('|')
  }).join(';')
  return nativeMerge(timelineCsv) ?? []
}
