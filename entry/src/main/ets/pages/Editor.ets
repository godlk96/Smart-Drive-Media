import { EditorPreviewArea } from '../components/EditorPreviewArea'
import { sharedCoreBridge } from '../bridge/CoreBridge'
import { EditorStateModel, TemplateCardModel, TimelineMarkerModel, TimelineTrackModel } from '../model/AppState'
import { createEditorStateFromSnapshot, deepCloneExportSnapshot, ExportSnapshot, resolveTemplateDefinition } from '../model/Models'
import { TripSnapshot } from '../model/TripModels'
import { startNativeExport } from '../NativeExportManager'
import { debugLog } from '../utils/Logger'
import common from '@ohos.app.ability.common'

@Entry
@Component
struct Editor {
  private bridge = sharedCoreBridge
  private exportSessionSeed: string = ''
  private controlsTimer: number = -1
  private lastLoggedSecond: number = -1
  @State private showPlayerControls: boolean = true
  @State private showPreviewCover: boolean = true
  @State private previewPlaying: boolean = false
  private isSwitchingTemplate: boolean = false
  private isTimelineDragging: boolean = false
  private isSettlingAfterDrag: boolean = false
  private dragPreviewSec: number = 0
  private settleTargetSec: number = 0
  private settleTimer: number = -1
  private readonly settleWindowMs: number = 260
  private lastStablePlayheadSec: number = 0
  private readonly minuteBoundaryHysteresisSec: number = 0.35
  @State private seekToken: number = 0
  @State private tripSnapshot: TripSnapshot = new TripSnapshot()
  @State private previewRenderVersion: number = 0
  @State private showSlotLabels: boolean = false
  @State private exportLoadingVisible: boolean = false
  @State private exportLoadingText: string = '导出处理中...'
  @State private hasUnsavedChanges: boolean = false
  @State private backConfirmVisible: boolean = false
  @State private toastText: string = ''
  @State private toastVisible: boolean = false
  @State private clipMarks: Array<number> = []
  @State private mosaicEnabledUi: boolean = true
  private toastTimer: number = -1
  @State private state: EditorStateModel = {
    tripId: '',
    tripTitle: '剪辑工作台',
    timeRange: '',
    previewUri: '',
    previewCamera: '',
    playheadSec: 0,
    canPlayPrev: false,
    canPlayNext: false,
    currentClipIndex: 0,
    currentClipTotal: 0,
    playheadText: '00:00:00 / 00:20:00',
    totalDurationSec: 60,
    timeline: [],
    layers: [],
    selectionStartSec: 0,
    selectionEndSec: 60,
    boundaryMarkers: [],
    templateCards: [],
    previewSlots: [],
    activeTemplateId: 'T2',
    drawerExpanded: true,
    speedLabel: '1.0X',
    muted: false,
    watermarkEnabled: true,
    hideSpeed: true,
    hideGps: true,
    hideVin: true,
    exportStatusText: '待导出'
  }

  private applyState(nextState: EditorStateModel): void {
    const normalizedPlayhead = Math.max(0, Math.min(nextState.playheadSec, nextState.totalDurationSec))
    nextState.playheadSec = normalizedPlayhead
    this.state = nextState
  }

  private updatePlayheadText(text: string): void {
    const nextState = this.state
    nextState.playheadText = text
    this.state = nextState
  }

  private updatePlayheadSec(sec: number): void {
    const clamped = Math.max(0, Math.min(sec, this.state.totalDurationSec))
    this.lastStablePlayheadSec = clamped
    const nextState = this.state
    nextState.playheadSec = clamped
    this.state = nextState
  }

  private stabilizeMinuteBoundary(rawSec: number): number {
    const clamped = Math.max(0, Math.min(rawSec, this.state.totalDurationSec))
    const last = this.lastStablePlayheadSec
    if (last <= 0) {
      return clamped
    }
    const lastMinute = Math.floor(last / 60)
    const currentMinute = Math.floor(clamped / 60)
    if (lastMinute === currentMinute) {
      return clamped
    }
    const boundary = Math.max(lastMinute, currentMinute) * 60
    if (Math.abs(clamped - boundary) < this.minuteBoundaryHysteresisSec) {
      return last
    }
    return clamped
  }

  aboutToAppear(): void {
    let params: Record<string, string> = {}
    try {
      params = this.getUIContext().getRouter().getParams() as Record<string, string>
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('剪辑页', `读取路由参数失败：${message}`)
    }
    const tripId = params.tripId ?? 'trip-demo-1'
    const title = params.title ?? ''
    const subtitle = params.subtitle ?? ''
    debugLog('剪辑页', `进入页面，行程ID=${tripId}，标题提示=${title}，副标题提示=${subtitle}`)
    this.exportSessionSeed = `${tripId}_${Date.now()}`
    this.applyState(this.bridge.createEditorState(tripId, title, subtitle))
    this.tripSnapshot = this.bridge.getTripSnapshotClone(this.state.tripId) ?? new TripSnapshot()
    this.showPreviewCover = this.state.previewUri.length > 0
    this.previewPlaying = false
    this.showPlayerControls = true
    this.scheduleHideControls()
    this.hasUnsavedChanges = false
    this.backConfirmVisible = false
    this.clipMarks = []
    this.mosaicEnabledUi = true
    const trackSummary = this.state.timeline.map((item: TimelineTrackModel) => `${item.cameraPosition}:${item.segmentCount}`).join(',')
    debugLog('剪辑诊断', `初始化完成，时长=${this.state.totalDurationSec}s，轨道数=${this.state.timeline.length}，轨道明细=${trackSummary}，预览URI长度=${this.state.previewUri.length}，预览视角=${this.state.previewCamera}`)
  }

  aboutToDisappear(): void {
    this.clearHideControlsTimer()
    this.clearSettleTimer()
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer)
      this.toastTimer = -1
    }
  }

  private clearHideControlsTimer(): void {
    if (this.controlsTimer >= 0) {
      clearTimeout(this.controlsTimer)
      this.controlsTimer = -1
    }
  }

  private scheduleHideControls(): void {
    this.clearHideControlsTimer()
    this.controlsTimer = setTimeout(() => {
      this.showPlayerControls = false
      debugLog('剪辑诊断', '播放器控件自动隐藏')
    }, 3000)
  }

  private clearSettleTimer(): void {
    if (this.settleTimer >= 0) {
      clearTimeout(this.settleTimer)
      this.settleTimer = -1
    }
  }

  private showControlsTemporarily(): void {
    this.showPlayerControls = true
    this.scheduleHideControls()
  }

  private getPreviewAspectRatio(): number {
    const template = resolveTemplateDefinition(this.state.activeTemplateId)
    if (template.templateId === 'T1') {
      return 1920 / 2160
    }
    if (template.templateId === 'T2') {
      return 1920 / 1620
    }
    if (template.templateId === 'T3' || template.templateId === 'T4') {
      return 3840 / 1080
    }
    return 16 / 9
  }

  private hasPreviewSource(): boolean {
    return this.state.previewSlots.some((slot) => slot.uri.length > 0)
  }

  private startAllPreview(): void {
    this.showPreviewCover = false
    this.previewPlaying = true
    debugLog('剪辑诊断', `触发统一播放，目标倍速=${this.getPlaybackRate()}X`)
  }

  private pauseAllPreview(): void {
    this.previewPlaying = false
    debugLog('剪辑诊断', `触发统一暂停，当前倍速=${this.getPlaybackRate()}X`)
  }

  private togglePreviewPlay(): void {
    if (this.previewPlaying) {
      this.pauseAllPreview()
      debugLog('剪辑诊断', '点击暂停预览，已同步暂停全部画面')
    } else {
      if (Math.abs(this.state.playheadSec - this.state.totalDurationSec) < 0.2) {
        this.syncGlobalPlayhead(0, true)
      }
      this.startAllPreview()
      this.showPreviewCover = false
      debugLog('剪辑诊断', '点击播放预览，已同步播放全部画面')
    }
    this.showControlsTemporarily()
  }

  private toggleSlotLabels(): void {
    this.showSlotLabels = !this.showSlotLabels
    debugLog('剪辑诊断', `切换视角标注显示=${this.showSlotLabels}`)
  }

  private toPercent(value: number): string {
    const percent = Math.max(0, Math.min(100, value * 100))
    return `${percent}%`
  }

  private getPlaybackRate(): number {
    const normalized = this.state.speedLabel.replace('X', '')
    const parsed = Number(normalized)
    if (parsed >= 1.0 && parsed <= 4) {
      return parsed
    }
    return 1.0
  }

  private syncGlobalPlayhead(second: number, fromUser: boolean, commitSeek: boolean = true): void {
    const clamped = Math.max(0, Math.min(second, this.state.totalDurationSec))
    this.updatePlayheadSec(clamped)
    if (commitSeek) {
      this.applyState(this.bridge.seekGlobalPlayhead(Math.floor(clamped)))
      this.seekToken += 1
    }
    this.updatePlayheadText(this.bridge.updatePlayhead(Math.floor(this.state.playheadSec * 1000)))
    if (fromUser && commitSeek && Math.floor(clamped) !== this.lastLoggedSecond) {
      this.lastLoggedSecond = Math.floor(clamped)
      debugLog('剪辑页', `拖动全局进度，秒=${Math.floor(clamped)}，片段=${this.state.currentClipIndex}/${this.state.currentClipTotal}`)
    }
    if (fromUser) {
      this.hasUnsavedChanges = true
      this.showControlsTemporarily()
    }
  }

  private markUnsaved(): void {
    this.hasUnsavedChanges = true
  }

  private showToast(message: string): void {
    this.toastText = message
    this.toastVisible = true
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer)
    }
    this.toastTimer = setTimeout(() => {
      this.toastVisible = false
      this.toastTimer = -1
    }, 2000)
  }

  private getTemplateUiName(card: TemplateCardModel): string {
    if (card.id === 'T5') {
      return '单视角'
    }
    if (card.id === 'T1') {
      return '防追尾双录'
    }
    if (card.id === 'T2') {
      return '避险防加塞'
    }
    if (card.id === 'T3') {
      return '左右盲区'
    }
    if (card.id === 'T4') {
      return '沉浸式旅拍'
    }
    return card.title
  }

  private getTemplateResolution(card: TemplateCardModel): string {
    if (card.id === 'T5') {
      return '1920×1080'
    }
    if (card.id === 'T1') {
      return '1920×2160'
    }
    if (card.id === 'T2') {
      return '1920×1620'
    }
    return '3840×1080'
  }

  private getTemplateIcon(card: TemplateCardModel): string {
    if (card.id === 'T5') {
      return '📹'
    }
    if (card.id === 'T1') {
      return '📹📹'
    }
    if (card.id === 'T2') {
      return '👁️👁️👁️'
    }
    if (card.id === 'T3') {
      return '⬅️➡️'
    }
    return '🎬'
  }

  private templateSupportsMosaic(templateId: string): boolean {
    return templateId === 'T1' || templateId === 'T2' || templateId === 'T5'
  }

  private templateSupportsAudio(templateId: string): boolean {
    return true
  }

  private normalizeCameraName(camera: string): string {
    if (camera === 'FRONT') {
      return 'Front'
    }
    if (camera === 'REAR') {
      return 'Back'
    }
    if (camera === 'LEFT') {
      return 'Left'
    }
    if (camera === 'RIGHT') {
      return 'Right'
    }
    if (camera === 'LEFT_FRONT') {
      return 'LeftFront'
    }
    if (camera === 'RIGHT_FRONT') {
      return 'RightFront'
    }
    return camera
  }

  private cameraZhName(camera: string): string {
    const normalized = this.normalizeCameraName(camera)
    if (normalized === 'Front') {
      return '前'
    }
    if (normalized === 'Back') {
      return '后'
    }
    if (normalized === 'Left') {
      return '左后'
    }
    if (normalized === 'Right') {
      return '右后'
    }
    if (normalized === 'LeftFront') {
      return '左前'
    }
    if (normalized === 'RightFront') {
      return '右前'
    }
    return normalized
  }

  private isTemplateDisabled(card: TemplateCardModel): boolean {
    const definition = resolveTemplateDefinition(card.id)
    const tracks = this.state.timeline.map((item: TimelineTrackModel) => this.normalizeCameraName(item.cameraPosition))
    return definition.requiredCameras.some((camera) => !tracks.some((item: string) => item === this.normalizeCameraName(String(camera))))
  }

  private getTemplateMissingViews(card: TemplateCardModel): string {
    const definition = resolveTemplateDefinition(card.id)
    const tracks = this.state.timeline.map((item: TimelineTrackModel) => this.normalizeCameraName(item.cameraPosition))
    const missing = definition.requiredCameras
      .filter((camera) => !tracks.some((item: string) => item === this.normalizeCameraName(String(camera))))
      .map((camera) => this.cameraZhName(this.normalizeCameraName(String(camera))))
    return missing.join('、')
  }

  private selectTemplateForUi(card: TemplateCardModel): void {
    if (this.isTemplateDisabled(card)) {
      const missing = this.getTemplateMissingViews(card)
      this.showToast(`缺少${missing}视角，无法使用该模板`)
      return
    }
    this.selectTemplate(card)
  }

  private addClipMark(): void {
    if (this.clipMarks.length >= 2) {
      this.showToast('最多只能添加2个剪辑点')
      return
    }
    const marks = [...this.clipMarks, Math.floor(this.state.playheadSec)]
    this.clipMarks = marks
    if (marks.length === 2) {
      const start = Math.min(marks[0], marks[1])
      const end = Math.max(marks[0], marks[1])
      this.applyState(this.bridge.updateSelectionRange(start, end))
      this.syncGlobalPlayhead(this.state.playheadSec, false)
    }
    this.markUnsaved()
    this.showToast('已添加剪辑点')
  }

  private undoClipMark(): void {
    if (this.clipMarks.length === 0) {
      this.showToast('没有可撤回的剪辑点')
      return
    }
    const marks = [...this.clipMarks]
    marks.pop()
    this.clipMarks = marks
    if (marks.length === 0) {
      this.applyState(this.bridge.updateSelectionRange(0, this.state.totalDurationSec))
    } else if (marks.length === 1) {
      this.applyState(this.bridge.updateSelectionRange(marks[0], this.state.totalDurationSec))
    }
    this.markUnsaved()
    this.showToast('已撤回上次剪辑点')
  }

  private getPlayheadPercent(): string {
    const total = Math.max(1, this.state.totalDurationSec)
    const value = Math.max(0, Math.min(100, (this.state.playheadSec / total) * 100))
    return `${value}%`
  }

  private getClipSegmentLeft(): string {
    if (this.clipMarks.length < 2) {
      return '0%'
    }
    const total = Math.max(1, this.state.totalDurationSec)
    const start = Math.min(this.clipMarks[0], this.clipMarks[1])
    return `${Math.max(0, Math.min(100, (start / total) * 100))}%`
  }

  private getClipSegmentWidth(): string {
    if (this.clipMarks.length < 2) {
      return '0%'
    }
    const total = Math.max(1, this.state.totalDurationSec)
    const start = Math.min(this.clipMarks[0], this.clipMarks[1])
    const end = Math.max(this.clipMarks[0], this.clipMarks[1])
    return `${Math.max(0, Math.min(100, ((end - start) / total) * 100))}%`
  }

  private markPercent(mark: number): string {
    const total = Math.max(1, this.state.totalDurationSec)
    return `${Math.max(0, Math.min(100, (mark / total) * 100))}%`
  }

  private formatTimelineTick(seconds: number): string {
    const min = Math.floor(seconds / 60)
    const sec = Math.floor(seconds % 60)
    return `${min}:${sec.toString().padStart(2, '0')}`
  }

  private getTimelineTicks(): Array<number> {
    const result: Array<number> = []
    const interval = this.state.totalDurationSec <= 60 ? 10 : 30
    for (let point = 0; point <= this.state.totalDurationSec; point += interval) {
      result.push(point)
    }
    if (result.length === 0 || result[result.length - 1] !== this.state.totalDurationSec) {
      result.push(this.state.totalDurationSec)
    }
    return result
  }

  private getSegmentInfoText(): string {
    return `已添加 ${this.clipMarks.length} 个剪辑点 | 总时长 ${this.state.totalDurationSec} 秒`
  }

  private handleBack(): void {
    if (this.hasUnsavedChanges) {
      this.backConfirmVisible = true
      return
    }
    try {
      this.getUIContext().getRouter().back()
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('剪辑页', `返回失败：${message}`)
    }
  }

  private confirmBack(): void {
    this.backConfirmVisible = false
    try {
      this.getUIContext().getRouter().back()
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('剪辑页', `返回失败：${message}`)
    }
  }

  private cancelBack(): void {
    this.backConfirmVisible = false
  }

  private toggleMosaicByUi(value: boolean): void {
    this.mosaicEnabledUi = value
    this.markUnsaved()
  }

  private handlePreviewPlayheadChanged(playheadMs: number): void {
    if (!this.previewPlaying || this.isTimelineDragging) {
      return
    }
    const nextSec = Math.max(0, Math.min(this.state.totalDurationSec, playheadMs / 1000))
    if (this.isSettlingAfterDrag) {
      const delta = Math.abs(nextSec - this.settleTargetSec)
      if (delta > 0.55) {
        return
      }
      this.isSettlingAfterDrag = false
      this.clearSettleTimer()
    }
    const stabilizedSec = this.stabilizeMinuteBoundary(nextSec)
    this.updatePlayheadSec(stabilizedSec)
    this.updatePlayheadText(this.bridge.updatePlayhead(Math.floor(stabilizedSec * 1000)))
  }

  private handlePreviewEnded(): void {
    this.previewPlaying = false
    this.showPreviewCover = true
    this.updatePlayheadSec(this.state.totalDurationSec)
    this.updatePlayheadText(this.bridge.updatePlayhead(Math.floor(this.state.totalDurationSec * 1000)))
    this.showControlsTemporarily()
  }

  private getRangeStartPercent(): string {
    const total = Math.max(1, this.state.totalDurationSec)
    const percent = Math.max(0, Math.min(100, (this.state.selectionStartSec / total) * 100))
    return `${percent}%`
  }

  private getRangeEndPercent(): string {
    const total = Math.max(1, this.state.totalDurationSec)
    const percent = Math.max(0, Math.min(100, (this.state.selectionEndSec / total) * 100))
    return `${percent}%`
  }

  private getRangeWidthPercent(): string {
    const total = Math.max(1, this.state.totalDurationSec)
    const widthPercent = Math.max(0, Math.min(100, ((this.state.selectionEndSec - this.state.selectionStartSec) / total) * 100))
    return `${widthPercent}%`
  }

  private hasActiveSelectionRange(): boolean {
    return this.state.selectionStartSec > 0 || this.state.selectionEndSec < this.state.totalDurationSec
  }

  @State private timelineWidth: number = 0

  private handleTimelineTouch(localX: number, commitSeek: boolean, fromUser: boolean): void {
    if (this.timelineWidth <= 0) {
      return
    }
    const percent = Math.max(0, Math.min(1, localX / this.timelineWidth))
    const targetSec = percent * this.state.totalDurationSec
    this.syncGlobalPlayhead(targetSec, fromUser, commitSeek)
  }

  private beginTimelineDrag(localX: number): void {
    this.isTimelineDragging = true
    this.isSettlingAfterDrag = false
    this.clearSettleTimer()
    this.handleTimelineTouch(localX, false, false)
    this.dragPreviewSec = this.state.playheadSec
  }

  private updateTimelineDrag(localX: number): void {
    this.handleTimelineTouch(localX, false, false)
    this.dragPreviewSec = this.state.playheadSec
  }

  private endTimelineDrag(localX?: number): void {
    if (localX !== undefined) {
      this.handleTimelineTouch(localX, false, false)
    }
    const finalSec = this.state.playheadSec
    this.settleTargetSec = finalSec
    this.isSettlingAfterDrag = true
    this.clearSettleTimer()
    this.settleTimer = setTimeout(() => {
      this.isSettlingAfterDrag = false
      this.settleTimer = -1
    }, this.settleWindowMs)
    this.isTimelineDragging = false
    this.syncGlobalPlayhead(finalSec, true, true)
  }

  private updateExportStatus(statusText: string): void {
    this.bridge.setExportStatusText(statusText)
    const nextState = this.state
    nextState.exportStatusText = statusText
    this.state = nextState
  }

  private buildExportSnapshot(): ExportSnapshot | undefined {
    const snapshot = this.bridge.getTripSnapshotClone(this.state.tripId)
    if (!snapshot) {
      return undefined
    }
    let draft = createEditorStateFromSnapshot(
      snapshot,
      this.exportSessionSeed,
      this.state.activeTemplateId,
      this.state.speedLabel,
      this.state.muted,
      this.state.watermarkEnabled,
      this.state.hideSpeed,
      this.state.hideGps,
      this.state.hideVin,
      this.state.drawerExpanded,
      this.state.exportStatusText
    )
    const startMs = Math.floor(this.state.selectionStartSec * 1000)
    const endMs = Math.floor(this.state.selectionEndSec * 1000)
    const playheadMs = Math.floor(this.state.playheadSec * 1000)
    draft.playback.rangeStartMs = startMs
    draft.playback.rangeEndMs = endMs
    draft.playback.playheadMs = Math.max(startMs, Math.min(playheadMs, endMs))
    return deepCloneExportSnapshot(draft)
  }

  private async startNativeExportTask(): Promise<void> {
    if (this.exportLoadingVisible) {
      return
    }
    const exportSnapshot = this.buildExportSnapshot()
    if (!exportSnapshot) {
      this.updateExportStatus('导出失败：缺少行程数据')
      return
    }
    const host = this.getUIContext().getHostContext()
    if (!host) {
      this.updateExportStatus('导出失败：缺少页面上下文')
      return
    }
    const context = host as common.UIAbilityContext
    this.exportLoadingVisible = true
    this.exportLoadingText = '导出处理中...'
    this.updateExportStatus('导出处理中...')
    try {
      const outputPath = await startNativeExport(exportSnapshot, context, (event) => {
        this.updateExportStatus(event.status)
        this.exportLoadingText = event.status
        debugLog('导出', `导出事件 job=${event.jobId} status=${event.status} progress=${event.progress}`)
      })
      this.updateExportStatus(`导出完成：${outputPath}`)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      this.updateExportStatus(`导出失败：${message}`)
    } finally {
      this.exportLoadingVisible = false
    }
  }

  private togglePrivacy(type: string, enabled: boolean): void {
    debugLog('剪辑页', `切换隐私开关，类型=${type}，值=${enabled}`)
    this.applyState(this.bridge.updatePrivacy(type, enabled))
    this.showControlsTemporarily()
  }

  private switchCamera(camera: string): void {
    this.applyState(this.bridge.switchCamera(camera))
    this.tripSnapshot = this.bridge.getTripSnapshotClone(this.state.tripId) ?? new TripSnapshot()
    this.previewRenderVersion += 1
    this.seekToken += 1
    this.showPreviewCover = this.state.previewUri.length > 0
    debugLog('剪辑页', `切换播放器视角=${camera}，片段=${this.state.currentClipIndex}/${this.state.currentClipTotal}`)
    this.showControlsTemporarily()
  }

  private updatePlayhead(second: number): void {
    this.syncGlobalPlayhead(second, true)
  }

  private updateRangeStart(value: number): void {
    const nextStart = Math.min(Math.floor(value), this.state.selectionEndSec)
    this.applyState(this.bridge.updateSelectionRange(nextStart, this.state.selectionEndSec))
    if (this.state.playheadSec < this.state.selectionStartSec) {
      this.updatePlayhead(this.state.selectionStartSec)
    }
    this.markUnsaved()
    this.showControlsTemporarily()
  }

  private updateRangeEnd(value: number): void {
    const nextEnd = Math.max(Math.floor(value), this.state.selectionStartSec)
    this.applyState(this.bridge.updateSelectionRange(this.state.selectionStartSec, nextEnd))
    if (this.state.playheadSec > this.state.selectionEndSec) {
      this.updatePlayhead(this.state.selectionEndSec)
    }
    this.markUnsaved()
    this.showControlsTemporarily()
  }

  private selectTemplate(card: TemplateCardModel): void {
    if (this.isSwitchingTemplate) {
      return
    }
    this.isSwitchingTemplate = true
    const wasPlaying = this.previewPlaying
    const targetSec = this.state.playheadSec
    this.pauseAllPreview()
    this.applyState(this.bridge.selectTemplate(card.id))
    this.applyState(this.bridge.seekGlobalPlayhead(Math.floor(targetSec)))
    this.updatePlayheadSec(this.state.playheadSec)
    this.updatePlayheadText(this.bridge.updatePlayhead(Math.floor(this.state.playheadSec * 1000)))
    this.tripSnapshot = this.bridge.getTripSnapshotClone(this.state.tripId) ?? new TripSnapshot()

    this.previewRenderVersion += 1
    this.showPreviewCover = !wasPlaying
    this.seekToken += 1
    if (wasPlaying) {
      this.startAllPreview()
    }
    setTimeout(() => {
      this.isSwitchingTemplate = false
    }, 240)
    
    debugLog('剪辑页', `切换模板=${card.id}`)
    this.markUnsaved()
    this.showControlsTemporarily()
  }

  private toggleDrawer(): void {
    this.applyState(this.bridge.toggleTemplateDrawer(!this.state.drawerExpanded))
  }

  private cycleSpeed(): void {
    this.applyState(this.bridge.cycleSpeed())
    this.seekToken += 1
    debugLog('剪辑诊断', `切换整体倍速=${this.getPlaybackRate()}X`)
    this.markUnsaved()
    this.showControlsTemporarily()
  }

  private toggleMuted(): void {
    this.applyState(this.bridge.toggleMuted())
    this.seekToken += 1
    this.showControlsTemporarily()
  }

  private toggleWatermark(): void {
    this.applyState(this.bridge.toggleWatermark())
    this.showControlsTemporarily()
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column({ space: 0 }) {
        Row() {
          Button('← 返回')
            .type(ButtonType.Normal)
            .fontSize(16)
            .fontColor('#FFFFFF')
            .backgroundColor('#00000000')
            .onClick(() => this.handleBack())
          Text(this.state.timeRange.length > 0 ? this.state.timeRange : this.state.tripTitle)
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
          Button('导出剪辑')
            .type(ButtonType.Capsule)
            .fontSize(14)
            .fontColor('#FFFFFF')
            .backgroundColor('#FF7A00')
            .onClick(() => this.startNativeExportTask())
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 12, bottom: 12 })

        Scroll() {
          Column({ space: 16 }) {
            Column({ space: 12 }) {
              Text('剪辑模板（点击查看比例）')
                .fontSize(14)
                .fontColor('#999999')
                .width('100%')
              Scroll() {
                Row({ space: 12 }) {
                  ForEach(this.state.templateCards, (card: TemplateCardModel) => {
                    Column({ space: 4 }) {
                      Text(this.getTemplateIcon(card))
                        .fontSize(22)
                      Text(this.getTemplateUiName(card))
                        .fontSize(12)
                        .fontColor('#FFFFFF')
                      Text(this.getTemplateResolution(card))
                        .fontSize(10)
                        .fontColor(card.id === this.state.activeTemplateId ? '#FFFFFF' : '#999999')
                    }
                    .width(100)
                    .height(84)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .backgroundColor(card.id === this.state.activeTemplateId ? '#FF7A00' : '#333333')
                    .borderRadius(8)
                    .border({ width: 2, color: card.id === this.state.activeTemplateId ? '#FF7A00' : '#00000000' })
                    .opacity(this.isTemplateDisabled(card) ? 0.5 : 1)
                    .onClick(() => this.selectTemplateForUi(card))
                  }, (card: TemplateCardModel) => card.id)
                }
                .padding({ bottom: 4 })
              }
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Off)
            }
            .width('100%')
            .padding(16)
            .backgroundColor('#282828')
            .borderRadius(12)

            Column({ space: 0 }) {
              Text('播放剪辑器')
                .fontSize(14)
                .fontColor('#999999')
                .width('100%')
                .padding({ left: 16, right: 16, top: 12, bottom: 8 })
              Stack({ alignContent: Alignment.Center }) {
                if (this.hasPreviewSource()) {
                  EditorPreviewArea({
                    editorState: this.state,
                    tripSnapshot: this.tripSnapshot,
                    playing: this.previewPlaying,
                    seekToken: this.seekToken,
                    playheadMs: Math.floor(this.state.playheadSec * 1000),
                    muted: this.state.muted,
                    speedLabel: this.state.speedLabel,
                    onPlayheadChanged: (playheadMs: number) => this.handlePreviewPlayheadChanged(playheadMs),
                    onPlaybackEnded: () => this.handlePreviewEnded()
                  })
                    .width('100%')
                    .height('100%')
                } else {
                  Text('预览区')
                    .fontSize(14)
                    .fontColor('#FFFFFF')
                }
                if (this.showPlayerControls && this.hasPreviewSource()) {
                  Text(this.previewPlaying ? '⏸' : '▶')
                    .fontSize(24)
                    .fontColor('#FFFFFF')
                    .textAlign(TextAlign.Center)
                    .width(56)
                    .height(56)
                    .onClick(() => this.togglePreviewPlay())
                  Text(this.state.speedLabel.replace('X', 'x'))
                    .fontSize(12)
                    .fontColor('#FFFFFF')
                    .backgroundColor('#B3000000')
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                    .borderRadius(4)
                    .position({ x: '86%', y: '4%' })
                  if (this.state.muted) {
                    Text('🔇 全局静音')
                      .fontSize(12)
                      .fontColor('#FFFFFF')
                      .backgroundColor('#B3FF0000')
                      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                      .borderRadius(4)
                      .position({ x: '2%', y: '4%' })
                  }
                }
              }
              .width('100%')
              .aspectRatio(this.getPreviewAspectRatio())
              .backgroundColor('#000000')
              .onClick(() => {
                if (this.showPreviewCover && this.hasPreviewSource()) {
                  this.startAllPreview()
                  this.showPreviewCover = false
                }
                this.showControlsTemporarily()
              })

              Row() {
                Stack({ alignContent: Alignment.BottomStart }) {
                  Column()
                    .width('100%')
                    .height(56)
                    .backgroundColor('#121212')
                  if (this.hasActiveSelectionRange()) {
                    Column()
                      .height(56)
                      .backgroundColor('#33FF7A00')
                      .width(this.getRangeWidthPercent())
                      .position({ x: this.getRangeStartPercent(), y: '0%' })
                  }
                  Column()
                    .width(2)
                    .height(56)
                    .backgroundColor('#0A59F7')
                    .position({ x: this.getPlayheadPercent(), y: '0%' })
                  Text(this.formatTimelineTick(Math.floor(this.state.playheadSec)))
                    .fontSize(10)
                    .fontColor('#FFFFFF')
                    .backgroundColor('#0A59F7')
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .borderRadius(4)
                    .position({ x: this.getPlayheadPercent(), y: '-30%' })
                  ForEach(this.clipMarks, (mark: number, index: number) => {
                    Column()
                      .width(2)
                      .height(56)
                      .backgroundColor('#FF7A00')
                      .position({ x: this.markPercent(mark), y: '0%' })
                    Text('▼')
                      .fontSize(10)
                      .fontColor('#FF7A00')
                      .position({ x: this.markPercent(mark), y: '2%' })
                  }, (mark: number, index: number) => `${mark}-${index}`)
                  Row() {
                    ForEach(this.getTimelineTicks(), (tick: number) => {
                      Text(this.formatTimelineTick(tick))
                        .fontSize(10)
                        .fontColor('#666666')
                    }, (tick: number) => `${tick}`)
                  }
                  .width('100%')
                  .justifyContent(FlexAlign.SpaceBetween)
                  .padding({ left: 8, right: 8, top: 58 })
                }
                .layoutWeight(1)
                .height(80)
                .backgroundColor('#121212')
                .onAreaChange((oldValue: Area, newValue: Area) => {
                  this.timelineWidth = Number(newValue.width)
                })
                .gesture(
                  GestureGroup(GestureMode.Exclusive,
                    PanGesture({ direction: PanDirection.Horizontal })
                      .onActionStart((event: GestureEvent) => {
                        if (event.fingerList && event.fingerList.length > 0) {
                          this.beginTimelineDrag(event.fingerList[0].localX)
                        }
                      })
                      .onActionUpdate((event: GestureEvent) => {
                        if (event.fingerList && event.fingerList.length > 0) {
                          this.updateTimelineDrag(event.fingerList[0].localX)
                        }
                      })
                      .onActionEnd((event: GestureEvent) => {
                        if (event.fingerList && event.fingerList.length > 0) {
                          this.endTimelineDrag(event.fingerList[0].localX)
                        } else {
                          this.endTimelineDrag()
                        }
                      }),
                    TapGesture()
                      .onAction((event: GestureEvent) => {
                        if (event.fingerList && event.fingerList.length > 0) {
                          this.handleTimelineTouch(event.fingerList[0].localX, true, true)
                        }
                      })
                  )
                )
                Column({ space: 4 }) {
                  Text('+')
                    .fontSize(20)
                    .fontColor('#FFFFFF')
                    .backgroundColor('#333333')
                    .width(32)
                    .height(32)
                    .textAlign(TextAlign.Center)
                    .borderRadius(4)
                    .onClick(() => this.addClipMark())
                  Text('✕')
                    .fontSize(16)
                    .fontColor('#FF4444')
                    .backgroundColor('#333333')
                    .width(32)
                    .height(32)
                    .textAlign(TextAlign.Center)
                    .borderRadius(4)
                    .onClick(() => this.undoClipMark())
                }
                .width(44)
                .height(80)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor('#1A1A1A')
              }
              .width('100%')

              Text(this.getSegmentInfoText())
                .fontSize(12)
                .fontColor('#999999')
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 8, bottom: 8 })
                .backgroundColor('#1A1A1A')
            }
            .width('100%')
            .backgroundColor('#222222')
            .borderRadius(12)
            .border({ width: 1, color: '#333333' })

            Column({ space: 12 }) {
              Text('功能设置')
                .fontSize(14)
                .fontColor('#999999')
                .width('100%')
              if (this.templateSupportsMosaic(this.state.activeTemplateId)) {
                Row() {
                  Text('前视角固定打码')
                    .fontSize(14)
                    .fontColor('#FFFFFF')
                  Blank()
                  Toggle({ type: ToggleType.Switch, isOn: this.mosaicEnabledUi })
                    .onChange((value: boolean) => this.toggleMosaicByUi(value))
                }
                .width('100%')
              }
              Row() {
                Text('倍速')
                  .fontSize(14)
                  .fontColor('#FFFFFF')
                Blank()
                Button(this.state.speedLabel.replace('X', 'x'))
                  .type(ButtonType.Capsule)
                  .fontSize(14)
                  .fontColor('#FFFFFF')
                  .backgroundColor('#333333')
                  .onClick(() => this.cycleSpeed())
              }
              .width('100%')
            }
            .width('100%')
            .padding(16)
            .backgroundColor('#282828')
            .borderRadius(12)
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 20 })
        }
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#181818')

      if (this.toastVisible) {
        Text(this.toastText)
          .fontSize(14)
          .fontColor('#FFFFFF')
          .backgroundColor('#E6000000')
          .padding({ left: 24, right: 24, top: 12, bottom: 12 })
          .borderRadius(8)
          .position({ x: '24%', y: '86%' })
      }

      if (this.backConfirmVisible) {
        Column({ space: 0 }) {
          Column({ space: 12 }) {
            Text('确认放弃修改？')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
            Text('返回将丢失未保存的修改')
              .fontSize(14)
              .fontColor('#999999')
            Row({ space: 12 }) {
              Button('继续编辑')
                .layoutWeight(1)
                .type(ButtonType.Capsule)
                .fontSize(14)
                .fontColor('#FFFFFF')
                .backgroundColor('#333333')
                .onClick(() => this.cancelBack())
              Button('放弃')
                .layoutWeight(1)
                .type(ButtonType.Capsule)
                .fontSize(14)
                .fontColor('#FFFFFF')
                .backgroundColor('#0A59F7')
                .onClick(() => this.confirmBack())
            }
            .width('100%')
          }
          .width('84%')
          .padding(24)
          .backgroundColor('#282828')
          .borderRadius(16)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#B3000000')
      }

      if (this.exportLoadingVisible) {
        Column({ space: 10 }) {
          LoadingProgress()
            .color('#F97316')
            .width(54)
            .height(54)
          Text(this.exportLoadingText)
            .fontSize(13)
            .fontColor('#F8FAFC')
        }
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .width('100%')
        .height('100%')
        .backgroundColor('#88000000')
      }
    }
    .width('100%')
    .height('100%')
  }
}
