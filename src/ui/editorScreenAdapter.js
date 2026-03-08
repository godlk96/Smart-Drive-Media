/**
 * (编辑器适配器) 将复杂的剪辑逻辑包装成简单的 UI 动作（如 seekTo, startExport）。
 */
import { Orientation, getEditorLayout } from '../logic/editorLayout.js'

function mapTimelineTrack(track) {
  return {
    cameraPosition: track.cameraPosition,
    segmentCount: track.segments.length,
    degraded: track.degraded
  }
}

export class EditorScreenAdapter {
  constructor({ editorSession, exportStatusViewModel, router }) {
    this.editorSession = editorSession
    this.exportStatusViewModel = exportStatusViewModel
    this.router = router
    this.orientation = Orientation.PORTRAIT
    this.timeline = []
    this.playheadMs = 0
    this.syncCorrections = []
  }

  loadTrip(trip) {
    const timeline = this.editorSession.loadTrip(trip)
    this.timeline = timeline.map(mapTimelineTrack)
    this.playheadMs = 0
    return this.getState()
  }

  setOrientation(orientation) {
    this.orientation = orientation === Orientation.LANDSCAPE ? Orientation.LANDSCAPE : Orientation.PORTRAIT
    return this.getState()
  }

  seekTo(positionMs) {
    this.playheadMs = this.editorSession.seekTo(positionMs)
    return this.getState()
  }

  syncToMaster(slaveTimes) {
    this.syncCorrections = this.editorSession.applySync(this.playheadMs, slaveTimes)
    return this.getState()
  }

  startExport(outputPath) {
    this.exportStatusViewModel.start(outputPath)
    return this.getState()
  }

  updateExportProgress(progress) {
    this.exportStatusViewModel.progress(progress)
    return this.getState()
  }

  finishExportSuccess() {
    this.exportStatusViewModel.success()
    return this.getState()
  }

  finishExportFail(message) {
    this.exportStatusViewModel.fail(message)
    return this.getState()
  }

  backToLibrary() {
    return this.router.back()
  }

  getState() {
    return {
      screen: 'editor',
      orientation: this.orientation,
      layout: getEditorLayout(this.orientation),
      timeline: [...this.timeline],
      playheadMs: this.playheadMs,
      syncCorrections: [...this.syncCorrections],
      exportStatus: this.exportStatusViewModel.getState(),
      route: this.router.getState()
    }
  }
}
