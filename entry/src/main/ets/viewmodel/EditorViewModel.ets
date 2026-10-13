import { CoreBridge, sharedCoreBridge } from '../bridge/CoreBridge'
import {
  getCameraZhNameById,
  getTemplateIconById,
  getTemplateResolutionById,
  getTemplateUiNameById,
  normalizeCameraNameById
} from '../constants/AppConstants'
import { EditorStateModel, TemplateCardModel, TimelineTrackModel } from '../model/AppState'
import { createEditorStateFromSnapshot, deepCloneExportSnapshot, ExportSnapshot, resolveTemplateDefinition, TemplateId } from '../model/Models'
import { formatSegmentDuration as segmentDurationText, outputDurationSec, segmentIndexAtSec, Segment } from '../model/SegmentModel'
import { TripSnapshot } from '../model/TripModels'
import { debugLog } from '../utils/Logger'

export interface EditorHydrateResult {
  state: EditorStateModel
  tripSnapshot: TripSnapshot
  exportSessionSeed: string
}

export class EditorViewModel {
  private bridge: CoreBridge

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

  /**
   * 切换模板。这里曾经是一个 taskId 状态机（beginTemplateSwitchTask /
   * isTemplateSwitchTaskValid / finishTemplateSwitchTask + 三个私有字段），
   * 用途是与预览区做"就绪"握手。预览区的布局与段绑定现在是同步的，
   * 握手不再有存在理由 —— 切换就是一个同步的状态变更。
   */
  changeTemplate(templateId: string): EditorStateModel {
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

  setExportStatusText(statusText: string): void {
    this.bridge.setExportStatusText(statusText)
  }

  buildExportSnapshot(state: EditorStateModel, exportSessionSeed: string): ExportSnapshot | undefined {
    const tripSnapshot = this.bridge.getTripSnapshotClone(state.tripId)
    if (!tripSnapshot) {
      return undefined
    }
    const draft = createEditorStateFromSnapshot(
      tripSnapshot,
      exportSessionSeed,
      state.activeTemplateId,
      state.segments,
      state.watermarkEnabled,
      state.drawerExpanded,
      state.exportStatusText
    )
    const playheadMs = Math.floor(state.playheadSec * 1000)
    draft.playback.playheadMs = Math.max(0, Math.min(playheadMs, draft.playback.rangeEndMs))
    return deepCloneExportSnapshot(draft)
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
    if (parsed >= 0.75 && parsed <= 2.0) {
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

  /** 播放头所在的那一段（即选中段）；不在任何段内返回 undefined。 */
  getSelectedSegment(state: EditorStateModel): Segment | undefined {
    const at = segmentIndexAtSec(state.segments, state.playheadSec)
    if (at < 0) {
      return undefined
    }
    return state.segments[at]
  }

  /** 段时长文案，只写时长不写起止（spec D9/D10）。 */
  formatSegmentDuration(segment: Segment): string {
    return segmentDurationText(segment)
  }

  /** 成片时长：各启用段按各自倍速换算后求和。 */
  getOutputDurationSec(state: EditorStateModel): number {
    return outputDurationSec(state.segments)
  }

  logPreviewPayload(state: EditorStateModel): void {
    debugLog('剪辑VM', `预览状态 template=${state.activeTemplateId} slots=${state.previewSlots.length}`)
  }
}
