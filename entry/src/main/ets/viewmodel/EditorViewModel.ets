import { CoreBridge, sharedCoreBridge } from '../bridge/CoreBridge'
import {
  getCameraZhNameById,
  getTemplateIconById,
  getTemplateResolutionById,
  getTemplateUiNameById,
  normalizeCameraNameById
} from '../constants/AppConstants'
import { ExportPayloadTranslator } from '../core/translator/ExportPayloadTranslator'
import { FFmpegCommandTranslator } from '../core/translator/FFmpegCommandTranslator'
import { PreviewPayload, PreviewPayloadTranslator } from '../core/translator/PreviewPayloadTranslator'
import { EditorStateModel, TemplateCardModel, TimelineTrackModel } from '../model/AppState'
import { ExportSnapshot, resolveTemplateDefinition, TemplateId } from '../model/Models'
import { TripSnapshot } from '../model/TripModels'
import { debugLog } from '../utils/Logger'

export interface EditorHydrateResult {
  state: EditorStateModel
  tripSnapshot: TripSnapshot
  exportSessionSeed: string
}

export class EditorViewModel {
  private bridge: CoreBridge
  private exportPayloadTranslator = new ExportPayloadTranslator()
  private previewPayloadTranslator = new PreviewPayloadTranslator()
  private ffmpegTranslator = new FFmpegCommandTranslator()
  private templateSwitchSeed: number = 0
  private switchTaskId: number = 0
  private isTemplateSwitching: boolean = false

  constructor(bridge: CoreBridge = sharedCoreBridge) {
    this.bridge = bridge
  }

  hydrate(tripId: string): EditorHydrateResult {
    const state = this.bridge.createEditorState(tripId, '', '')
    const tripSnapshot = this.bridge.getTripSnapshotClone(state.tripId) ?? new TripSnapshot()
    return {
      state,
      tripSnapshot,
      exportSessionSeed: `${tripId}_${Date.now()}`
    }
  }

  seekGlobalPlayhead(second: number): EditorStateModel {
    return this.bridge.seekGlobalPlayhead(Math.floor(second))
  }

  updatePlayheadText(playheadSec: number): string {
    return this.bridge.updatePlayhead(Math.floor(playheadSec * 1000))
  }

  updateSelectionRange(startSec: number, endSec: number): EditorStateModel {
    return this.bridge.updateSelectionRange(startSec, endSec)
  }

  selectTemplate(templateId: string): EditorStateModel {
    return this.bridge.selectTemplate(templateId)
  }

  beginTemplateSwitchTask(): number {
    if (this.isTemplateSwitching) {
      return -1
    }
    this.templateSwitchSeed += 1
    this.switchTaskId = this.templateSwitchSeed
    this.isTemplateSwitching = true
    return this.switchTaskId
  }

  isTemplateSwitchTaskValid(taskId: number): boolean {
    return taskId > 0 && this.isTemplateSwitching && this.switchTaskId === taskId
  }

  finishTemplateSwitchTask(taskId: number): void {
    if (this.switchTaskId === taskId) {
      this.switchTaskId = 0
      this.isTemplateSwitching = false
    }
  }

  getTemplateSwitchTaskId(): number {
    return this.switchTaskId
  }

  getIsTemplateSwitching(): boolean {
    return this.isTemplateSwitching
  }

  changeTemplate(templateId: string, taskId: number): EditorStateModel | undefined {
    if (!this.isTemplateSwitchTaskValid(taskId)) {
      return undefined
    }
    return this.bridge.selectTemplate(templateId)
  }

  switchCamera(camera: string): EditorStateModel {
    return this.bridge.switchCamera(camera)
  }

  toggleTemplateDrawer(expanded: boolean): EditorStateModel {
    return this.bridge.toggleTemplateDrawer(expanded)
  }

  cycleSpeed(): EditorStateModel {
    return this.bridge.cycleSpeed()
  }

  toggleMuted(): EditorStateModel {
    return this.bridge.toggleMuted()
  }

  setMuted(value: boolean): EditorStateModel {
    return this.bridge.setMuted(value)
  }

  toggleWatermark(): EditorStateModel {
    return this.bridge.toggleWatermark()
  }

  updatePrivacy(type: string, enabled: boolean): EditorStateModel {
    return this.bridge.updatePrivacy(type, enabled)
  }

  setExportStatusText(statusText: string): void {
    this.bridge.setExportStatusText(statusText)
  }

  buildExportSnapshot(state: EditorStateModel, exportSessionSeed: string): ExportSnapshot | undefined {
    const tripSnapshot = this.bridge.getTripSnapshotClone(state.tripId)
    return this.exportPayloadTranslator.translate({
      tripSnapshot,
      editorState: state,
      sessionId: exportSessionSeed
    })
  }

  buildFfmpegArgs(state: EditorStateModel, exportSessionSeed: string): Array<string> {
    const snapshot = this.buildExportSnapshot(state, exportSessionSeed)
    if (!snapshot) {
      return []
    }
    return this.ffmpegTranslator.translate(snapshot)
  }

  buildPreviewPayload(state: EditorStateModel): PreviewPayload {
    return this.previewPayloadTranslator.translate(state)
  }

  getTripSnapshot(tripId: string): TripSnapshot {
    return this.bridge.getTripSnapshotClone(tripId) ?? new TripSnapshot()
  }

  getTemplateUiName(card: TemplateCardModel): string {
    const name = getTemplateUiNameById(card.id)
    if (name.length > 0) {
      return name
    }
    return card.title
  }

  getTemplateResolution(card: TemplateCardModel): string {
    const resolution = getTemplateResolutionById(card.id)
    if (resolution.length > 0) {
      return resolution
    }
    return '3840×1080'
  }

  getTemplateIcon(card: TemplateCardModel): string {
    const icon = getTemplateIconById(card.id)
    if (icon.length > 0) {
      return icon
    }
    return '🎬'
  }

  templateSupportsMosaic(templateId: string): boolean {
    return templateId === TemplateId.T1 || templateId === TemplateId.T2 || templateId === TemplateId.T5
  }

  normalizeCameraName(camera: string): string {
    return normalizeCameraNameById(camera)
  }

  cameraZhName(camera: string): string {
    const normalized = this.normalizeCameraName(camera)
    return getCameraZhNameById(normalized)
  }

  isTemplateDisabled(card: TemplateCardModel, timeline: Array<TimelineTrackModel>): boolean {
    const definition = resolveTemplateDefinition(card.id)
    const tracks = timeline.map((item: TimelineTrackModel) => this.normalizeCameraName(item.cameraPosition))
    return definition.requiredCameras.some((camera) => !tracks.some((item: string) => item === this.normalizeCameraName(String(camera))))
  }

  getTemplateMissingViews(card: TemplateCardModel, timeline: Array<TimelineTrackModel>): string {
    const definition = resolveTemplateDefinition(card.id)
    const tracks = timeline.map((item: TimelineTrackModel) => this.normalizeCameraName(item.cameraPosition))
    const missing = definition.requiredCameras
      .filter((camera) => !tracks.some((item: string) => item === this.normalizeCameraName(String(camera))))
      .map((camera) => this.cameraZhName(this.normalizeCameraName(String(camera))))
    return missing.join('、')
  }

  getPreviewAspectRatio(templateId: string): number {
    const template = resolveTemplateDefinition(templateId)
    if (template.templateId === TemplateId.T1) {
      return 1920 / 2160
    }
    if (template.templateId === TemplateId.T2) {
      return 1920 / 1620
    }
    if (template.templateId === TemplateId.T3 || template.templateId === TemplateId.T4) {
      return 3840 / 1080
    }
    return 16 / 9
  }

  getPlaybackRate(speedLabel: string): number {
    const normalized = speedLabel.replace('X', '')
    const parsed = Number(normalized)
    if (parsed >= 1.0 && parsed <= 4) {
      return parsed
    }
    return 1.0
  }

  getTimelineTicks(totalDurationSec: number): Array<number> {
    const result: Array<number> = []
    const interval = totalDurationSec <= 60 ? 10 : 30
    for (let point = 0; point <= totalDurationSec; point += interval) {
      result.push(point)
    }
    if (result.length === 0 || result[result.length - 1] !== totalDurationSec) {
      result.push(totalDurationSec)
    }
    return result
  }

  formatTimelineTick(seconds: number): string {
    const min = Math.floor(seconds / 60)
    const sec = Math.floor(seconds % 60)
    return `${min}:${sec.toString().padStart(2, '0')}`
  }

  logPreviewPayload(state: EditorStateModel): void {
    const payload = this.buildPreviewPayload(state)
    debugLog('剪辑VM', `预览翻译结果 template=${payload.templateId} slots=${payload.slots.length}`)
  }
}
