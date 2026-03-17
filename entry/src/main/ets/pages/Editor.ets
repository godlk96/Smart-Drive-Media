import { SeamlessVideoPlayer, SeamlessVideoController } from '../components/SeamlessVideoPlayer'
import { SeamlessPreviewController, SeamlessPreviewView } from '../components/SeamlessPreviewView'
import { sharedCoreBridge } from '../bridge/CoreBridge'
import { EditorStateModel, PreviewSlotModel, TemplateCardModel, TimelineMarkerModel, TimelineTrackModel } from '../model/AppState'
import { createEditorStateFromSnapshot, deepCloneExportSnapshot, ExportSnapshot, resolveTemplateDefinition } from '../model/Models'
import { startNativeExport } from '../NativeExportManager'
import { debugLog } from '../utils/Logger'
import common from '@ohos.app.ability.common'

@Entry
@Component
struct Editor {
  private bridge = sharedCoreBridge
  private exportSessionSeed: string = ''
  private primaryControllerA: SeamlessPreviewController = new SeamlessPreviewController()
  private secondaryControllerA: SeamlessVideoController = new SeamlessVideoController()
  private secondaryControllerB: SeamlessVideoController = new SeamlessVideoController()
  private secondaryControllerC: SeamlessVideoController = new SeamlessVideoController()
  private controlsTimer: number = -1
  private speedEmulationTimer: number = -1
  private speedEmulationFractionSec: number = 0
  private lastPlayheadTickAt: number = 0
  private manualSpeedMode: boolean = false
  private lastSecondarySeekMs: number = 0
  private lastLoggedSecond: number = -1
  @State private showPlayerControls: boolean = true
  @State private showPreviewCover: boolean = true
  @State private previewPlaying: boolean = true
  @State private primarySrcA: string = ''
  @State private primarySrcB: string = ''
  @State private primaryMutedA: boolean = true
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
    const nextState = this.state
    nextState.playheadSec = clamped
    this.state = nextState
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
    this.syncPrimarySourcesByState()
    this.syncPrimaryMuteByState()
    this.showPreviewCover = this.state.previewUri.length > 0
    this.previewPlaying = !this.showPreviewCover
    this.showPlayerControls = true
    this.applyPlaybackRate()
    this.scheduleHideControls()
    this.hasUnsavedChanges = false
    this.backConfirmVisible = false
    this.clipMarks = []
    this.mosaicEnabledUi = true
    this.lastPlayheadTickAt = Date.now()
    const trackSummary = this.state.timeline.map((item: TimelineTrackModel) => `${item.cameraPosition}:${item.segmentCount}`).join(',')
    debugLog('剪辑诊断', `初始化完成，时长=${this.state.totalDurationSec}s，轨道数=${this.state.timeline.length}，轨道明细=${trackSummary}，预览URI长度=${this.state.previewUri.length}，预览视角=${this.state.previewCamera}`)
  }

  aboutToDisappear(): void {
    this.clearHideControlsTimer()
    this.clearSpeedEmulationTimer()
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

  private clearSpeedEmulationTimer(): void {
    if (this.speedEmulationTimer >= 0) {
      clearInterval(this.speedEmulationTimer)
      this.speedEmulationTimer = -1
    }
    this.speedEmulationFractionSec = 0
  }

  private scheduleHideControls(): void {
    this.clearHideControlsTimer()
    this.controlsTimer = setTimeout(() => {
      this.showPlayerControls = false
      debugLog('剪辑诊断', '播放器控件自动隐藏')
    }, 3000)
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

  private getPrimaryPreviewSlot(): PreviewSlotModel | undefined {
    return this.state.previewSlots[0]
  }

  private isPrimarySlotEventValid(slot: PreviewSlotModel): boolean {
    const primary = this.getPrimaryPreviewSlot()
    if (!primary) {
      return false
    }
    const valid = primary.id === slot.id && primary.uri === slot.uri
    if (!valid) {
      debugLog('剪辑诊断', `忽略主画面过期回调，slot=${slot.id}/${slot.uri}，primary=${primary.id}/${primary.uri}`)
    }
    return valid
  }

  private isPrimaryPreviewSlot(slotId: string): boolean {
    const primary = this.getPrimaryPreviewSlot()
    return primary !== undefined && primary.id === slotId
  }

  private hasPreviewSource(): boolean {
    return this.state.previewSlots.some((slot: PreviewSlotModel) => slot.uri.length > 0)
  }

  private syncPrimarySourcesByState(): void {
    const primary = this.getPrimaryPreviewSlot()
    if (!primary || primary.uri.length === 0) {
      this.primarySrcA = ''
      this.primarySrcB = ''
      this.primaryControllerA.reloadWindow('', '', 0)
      return
    }
    this.primarySrcA = primary.uri
    const preloadUri = primary.nextUri ?? ''
    this.primarySrcB = preloadUri.length > 0 && preloadUri !== primary.uri ? preloadUri : ''
    this.primaryControllerA.reloadWindow(this.primarySrcA, this.primarySrcB, this.getLocalSecond(this.state.playheadSec))
  }

  private syncPrimaryMuteByState(): void {
    const primary = this.getPrimaryPreviewSlot()
    const allowAudio = primary ? this.getAudioSlotId() === primary.id : false
    const activeMuted = allowAudio ? this.state.muted : true
    this.primaryMutedA = activeMuted
    this.primaryControllerA.setMuted(activeMuted)
  }

  private handleSeamlessSwap(): void {
    if (!this.state.canPlayNext) {
      return
    }
    this.applyState(this.bridge.playNextClip())
    this.syncPrimarySourcesByState()
    this.syncPrimaryMuteByState()
    this.updatePlayheadSec(this.getCurrentClipStartSec())
    this.updatePlayheadText(this.bridge.updatePlayhead(Math.floor(this.state.playheadSec * 1000)))
    this.seekSecondaryControllers(0, true)
    this.showPreviewCover = false
    this.showControlsTemporarily()
  }

  private handleSeamlessEnded(): void {
    this.previewPlaying = false
    this.showPreviewCover = true
    this.clearSpeedEmulationTimer()
    this.updatePlayheadSec(this.state.totalDurationSec)
    this.updatePlayheadText(this.bridge.updatePlayhead(Math.floor(this.state.totalDurationSec * 1000)))
    this.pauseAllPreview()
    this.showControlsTemporarily()
  }

  private handleSeamlessError(message: string): void {
    debugLog('剪辑诊断', `无缝管理器错误：${message}`)
    this.showPreviewCover = true
  }

  private getSecondaryController(slotId: string): SeamlessVideoController {
    if (slotId === 'pip' || slotId === 'bottomLeft' || slotId === 'left') {
      return this.secondaryControllerA
    }
    if (slotId === 'bottomRight' || slotId === 'right') {
      return this.secondaryControllerB
    }
    if (slotId === 'center' || slotId === 'middle') {
      return this.secondaryControllerC
    }
    return this.secondaryControllerC
  }

  private getAudioSlotId(): string {
    const frontSlot = this.state.previewSlots.find((slot: PreviewSlotModel) => slot.camera === 'Front' && slot.uri.length > 0)
    if (frontSlot) {
      return frontSlot.id
    }
    const primary = this.getPrimaryPreviewSlot()
    if (primary && primary.uri.length > 0) {
      return primary.id
    }
    const fallback = this.state.previewSlots.find((slot: PreviewSlotModel) => slot.uri.length > 0)
    return fallback ? fallback.id : ''
  }

  private startAllPreview(): void {
    this.lastPlayheadTickAt = Date.now()
    this.syncPrimaryMuteByState()
    this.primaryControllerA.start()
    this.secondaryControllerA.start()
    this.secondaryControllerB.start()
    this.secondaryControllerC.start()
    this.previewPlaying = true
    this.ensureSpeedEmulation()
    debugLog('剪辑诊断', `触发统一播放，目标倍速=${this.getPlaybackRate()}X`)
  }

  private pauseAllPreview(): void {
    this.primaryControllerA.pause()
    this.secondaryControllerA.pause()
    this.secondaryControllerB.pause()
    this.secondaryControllerC.pause()
    this.previewPlaying = false
    this.manualSpeedMode = false
    this.clearSpeedEmulationTimer()
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

  private syncGlobalPlayhead(second: number, fromUser: boolean): void {
    const clamped = Math.max(0, Math.min(second, this.state.totalDurationSec))
    this.updatePlayheadSec(clamped)
    this.applyState(this.bridge.seekGlobalPlayhead(Math.floor(clamped)))
    this.syncPrimarySourcesByState()
    this.syncPrimaryMuteByState()
    this.updatePlayheadText(this.bridge.updatePlayhead(Math.floor(this.state.playheadSec * 1000)))
    const localSecond = this.getLocalSecond(this.state.playheadSec)
    
    // Optimize: only seek if difference is significant or forced
    const now = Date.now()
    if (fromUser || now - this.lastSecondarySeekMs > 1000) {
      this.seekAllControllers(localSecond, true)
    }
    
    if (fromUser && Math.floor(clamped) !== this.lastLoggedSecond) {
      this.lastLoggedSecond = Math.floor(clamped)
      debugLog('剪辑页', `拖动全局进度，秒=${Math.floor(clamped)}，片段=${this.state.currentClipIndex}/${this.state.currentClipTotal}，片内秒=${Math.floor(localSecond)}`)
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

  private ensureSpeedEmulation(): void {
    this.clearSpeedEmulationTimer()
    if (!this.previewPlaying) {
      return
    }
    this.lastPlayheadTickAt = Date.now()
    const rate = this.getPlaybackRate()
    if (rate <= 1) {
      this.manualSpeedMode = false
      this.speedEmulationTimer = setInterval(() => {
        if (!this.previewPlaying) {
          return
        }
        const now = Date.now()
        const elapsedSec = Math.max(0, (now - this.lastPlayheadTickAt) / 1000)
        this.lastPlayheadTickAt = now
        if (elapsedSec <= 0) {
          return
        }
        
        const nextSec = Math.min(this.state.totalDurationSec, this.state.playheadSec + elapsedSec)
        this.updatePlayheadSec(nextSec)
        this.updatePlayheadText(this.bridge.updatePlayhead(Math.floor(this.state.playheadSec * 1000)))
        if (nextSec >= this.state.totalDurationSec) {
          this.previewPlaying = false
          this.clearSpeedEmulationTimer()
        }
      }, 80)
      return
    }
    this.manualSpeedMode = true
    this.primaryControllerA.pause()
    this.secondaryControllerA.pause()
    this.secondaryControllerB.pause()
    this.secondaryControllerC.pause()
    this.lastSecondarySeekMs = 0
    this.speedEmulationTimer = setInterval(() => {
      if (!this.previewPlaying) {
        return
      }
      this.speedEmulationFractionSec += rate * 0.32
      const stepSec = this.speedEmulationFractionSec
      this.speedEmulationFractionSec = 0
      const nextSec = Math.min(this.state.totalDurationSec, this.state.playheadSec + stepSec)
      const currentClipEnd = this.getCurrentClipStartSec() + this.getClipSpanSec()
      if (nextSec >= currentClipEnd && this.state.canPlayNext) {
        this.syncGlobalPlayhead(nextSec, false)
      } else {
        this.updatePlayheadSec(nextSec)
        this.updatePlayheadText(this.bridge.updatePlayhead(Math.floor(this.state.playheadSec * 1000)))
        const localSecond = this.getLocalSecond(this.state.playheadSec)
        this.seekPrimaryController(localSecond)
        this.seekSecondaryControllers(localSecond, false)
      }
      if (nextSec >= this.state.totalDurationSec) {
        this.previewPlaying = false
        this.manualSpeedMode = false
        this.clearSpeedEmulationTimer()
      }
    }, 320)
    debugLog('倍速诊断', `启用预览倍速仿真，rate=${rate}`)
  }

  private applyPlaybackRate(): void {
    const rate = this.getPlaybackRate()
    this.primaryControllerA.setPlaybackSpeed(rate)
    this.secondaryControllerA.setPlaybackSpeed(rate)
    this.secondaryControllerB.setPlaybackSpeed(rate)
    this.secondaryControllerC.setPlaybackSpeed(rate)
  }

  private getClipSpanSec(): number {
    if (this.state.currentClipTotal <= 0) {
      return Math.max(1, this.state.totalDurationSec)
    }
    return Math.max(1, Math.floor(this.state.totalDurationSec / this.state.currentClipTotal))
  }

  private getCurrentClipStartSec(): number {
    if (this.state.currentClipIndex <= 0) {
      return 0
    }
    return (this.state.currentClipIndex - 1) * this.getClipSpanSec()
  }

  private getLocalSecond(globalSecond: number): number {
    const clipStart = this.getCurrentClipStartSec()
    return Math.max(0, globalSecond - clipStart)
  }

  private seekPrimaryController(localSecond: number): void {
    this.primaryControllerA.setCurrentTime(localSecond)
  }

  private seekSecondaryControllers(localSecond: number, force: boolean): void {
    const now = Date.now()
    if (!force && now - this.lastSecondarySeekMs < 1500) {
      return
    }
    this.lastSecondarySeekMs = now
    this.secondaryControllerA.setCurrentTime(localSecond)
    this.secondaryControllerB.setCurrentTime(localSecond)
    this.secondaryControllerC.setCurrentTime(localSecond)
  }

  private seekAllControllers(localSecond: number, force: boolean): void {
    this.seekPrimaryController(localSecond)
    this.seekSecondaryControllers(localSecond, force)
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

  private handleTimelineTouch(localX: number): void {
    if (this.timelineWidth <= 0) {
      return
    }
    const percent = Math.max(0, Math.min(1, localX / this.timelineWidth))
    const targetSec = percent * this.state.totalDurationSec
    this.updatePlayhead(targetSec)
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
    this.syncPrimarySourcesByState()
    this.syncPrimaryMuteByState()
    this.showPreviewCover = this.state.previewUri.length > 0
    debugLog('剪辑页', `切换播放器视角=${camera}，片段=${this.state.currentClipIndex}/${this.state.currentClipTotal}`)
    this.showControlsTemporarily()
  }

  private playPrevClip(): void {
    this.applyState(this.bridge.playPrevClip())
    this.syncPrimarySourcesByState()
    this.syncPrimaryMuteByState()
    this.updatePlayheadSec(this.getCurrentClipStartSec())
    this.updatePlayheadText(this.bridge.updatePlayhead(this.state.playheadSec * 1000))
    this.seekAllControllers(0, true)
    this.showPreviewCover = this.state.previewUri.length > 0
    debugLog('剪辑页', `切换上一片，当前=${this.state.currentClipIndex}/${this.state.currentClipTotal}`)
    this.showControlsTemporarily()
  }

  private playNextClip(): void {
    this.applyState(this.bridge.playNextClip())
    this.syncPrimarySourcesByState()
    this.syncPrimaryMuteByState()
    this.updatePlayheadSec(this.getCurrentClipStartSec())
    this.updatePlayheadText(this.bridge.updatePlayhead(this.state.playheadSec * 1000))
    this.seekAllControllers(0, true)
    this.showPreviewCover = this.state.previewUri.length > 0
    debugLog('剪辑页', `切换下一片，当前=${this.state.currentClipIndex}/${this.state.currentClipTotal}`)
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
    const wasPlaying = this.previewPlaying
    this.pauseAllPreview()
    this.applyState(this.bridge.selectTemplate(card.id))
    
    // Reset to 0
    this.updatePlayheadSec(0)
    this.updatePlayheadText(this.bridge.updatePlayhead(0))
    this.applyState(this.bridge.seekGlobalPlayhead(0))
    this.syncPrimarySourcesByState()
    this.syncPrimaryMuteByState()

    this.previewRenderVersion += 1
    this.showPreviewCover = true
    
    // We need to wait for players to be ready after template switch before seeking
    setTimeout(() => {
      this.seekAllControllers(0, true)
      if (!wasPlaying) {
        this.pauseAllPreview()
      } else {
        this.startAllPreview()
      }
    }, 150)
    
    debugLog('剪辑页', `切换模板=${card.id}`)
    this.markUnsaved()
    this.showControlsTemporarily()
  }

  private toggleDrawer(): void {
    this.applyState(this.bridge.toggleTemplateDrawer(!this.state.drawerExpanded))
  }

  private cycleSpeed(): void {
    this.applyState(this.bridge.cycleSpeed())
    this.applyPlaybackRate()
    if (this.previewPlaying) {
      if (this.getPlaybackRate() <= 1) {
        this.manualSpeedMode = false
        this.clearSpeedEmulationTimer()
        this.startAllPreview()
      } else {
        this.ensureSpeedEmulation()
      }
    }
    debugLog('剪辑诊断', `切换整体倍速=${this.getPlaybackRate()}X`)
    this.markUnsaved()
    this.showControlsTemporarily()
  }

  private toggleMuted(): void {
    this.applyState(this.bridge.toggleMuted())
    this.syncPrimaryMuteByState()
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
                  if (this.getPrimaryPreviewSlot() && (this.getPrimaryPreviewSlot()?.uri.length ?? 0) > 0) {
                    SeamlessPreviewView({
                      currentUri: this.primarySrcA,
                      nextUri: this.primarySrcB,
                      controller: this.primaryControllerA,
                      muted: this.primaryMutedA,
                      onSwapCallback: () => this.handleSeamlessSwap(),
                      onEndedCallback: () => this.handleSeamlessEnded(),
                      onErrorCallback: (message: string) => this.handleSeamlessError(message)
                    })
                      .width(this.toPercent(this.getPrimaryPreviewSlot()?.width ?? 0))
                      .height(this.toPercent(this.getPrimaryPreviewSlot()?.height ?? 0))
                      .position({
                        x: this.toPercent(this.getPrimaryPreviewSlot()?.x ?? 0),
                        y: this.toPercent(this.getPrimaryPreviewSlot()?.y ?? 0)
                      })
                      .opacity(1)
                  }
                  ForEach(this.state.previewSlots, (slot: PreviewSlotModel) => {
                    if (slot.uri.length === 0) {
                      Column()
                        .width(this.toPercent(slot.width))
                        .height(this.toPercent(slot.height))
                        .backgroundColor('#444444')
                        .border({ width: 1, color: '#333333' })
                        .position({ x: this.toPercent(slot.x), y: this.toPercent(slot.y) })
                    } else if (!this.isPrimaryPreviewSlot(slot.id)) {
                      SeamlessVideoPlayer({
                        src: slot.uri,
                        controller: this.getSecondaryController(slot.id),
                        muted: this.getAudioSlotId() === slot.id ? this.state.muted : true,
                        onPreparedCallback: () => {
                          this.applyPlaybackRate()
                          if (this.previewPlaying && !this.showPreviewCover) {
                            this.getSecondaryController(slot.id).start()
                          } else {
                            this.getSecondaryController(slot.id).pause()
                          }
                        }
                      })
                        .width(this.toPercent(slot.width))
                        .height(this.toPercent(slot.height))
                        .position({ x: this.toPercent(slot.x), y: this.toPercent(slot.y) })
                    }
                    Text(this.cameraZhName(slot.camera))
                      .fontSize(10)
                      .fontColor('#999999')
                      .position({ x: this.toPercent(slot.x + 0.01), y: this.toPercent(slot.y + 0.01) })
                    if (this.mosaicEnabledUi && this.templateSupportsMosaic(this.state.activeTemplateId) && slot.camera === 'Front') {
                      Column()
                        .width(this.toPercent(slot.width * 0.3))
                        .height(this.toPercent(slot.height * 0.15))
                        .backgroundColor('#000000B3')
                        .borderRadius(4)
                        .position({
                          x: this.toPercent(slot.x + slot.width * 0.35),
                          y: this.toPercent(slot.y + slot.height * 0.65)
                        })
                    }
                  }, (slot: PreviewSlotModel) => `${this.previewRenderVersion}-${this.state.activeTemplateId}-${slot.id}`)
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
                          this.handleTimelineTouch(event.fingerList[0].localX)
                        }
                      })
                      .onActionUpdate((event: GestureEvent) => {
                        if (event.fingerList && event.fingerList.length > 0) {
                          this.handleTimelineTouch(event.fingerList[0].localX)
                        }
                      }),
                    TapGesture()
                      .onAction((event: GestureEvent) => {
                        if (event.fingerList && event.fingerList.length > 0) {
                          this.handleTimelineTouch(event.fingerList[0].localX)
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
