/**
 * (编辑器适配器) 将复杂的剪辑逻辑包装成简单的 UI 动作（如 seekTo, startExport）。
 */
import { Orientation, getEditorLayout } from '../logic/editorLayout.js'
import {
  buildScenarioPreview,
  getScenarioTemplateCards
} from '../logic/scenarioTemplateEngine.js'
import { buildPrivacyPlan, createDefaultPrivacyConfig } from '../logic/privacyConfig.js'

const SPEED_OPTIONS = ['1.0X', '4.0X', '8.0X', '16.0X']

function parseSpeedValue(speedLabel) {
  const matched = Number.parseFloat(String(speedLabel).replace(/x$/i, ''))
  if (!Number.isFinite(matched) || matched <= 0) {
    return 1
  }
  return matched
}

function mapTimelineTrack(track) {
  return {
    cameraPosition: track.cameraPosition,
    segmentCount: track.segments.length,
    degraded: track.degraded
  }
}

function calculateTotalDurationMs(timeline) {
  const totals = timeline.map(track =>
    track.segments.reduce((sum, segment) => sum + Math.max(0, Number(segment.duration) || 0), 0)
  )
  const maxDurationSec = totals.length === 0 ? 0 : Math.max(...totals)
  return maxDurationSec * 1000
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
    this.totalDurationMs = 0
    this.selectionRangeMs = { start: 0, end: 0 }
    this.templateDrawer = {
      expanded: true,
      activeTemplateId: 'T2',
      cards: getScenarioTemplateCards()
    }
    this.previewTemplate = buildScenarioPreview(this.templateDrawer.activeTemplateId, [])
    this.controlDeck = {
      speed: '1.0X',
      muted: false,
      watermarkEnabled: true
    }
    this.privacyConfig = createDefaultPrivacyConfig()
    this.timelineDecorations = {
      boundaryMarkers: []
    }
  }

  loadTrip(trip) {
    const timeline = this.editorSession.loadTrip(trip)
    this.timeline = timeline.map(mapTimelineTrack)
    this.playheadMs = 0
    const totalDurationMs = calculateTotalDurationMs(timeline)
    this.totalDurationMs = totalDurationMs
    this.selectionRangeMs = { start: 0, end: totalDurationMs }
    this.timelineDecorations.boundaryMarkers = this.buildBoundaryMarkers(totalDurationMs)
    this.previewTemplate = this.buildPreviewTemplate()
    return this.getState()
  }

  setOrientation(orientation) {
    this.orientation = orientation === Orientation.LANDSCAPE ? Orientation.LANDSCAPE : Orientation.PORTRAIT
    return this.getState()
  }

  seekTo(positionMs) {
    const bounded = Math.max(this.selectionRangeMs.start, Math.min(positionMs, this.selectionRangeMs.end))
    this.playheadMs = this.editorSession.seekTo(bounded)
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

  updateSelectionRange(startMs, endMs) {
    const duration = this.totalDurationMs
    const clampedStart = Math.max(0, Math.min(startMs, duration))
    const clampedEnd = Math.max(clampedStart, Math.min(endMs, duration))
    this.selectionRangeMs = { start: clampedStart, end: clampedEnd }
    this.playheadMs = Math.max(clampedStart, Math.min(this.playheadMs, clampedEnd))
    return this.getState()
  }

  selectTemplate(templateId) {
    const exists = this.templateDrawer.cards.some(card => card.id === templateId)
    this.templateDrawer.activeTemplateId = exists ? templateId : 'T2'
    this.previewTemplate = this.buildPreviewTemplate()
    return this.getState()
  }

  setDrawerExpanded(expanded) {
    this.templateDrawer.expanded = Boolean(expanded)
    return this.getState()
  }

  cycleSpeed() {
    const index = SPEED_OPTIONS.indexOf(this.controlDeck.speed)
    const nextIndex = index < 0 ? 0 : (index + 1) % SPEED_OPTIONS.length
    this.controlDeck.speed = SPEED_OPTIONS[nextIndex]
    this.applySpeedMuteRule()
    return this.getState()
  }

  toggleMuted() {
    if (this.isForcedMute()) {
      this.controlDeck.muted = true
      return this.getState()
    }
    this.controlDeck.muted = !this.controlDeck.muted
    return this.getState()
  }

  toggleWatermark() {
    this.controlDeck.watermarkEnabled = !this.controlDeck.watermarkEnabled
    return this.getState()
  }

  setControlDeck(nextControlDeck = {}) {
    this.controlDeck = {
      ...this.controlDeck,
      ...nextControlDeck
    }
    if (!SPEED_OPTIONS.includes(this.controlDeck.speed)) {
      this.controlDeck.speed = '1.0X'
    }
    this.applySpeedMuteRule()
    return this.getState()
  }

  setPrivacyConfig(nextPrivacyConfig = {}) {
    this.privacyConfig = {
      ...this.privacyConfig,
      ...nextPrivacyConfig
    }
    return this.getState()
  }

  toggleHideSpeed() {
    this.privacyConfig.hideSpeed = !this.privacyConfig.hideSpeed
    return this.getState()
  }

  toggleHideVin() {
    this.privacyConfig.hideVin = !this.privacyConfig.hideVin
    return this.getState()
  }

  toggleHideGps() {
    this.privacyConfig.hideGps = !this.privacyConfig.hideGps
    return this.getState()
  }

  toggleCinematicCrop() {
    this.privacyConfig.cinematicCrop = !this.privacyConfig.cinematicCrop
    return this.getState()
  }

  isForcedMute() {
    return parseSpeedValue(this.controlDeck.speed) > 1
  }

  applySpeedMuteRule() {
    if (this.isForcedMute()) {
      this.controlDeck.muted = true
    }
  }

  buildBoundaryMarkers(durationMs) {
    const markers = []
    const step = 60000
    for (let position = step; position < durationMs; position += step) {
      markers.push({
        positionMs: position,
        style: 'dashed'
      })
    }
    return markers
  }

  buildPreviewTemplate() {
    const availableTracks = this.timeline.map(track => track.cameraPosition)
    return buildScenarioPreview(this.templateDrawer.activeTemplateId, availableTracks)
  }

  getState() {
    return {
      screen: 'editor',
      orientation: this.orientation,
      layout: getEditorLayout(this.orientation),
      timeline: [...this.timeline],
      playheadMs: this.playheadMs,
      selectionRangeMs: { ...this.selectionRangeMs },
      timelineDecorations: {
        boundaryMarkers: [...this.timelineDecorations.boundaryMarkers]
      },
      templateDrawer: {
        expanded: this.templateDrawer.expanded,
        activeTemplateId: this.templateDrawer.activeTemplateId,
        cards: this.templateDrawer.cards.map(card => ({ ...card }))
      },
      previewTemplate: {
        templateId: this.previewTemplate.templateId,
        title: this.previewTemplate.title,
        aspectRatio: this.previewTemplate.aspectRatio,
        outputSize: { ...this.previewTemplate.outputSize },
        slots: this.previewTemplate.slots.map(slot => ({
          id: slot.id,
          track: slot.track,
          rect: { ...slot.rect },
          radius: slot.radius
        })),
        guides: this.previewTemplate.guides.map(guide => ({
          id: guide.id,
          rect: { ...guide.rect },
          color: guide.color
        }))
      },
      privacyConfig: { ...this.privacyConfig },
      privacyPreview: buildPrivacyPlan(this.privacyConfig),
      controlDeck: {
        ...this.controlDeck,
        forcedMuted: this.isForcedMute()
      },
      syncCorrections: [...this.syncCorrections],
      exportStatus: this.exportStatusViewModel.getState(),
      route: this.router.getState()
    }
  }
}
