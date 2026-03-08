/**
 * (剪辑台) 核心调度器。管理 6 个视角的同步播放，处理“主视角”和“从视角”的时间对齐。
 */
import { CameraPosition } from '../model/types.js'
import { buildTrackFallbackPlan } from './trackFallbackPlanner.js'

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
  }

  loadTrip(trip) {
    const fallback = buildTrackFallbackPlan(trip.videoTracks ?? [])
    this.degradedTracks = [...fallback.degradedTracks]
    this.trackMap = new Map(CAMERA_ORDER.map(camera => [camera, []]))
    for (const track of fallback.timelineTracks) {
      this.trackMap.set(track.cameraPosition, [...track.segments])
    }
    this.playheadMs = 0
    return this.getTimeline()
  }

  seekTo(positionMs) {
    this.playheadMs = Math.max(0, Number(positionMs) || 0)
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
}
