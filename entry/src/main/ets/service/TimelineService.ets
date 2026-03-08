import { TimelineTrackModel } from '../model/AppState'
import { DvrMeta } from '../model/TripModels'
import smartdriveExporter from 'libsmartdrive_exporter.so'
import { ensureCoreApiContract } from './CoreApiContract'

export function buildTimeline(metas: Array<DvrMeta>): Array<TimelineTrackModel> {
  ensureCoreApiContract()
  const nativeBuild = smartdriveExporter.buildTimeline as ((camerasCsv: string) => Array<TimelineTrackModel>) | undefined
  if (typeof nativeBuild !== 'function') {
    throw new Error('smartdrive_exporter.buildTimeline 未实现')
  }
  const camerasCsv = metas.map((item: DvrMeta) => item.camera).join(',')
  return nativeBuild(camerasCsv) ?? []
}

export function mergeTimeline(tracks: Array<Array<TimelineTrackModel>>): Array<TimelineTrackModel> {
  ensureCoreApiContract()
  const nativeMerge = smartdriveExporter.mergeTimeline as ((timelineCsv: string) => Array<TimelineTrackModel>) | undefined
  if (typeof nativeMerge !== 'function') {
    throw new Error('smartdrive_exporter.mergeTimeline 未实现')
  }
  const timelineCsv = tracks.map((timeline: Array<TimelineTrackModel>) => {
    return timeline.map((item: TimelineTrackModel) => `${item.cameraPosition}:${item.segmentCount}`).join('|')
  }).join(';')
  return nativeMerge(timelineCsv) ?? []
}
