/**
 * (剪辑台) 核心调度器。管理 6 个视角的同步播放，处理“主视角”和“从视角”的时间对齐。
 */
import { CameraPosition } from '../model/types.js'
import { buildTrackFallbackPlan } from './trackFallbackPlanner.js'
import { SeamlessPlayer } from './seamlessPlayer.js'
import { assembleVirtualClip } from './virtualTimeline.js'

const CAMERA_ORDER = [
  CameraPosition.FRONT,
  CameraPosition.BACK,
  CameraPosition.LEFT,
  CameraPosition.RIGHT,
  CameraPosition.LEFT_FRONT,
  CameraPosition.RIGHT_FRONT
]

export const SYNC_DRIFT_THRESHOLD_MS = 100

export class MultiTrackEditorSession {
  constructor() {
    this.masterCamera = CameraPosition.FRONT
    this.playheadMs = 0
    this.trackMap = new Map(CAMERA_ORDER.map(camera => [camera, []]))
    this.degradedTracks = []
    this.masterVirtualClip = assembleVirtualClip([])
    this.seamlessPlayer = new SeamlessPlayer()
  }

  loadTrip(trip) {
    const fallback = buildTrackFallbackPlan(trip.videoTracks ?? [])
    this.degradedTracks = [...fallback.degradedTracks]
    this.trackMap = new Map(CAMERA_ORDER.map(camera => [camera, []]))
    for (const track of fallback.timelineTracks) {
      this.trackMap.set(track.cameraPosition, [...track.segments])
    }
    this.playheadMs = 0
    const masterSegments = this.trackMap.get(this.masterCamera) ?? []
    this.masterVirtualClip = assembleVirtualClip(masterSegments, { id: `${this.masterCamera}-virtual-clip` })
    this.seamlessPlayer.loadVirtualClip(this.masterVirtualClip)
    return this.getTimeline()
  }

  seekTo(positionMs) {
    const clamped = Math.max(0, Number(positionMs) || 0)
    const mapping = this.masterVirtualClip.mapTime(clamped)
    this.playheadMs = mapping?.logicalTimeMs ?? clamped
    this.seamlessPlayer.syncToMapping(mapping)
    return this.playheadMs
  }

  applySync(masterTimeMs, slaveTimes) {
    this.playheadMs = Math.max(0, Number(masterTimeMs) || 0)
    const corrections = []
    for (const [camera, slaveTime] of Object.entries(slaveTimes ?? {})) {
      if (camera === this.masterCamera) {
        continue
      }
      const drift = Math.abs(this.playheadMs - slaveTime)
      if (drift > SYNC_DRIFT_THRESHOLD_MS) {
        corrections.push({
          cameraPosition: camera,
          seekToMs: this.playheadMs,
          driftMs: drift
        })
      }
    }
    return corrections
  }

  getTimeline() {
    return CAMERA_ORDER.map(cameraPosition => ({
      cameraPosition,
      segments: [...(this.trackMap.get(cameraPosition) ?? [])],
      degraded: this.degradedTracks.includes(cameraPosition)
    }))
  }

  getSeamlessPlaybackState() {
    return this.seamlessPlayer.getState()
  }

  mapMasterTime(logicalTimeMs) {
    return this.masterVirtualClip.mapTime(logicalTimeMs)
  }

  getMasterBoundaries() {
    return [...(this.masterVirtualClip.boundaries ?? [])]
  }

  getMasterRange(startMs, endMs) {
    return this.masterVirtualClip.calculateRange(startMs, endMs)
  }
}
