/**
 * (备胎计划) 当某个视角的视频丢失时，决定用什么来占位（比如显示黑屏或提示图片），防止崩溃。
 */
import { CameraPosition } from '../model/types.js'

const CAMERA_ORDER = [
  CameraPosition.FRONT,
  CameraPosition.BACK,
  CameraPosition.LEFT,
  CameraPosition.RIGHT,
  CameraPosition.LEFT_FRONT,
  CameraPosition.RIGHT_FRONT
]

export function buildTrackFallbackPlan(videoTracks) {
  const sourceMap = new Map(videoTracks.map(track => [track.cameraPosition, track]))
  const degradedTracks = []
  const timelineTracks = CAMERA_ORDER.map(camera => {
    const found = sourceMap.get(camera)
    if (!found || !Array.isArray(found.segments) || found.segments.length === 0) {
      degradedTracks.push(camera)
      return {
        cameraPosition: camera,
        mode: 'placeholder',
        segments: []
      }
    }
    return {
      cameraPosition: camera,
      mode: 'normal',
      segments: [...found.segments]
    }
  })

  return {
    timelineTracks,
    degradedTracks
  }
}
