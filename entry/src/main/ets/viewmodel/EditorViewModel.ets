import { CoreBridge, sharedCoreBridge } from '../bridge/CoreBridge'
import {
  getCameraZhNameById,
  getTemplateResolutionById,
  getTemplateUiNameById,
  normalizeCameraNameById
} from '../constants/AppConstants'
import { EditorStateModel, TemplateCardModel, TimelineTrackModel } from '../model/AppState'
import { createEditorStateFromSnapshot, deepCloneExportSnapshot, ExportSnapshot, resolveTemplateDefinition, TemplateId } from '../model/Models'
import { formatSegmentDuration as segmentDurationText, outputDurationSec, Segment } from '../model/SegmentModel'
import { DvrMeta, TripSnapshot } from '../model/TripModels'
import { WorkMeta } from '../model/WorkMeta'
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

  /**
   * 从「我的剪辑」的一条作品进入剪辑页。
   *
   * 与 hydrate 的区别只有一处：编辑器状态不是新建的白纸，而是按 sidecar 还原的。
   * 素材以现场为准（由调用方按文件名逐位装配好传进来），sidecar 只提供参数
   * （模板 / 分段 / 水印 / 播放头）。
   *
   * `tripSnapshot` 直接用传进来的 `live`：合成快照**不注册进行程库**，按
   * `state.tripId` 回查是查不到的（CoreBridge 里另有一个单槽兜底，见其注释）。
   */
  hydrateFromWork(live: TripSnapshot, meta: WorkMeta): EditorHydrateResult {
    const state = this.bridge.restoreEditorStateFromLive(live, meta)
    return {
      state,
      tripSnapshot: live,
      exportSessionSeed: `${live.id}_${Date.now()}`
    }
  }

  /** 相册权限的最近一次判定（转发 CoreBridge）。还原三态的第一道分叉。 */
  isPermissionGranted(): boolean {
    return this.bridge.isPermissionGranted()
  }

  /**
   * 行程库里全部行程的源片段，摊平成一个数组。
   *
   * 还原的片段级校验要的是「这些源文件现在还在不在」，与它属于哪趟行程无关 ——
   * 一件作品可能是跨行程、跨机位拼出来的。
   */
  allLibraryClips(): Array<DvrMeta> {
    return this.bridge.allLibraryClips()
  }

  seekGlobalPlayhead(second: number): EditorStateModel {
    // 不在这里取整：片段边界是拖手柄拖出来的小数秒，取整会让播放头落到边界之外，
    // 参数行、画面与剪刀各说各话。精度由 CoreBridge.seekGlobalPlayhead 按毫秒兜底。
    return this.bridge.seekGlobalPlayhead(second)
  }

  updatePlayheadText(playheadSec: number): string {
    return this.bridge.updatePlayhead(Math.floor(playheadSec * 1000))
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

  /** 在播放头处落刀（转发 CoreBridge，plan:735）。 */
  splitAtPlayhead(): EditorStateModel {
    return this.bridge.splitAtPlayhead()
  }

  deleteSegment(id: number): EditorStateModel {
    return this.bridge.deleteSegment(id)
  }

  adjustSegmentBoundary(id: number, edge: 'start' | 'end', sec: number): EditorStateModel {
    return this.bridge.adjustSegmentBoundary(id, edge, sec)
  }

  /** 灰段恢复 / 启用段置灰（转发 CoreBridge，plan:736）。 */
  toggleSegmentEnabled(id: number): EditorStateModel {
    return this.bridge.toggleSegmentEnabled(id)
  }

  /** 选中某一段（转发 CoreBridge，plan:737）。 */
  selectSegment(id: number): EditorStateModel {
    return this.bridge.selectSegment(id)
  }

  /** 剪刀置灰判据（plan:738）。 */
  canSplitAtPlayhead(): boolean {
    return this.bridge.canSplitAtPlayhead()
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
    const exported = draft.playback.segments
    const endMs = exported.length > 0 ? exported[exported.length - 1].endMs : playheadMs
    draft.playback.playheadMs = Math.max(0, Math.min(playheadMs, endMs))
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
    if (template.templateId === TemplateId.T2) {
      return 1920 / 2160
    }
    if (template.templateId === TemplateId.T3) {
      return 1920 / 1620
    }
    if (template.templateId === TemplateId.T5 || template.templateId === TemplateId.T6) {
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


  /** 判断当前是否处于空白区间（未选中任何段且非全片原始态）。 */
  isGap(state: EditorStateModel): boolean {
    return !state.isRawFull && state.selectedSegmentId === -1
  }

  /** 选中段（显式选中状态，spec D11/§5.7）；id 不存在时返回 undefined。 */
  getSelectedSegment(state: EditorStateModel): Segment | undefined {
    return state.segments.find((item: Segment) => item.id === state.selectedSegmentId)
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
