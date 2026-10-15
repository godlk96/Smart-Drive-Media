import { EditorPreviewArea } from '../components/EditorPreviewArea'
import { AppIcon, AppIconName } from '../components/AppIcon'
import { SegmentParamRow } from '../components/SegmentParamRow'
import { PreviewOverlay, SegmentTrack } from '../components/SegmentTrack'
import { TemplateStrip } from '../components/TemplateStrip'
import { sharedCoreBridge } from '../bridge/CoreBridge'
import { EditorStateModel, PreviewSeekRequest, TemplateCardModel, TimelineTrackModel } from '../model/AppState'
import { Segment, MAX_SEGMENTS, createFullSegment, segmentIndexAtSec, segmentOrdinal } from '../model/SegmentModel'
import { TripSnapshot } from '../model/TripModels'
import { startNativeExport } from '../NativeExportManager'
import { debugLog } from '../utils/Logger'
import common from '@ohos.app.ability.common'
import { EditorViewModel } from '../viewmodel/EditorViewModel'

/**
 * 画面区恒为 16:9。
 *
 * 以前这里跟模板走 `getPreviewAspectRatio()`，五个模板的自然高度是 366/275/92/92/183px
 * （内容宽 326px 时），最大差 4 倍 —— 每切一次模板，下面的参数行和片段轨道就上下弹一次。
 * 现在画面区定死 16:9，模板组合由 EditorPreviewArea 自己按 Contain 缩放居中、
 * 四周留 stage_bg 黑边（它内部本来就有这层等比约束），切模板时下方一动不动。
 */
const STAGE_ASPECT_RATIO: number = 16 / 9

@Entry
@Component
struct Editor {
  private viewModel: EditorViewModel = new EditorViewModel()
  private bridge = sharedCoreBridge
  private exportSessionSeed: string = ''
  private controlsTimer: number = -1
  private lastLoggedSecond: number = -1
  @State private showPlayerControls: boolean = true
  @State private previewPlaying: boolean = false
  private lastStablePlayheadSec: number = 0
  /**
   * 显式跳转请求。**只有**用户主动跳转才递增 token（见 requestPreviewSeek）。
   * 播放推进只改 playheadSec（展示用），不会发请求——位置由预览区的 TimelineClock 持有。
   */
  @State private previewSeek: PreviewSeekRequest = new PreviewSeekRequest()
  @State private tripSnapshot: TripSnapshot = new TripSnapshot()
  @State private exportLoadingVisible: boolean = false
  @State private exportLoadingText: string = '导出处理中...'
  @State private exportProgress: number = 0
  @State private hasUnsavedChanges: boolean = false
  @State private backConfirmVisible: boolean = false
  @State private toastText: string = ''
  @State private toastVisible: boolean = false
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
    boundaryMarkers: [],
    templateCards: [],
    previewSlots: [],
    activeTemplateId: 'T2',
    drawerExpanded: true,
    segments: createFullSegment(60),
    selectedSegmentId: 0,
    watermarkEnabled: true,
    exportStatusText: '待导出',
    isRawFull: true
  }

  private applyState(nextState: EditorStateModel): void {
    this.state = nextState
  }

  private updatePlayheadText(text: string): void {
    const next = this.state
    next.playheadText = text
    this.state = next
  }

  private updatePlayheadSec(sec: number): void {
    const clamped = Math.max(0, Math.min(sec, this.state.totalDurationSec))
    this.lastStablePlayheadSec = clamped
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
    const hydrateResult = this.viewModel.hydrate(tripId)
    this.exportSessionSeed = hydrateResult.exportSessionSeed
    this.applyState(hydrateResult.state)
    this.tripSnapshot = hydrateResult.tripSnapshot
    this.previewPlaying = false
    this.showPlayerControls = true
    // 把"宿主认为的播放头"作为一次显式跳转交给预览区。预览区挂载时会消费这个待处理请求，
    // 否则新挂载的 TimelineClock 从 0 开始，而界面显示的是恢复出来的位置（画面与播放头不一致）。
    this.requestPreviewSeek(this.state.playheadSec * 1000)
    this.scheduleHideControls()
    this.hasUnsavedChanges = false
    this.backConfirmVisible = false
    const trackSummary = this.state.timeline.map((item: TimelineTrackModel) => `${item.cameraPosition}:${item.segmentCount}`).join(',')
    debugLog('剪辑诊断', `初始化完成，时长=${this.state.totalDurationSec}s，轨道数=${this.state.timeline.length}，轨道明细=${trackSummary}，预览URI长度=${this.state.previewUri.length}，预览视角=${this.state.previewCamera}`)
  }

  aboutToDisappear(): void {
    this.clearHideControlsTimer()
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

  private showControlsTemporarily(): void {
    this.showPlayerControls = true
    this.scheduleHideControls()
  }

  private hasPreviewSource(): boolean {
    return this.state.previewSlots.some((slot) => slot.uri.length > 0)
  }

  private hasImageCover(): boolean {
    const uri = this.tripSnapshot.previewFrameUri
    if (uri.length === 0) {
      return false
    }
    const lower = uri.toLowerCase()
    return lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png') || lower.endsWith('.webp')
  }

  private formatCoverUri(uri: string): string {
    if (uri.startsWith('file://') || uri.startsWith('http://') || uri.startsWith('https://')) {
      return uri
    }
    return `file://${uri}`
  }

  private startAllPreview(): void {
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
      debugLog('剪辑诊断', '点击播放预览，已同步播放全部画面')
    }
    this.showControlsTemporarily()
  }

  private getPlaybackRate(): number {
    return this.viewModel.getPlaybackRate(this.previewSpeedLabel())
  }

  private syncGlobalPlayhead(second: number, fromUser: boolean, commitSeek: boolean = true): void {
    const clamped = Math.max(0, Math.min(second, this.state.totalDurationSec))
    this.updatePlayheadSec(clamped)
    if (commitSeek) {
      this.applyState(this.viewModel.seekGlobalPlayhead(clamped))
      this.requestPreviewSeek(clamped * 1000)
    }
    this.updatePlayheadText(this.viewModel.updatePlayheadText(this.state.playheadSec))
    if (fromUser && commitSeek && Math.floor(clamped) !== this.lastLoggedSecond) {
      this.lastLoggedSecond = Math.floor(clamped)
      debugLog('剪辑页', `拖动全局进度，秒=${Math.floor(clamped)}，片段=${this.state.currentClipIndex}/${this.state.currentClipTotal}`)
    }
    // fromUser 表示「用户直接操作了播放头」，那是导航而不是编辑：拖动进度条圆钮、
    // 播完再点播放回到 0，都不该点亮「未保存」，否则返回时会平白弹「确认放弃修改？」。
    // 真正的编辑一律走 markUnsaved()。
    if (fromUser) {
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
    return this.viewModel.getTemplateUiName(card)
  }

  private getTemplateResolution(card: TemplateCardModel): string {
    return this.viewModel.getTemplateResolution(card)
  }

  private templateSupportsAudio(templateId: string): boolean {
    return true
  }

  private normalizeCameraName(camera: string): string {
    return this.viewModel.normalizeCameraName(camera)
  }

  private cameraZhName(camera: string): string {
    return this.viewModel.cameraZhName(camera)
  }

  private isTemplateDisabled(card: TemplateCardModel): boolean {
    return this.viewModel.isTemplateDisabled(card, this.state.timeline)
  }

  private getTemplateMissingViews(card: TemplateCardModel): string {
    return this.viewModel.getTemplateMissingViews(card, this.state.timeline)
  }

  private selectTemplateForUi(card: TemplateCardModel): void {
    if (card.id === this.state.activeTemplateId) {
      this.showControlsTemporarily()
      return
    }
    if (this.isTemplateDisabled(card)) {
      const missing = this.getTemplateMissingViews(card)
      this.showToast(`缺少${missing}视角，无法使用该模板`)
      return
    }
    this.selectTemplate(card)
  }

  /**
   * 剪刀：在播放头处落刀。规则见 spec §3.2/§3.4。
   */
  private splitAtPlayhead(): void {
    const wasRawFull = this.state.isRawFull
    if (wasRawFull) {
      if (!this.viewModel.canSplitAtPlayhead()) {
        this.showToast('距离片尾不足10秒，无法截取')
        return
      }
    } else {
      if (this.state.segments.length >= MAX_SEGMENTS) {
        this.showToast('最多只能添加3个剪辑点')
        return
      }
      if (!this.viewModel.canSplitAtPlayhead()) {
        this.showToast('片段需至少20秒可切分，或空档需至少10秒')
        return
      }
    }
    this.pauseAllPreview()
    this.applyState(this.viewModel.splitAtPlayhead())
    this.markUnsaved()
    this.showToast(wasRawFull ? '已生成高光片段' : '已添加剪辑点')
    this.showControlsTemporarily()
  }

  /** 点画面：把控制条唤回来（spec §5.2）。 */
  private handleStageTap(): void {
    this.showControlsTemporarily()
  }

  /**
   * 点片段块：选中该段，并把播放头与画面搬到该段起点（spec §5.4、验收 §4）。
   *
   * 91730a0 之前这里会先 `syncGlobalPlayhead(segment.startSec)` 再选中；那次提交把它
   * 删成了「只选中」，于是点块只剩一圈琥珀描边，画面和进度条圆钮纹丝不动 ——
   * 正是「点了这里应该影响另外一个地方，但实际没有影响」。
   * 顺序上 seek 先做、显式选中后做：`seekGlobalPlayhead` 会按播放头重算选中
   * （边界归前一段），必须让用户的显式选择最后落笔。
   * `fromUser=false`：换选中/搬播放头是导航而非编辑，不该点亮「未保存」；
   * 但控件条要按交互唤回，所以这里单独 showControlsTemporarily()。
   */
  private handleSelectSegment(id: number): void {
    const target = this.state.segments.find((item: Segment) => item.id === id)
    if (target !== undefined) {
      this.syncGlobalPlayhead(target.startSec, false)
    }
    this.applyState(this.viewModel.selectSegment(id))
    this.showControlsTemporarily()
  }

  /**
   * 点轨道空档：播放头落进空档，参数行切到「空白区间」态（spec §3.1）。
   *
   * 空档起点必然等于前一段的终点，而 `segmentIndexAtSec` 把边界归前一段，
   * 所以这里不能靠 `seekGlobalPlayhead` 反推选中，必须在 seek 之后显式选中 -1，
   * 否则点空档会选中前一段、剪刀变成「切分」而不是「插入」。
   */
  private handleSelectGap(startSec: number): void {
    // 播放中必须先停下：空档是编辑态（在这里插入新片段），本就该在暂停下停留；
    // 否则播放头继续往前跑，下一 tick 就把选中态重算回「片段 N」——
    // 同一个点击暂停时有效、播放时看起来毫无反应。
    this.pauseAllPreview()
    this.syncGlobalPlayhead(startSec, false)
    this.applyState(this.viewModel.selectSegment(-1))
    this.showControlsTemporarily()
  }

  /** 拖圆钮：先跳转，再让圆钮落点所在的那一段选中（空档则为 -1）。 */
  private handleScrubTo(sec: number): void {
    // 进度条现在跟着控件条一起自动隐藏，所以拖动期间必须不断把隐藏倒计时往后推：
    // 否则 3 秒一到 showPlayerControls 翻假，进度条连同正被按住的这个手势一起被卸载，
    // 跳转停在手指划过的位置、松手也补不回来。手还按着、控件先没了，是新的自相矛盾。
    this.showControlsTemporarily()
    this.syncGlobalPlayhead(sec, true)
    if (!this.state.isRawFull) {
      const index = segmentIndexAtSec(this.state.segments, sec)
      const targetId = index >= 0 ? this.state.segments[index].id : -1
      this.applyState(this.viewModel.selectSegment(targetId))
    }
  }

  /**
   * 拖手柄过程中的节流寻道（spec §3.6.1）：画面与进度条圆钮跟着手势走，做到所见即所得。
   *
   * 这里**只**搬画面与圆钮，既不动选中态、也不动片段数据：
   * - 选中态不能按播放头重算（`seekGlobalPlayhead` 会做这件事）：左手柄被拖过播放头时，
   *   播放头就落到这一段之外，选中态一改手柄会在拖动中途消失 —— 991ee01 修的正是这个抖动环；
   * - 片段边界留到松手时一次性结算（见 handleAdjustBoundary），拖动期每帧改边界会让轨道块
   *   宽度与相邻段约束跟着重算。
   */
  private handleAdjustPreview(sec: number): void {
    this.updatePlayheadSec(sec)
    this.requestPreviewSeek(this.state.playheadSec * 1000)
  }

  private handleAdjustBoundary(id: number, edge: 'start' | 'end', sec: number): void {
    this.applyState(this.viewModel.adjustSegmentBoundary(id, edge, sec))
    // spec §3.6.1：拖动过程中不发 Seek（避免原生解码器抖动），松手后补发一次最终精准寻道，
    // 做到所见即所得。播放头必须跟着一起走，否则画面停在新边界、进度条圆钮还留在旧位置，
    // 两者对不上——这正是「点/拖了这里，另一个地方没反应」的另一面。
    this.syncGlobalPlayhead(sec, false)
    // 边界动过之后播放头可能已经不在这一段里了（比如左手柄被拖过播放头），
    // 这里保持用户正在编辑的那一段选中，手柄才不会在松手瞬间消失。
    this.applyState(this.viewModel.selectSegment(id))
    this.markUnsaved()
  }

  private handleDeleteSegment(id: number): void {
    const wasSegmented = !this.state.isRawFull
    this.applyState(this.viewModel.deleteSegment(id))
    this.markUnsaved()
    if (wasSegmented && this.state.isRawFull) {
      this.showToast('已恢复为完整视频')
    }
    this.showControlsTemporarily()
  }

  private handleCycleSegmentSpeed(): void {
    this.applyState(this.viewModel.cycleSpeed())
    this.markUnsaved()
    this.showControlsTemporarily()
  }

  private handleToggleSegmentMute(): void {
    this.applyState(this.viewModel.toggleMuted())
    this.markUnsaved()
    this.showControlsTemporarily()
  }

  private handleToggleSegmentEnabled(id: number): void {
    this.handleDeleteSegment(id)
  }

  /** 模板行只回传 id，这里翻回卡片复用既有的禁用校验与提示。 */
  private selectTemplateById(id: string): void {
    const card = this.state.templateCards.find((item: TemplateCardModel) => item.id === id)
    if (card !== undefined) {
      this.selectTemplateForUi(card)
    }
  }

  /** 参数行/轨道要展示的那一段；没有选中时退回第一段。 */
  private selectedSegment(): Segment {
    const found = this.viewModel.getSelectedSegment(this.state)
    if (found !== undefined) {
      return found
    }
    return this.state.segments.length > 0 ? this.state.segments[0] : new Segment()
  }

  private selectedSegmentId(): number {
    const found = this.viewModel.getSelectedSegment(this.state)
    return found !== undefined ? found.id : -1
  }


  /** 预览区要按播放头所在段的倍速出画（所见即所得，spec §5.4）；落在空档就用默认 1.0x。 */
  private previewSpeedLabel(): string {
    const index = segmentIndexAtSec(this.state.segments, this.state.playheadSec)
    return index >= 0 ? this.state.segments[index].speedLabel : '1.0X'
  }

  /** 同上，静音；落在空档按有声处理。 */
  private previewMuted(): boolean {
    const index = segmentIndexAtSec(this.state.segments, this.state.playheadSec)
    return index >= 0 ? this.state.segments[index].muted : false
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

  private handlePreviewPlayheadChanged(playheadMs: number): void {
    if (!this.previewPlaying) {
      return
    }
    const nextSec = Math.max(0, Math.min(this.state.totalDurationSec, playheadMs / 1000))
    // 播放头连续推进**整条源视频**，不再按片段跳过空档与灰段（2026-10-15 用户要求：
    // 「期望进度条可以播放整个视频，不受片段影响」）。
    // 旧写法按 playbackSkipTargetSec 跳段：末段之后的片尾空档其跳过目标正好是
    // totalDurationSec，于是一播到最后一个片段的结束位置进度条就直接冲到视频末尾。
    // 媒体层本来就不认识剪辑段（EditorPreviewArea 只吃 tripSnapshot.clips，
    // buildSegmentSpans 按整条行程绑 span），跳过纯粹是页面自己加的；
    // 「跳过灰段」只在导出时体现（toExportSegments 只取启用段）。
    this.updatePlayheadSec(nextSec)
    this.updatePlayheadText(this.viewModel.updatePlayheadText(nextSec))
    if (!this.state.isRawFull) {
      const atIndex = segmentIndexAtSec(this.state.segments, nextSec)
      const targetId = atIndex >= 0 ? this.state.segments[atIndex].id : -1
      if (this.state.selectedSegmentId !== targetId) {
        this.applyState(this.viewModel.selectSegment(targetId))
      }
    }
  }

  private handlePreviewEnded(): void {
    this.previewPlaying = false
    this.updatePlayheadSec(this.state.totalDurationSec)
    this.updatePlayheadText(this.viewModel.updatePlayheadText(this.state.totalDurationSec))
    this.showControlsTemporarily()
  }

  @State private timelineWidth: number = 0

  private updateExportStatus(statusText: string): void {
    this.viewModel.setExportStatusText(statusText)
    const nextState = this.state
    nextState.exportStatusText = statusText
    this.state = nextState
  }

  private buildExportSnapshot() {
    return this.viewModel.buildExportSnapshot(this.state, this.exportSessionSeed)
  }

  private async startNativeExportTask(): Promise<void> {
    if (this.exportLoadingVisible) {
      return
    }
    this.pauseAllPreview()
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
    this.exportLoadingText = '准备导出...'
    this.exportProgress = 0
    this.updateExportStatus('准备导出...')
    debugLog('导出', `====================【导出开始】====================`)
    debugLog('导出', `【导出参数-前端状态】tripId=${this.state.tripId} activeTemplateId=${this.state.activeTemplateId} totalDurationSec=${this.state.totalDurationSec} selectedSegmentId=${this.state.selectedSegmentId} watermarkEnabled=${this.state.watermarkEnabled}`)
    debugLog('导出', `【导出参数-前端片段总数】count=${this.state.segments.length}`)
    for (let i = 0; i < this.state.segments.length; i++) {
      const s = this.state.segments[i]
      debugLog('导出', `【导出参数-前端片段明细】#${i} id=${s.id} 区间=[${s.startSec}s -> ${s.endSec}s] 倍速=${s.speedLabel} 静音=${s.muted ? 'YES' : 'NO'} 启用=${s.enabled ? 'YES' : 'NO'}`)
    }
    try {
      const outputPath = await startNativeExport(exportSnapshot, context, (event) => {
        this.updateExportStatus(event.status)
        this.exportLoadingText = event.status
        this.exportProgress = event.progress
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

  /**
   * 唯一的跳转出口：生成一个新的 PreviewSeekRequest（token 递增 + 目标位置），一次赋值同时送达预览区。
   * 之所以不用两个 @Prop（token / targetMs）：ArkUI 不保证两个 @Prop 的更新顺序，
   * 会读到"新 token 配旧位置"，旧代码因此不得不加 260ms settle 窗口 + 0.55s 差值阈值去猜。
   */
  private requestPreviewSeek(targetMs: number): void {
    const request = new PreviewSeekRequest()
    request.token = this.previewSeek.token + 1
    request.targetMs = Math.max(0, Math.round(targetMs))
    this.previewSeek = request
  }

  private switchCamera(camera: string): void {
    this.applyState(this.viewModel.switchCamera(camera))
    this.tripSnapshot = this.viewModel.getTripSnapshot(this.state.tripId)
    this.requestPreviewSeek(this.state.playheadSec * 1000)
    this.viewModel.logPreviewPayload(this.state)
    debugLog('剪辑页', `切换播放器视角=${camera}，片段=${this.state.currentClipIndex}/${this.state.currentClipTotal}`)
    this.showControlsTemporarily()
  }

  private updatePlayhead(second: number): void {
    this.syncGlobalPlayhead(second, true)
  }

  /**
   * 切换模板 —— 一个同步的状态变更。
   *
   * 旧实现是：beginTemplateSwitchTask 拿 taskId → changeTemplate → 等预览区
   * 通过 onTemplateSwitchStageReady 回报 'prepared'/'playing'，期间挂着 1800ms
   * 就绪看门狗和 2200ms 兜底，外加 1500ms release 等待。三个独立超时、两处
   * resolve、四处 isTemplateSwitchTaskValid 复查交错在一起 —— 这正是"修好这个
   * 冒出那个"的源头。预览区的几何与段绑定现在是同步的，切换后只需要把播放
   * 意图同步下去，并触发显式跳转将新绑定机位对齐到当前播放头。
   */
  private selectTemplate(card: TemplateCardModel): void {
    const wasPlaying = this.previewPlaying
    const targetSec = this.state.playheadSec
    try {
      this.applyState(this.viewModel.changeTemplate(card.id))
      this.applyState(this.viewModel.seekGlobalPlayhead(targetSec))
      this.updatePlayheadSec(this.state.playheadSec)
      this.updatePlayheadText(this.viewModel.updatePlayheadText(this.state.playheadSec))
      this.tripSnapshot = this.viewModel.getTripSnapshot(this.state.tripId)
      this.requestPreviewSeek(targetSec * 1000)
      if (wasPlaying) {
        this.startAllPreview()
      }
      debugLog('剪辑页', `切换模板=${card.id}`)
      this.markUnsaved()
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('剪辑页', `切换模板失败：${message}`)
    }
    this.showControlsTemporarily()
  }

  private toggleDrawer(): void {
    this.applyState(this.viewModel.toggleTemplateDrawer(!this.state.drawerExpanded))
  }

  private cycleSpeed(): void {
    const currentSec = this.state.playheadSec
    const nextState = this.viewModel.cycleSpeed()
    nextState.playheadSec = currentSec
    this.applyState(nextState)
    debugLog('剪辑诊断', `切换整体倍速=${this.getPlaybackRate()}X`)
    this.markUnsaved()
    this.showControlsTemporarily()
  }

  private toggleMuted(): void {
    const currentSec = this.state.playheadSec
    const nextState = this.viewModel.toggleMuted()
    nextState.playheadSec = currentSec
    this.applyState(nextState)
    this.showControlsTemporarily()
  }

  private toggleWatermark(): void {
    const currentSec = this.state.playheadSec
    const nextState = this.viewModel.toggleWatermark()
    nextState.playheadSec = currentSec
    this.applyState(nextState)
    this.showControlsTemporarily()
  }

  @Builder
  TopBar() {
    Row() {
      Stack({ alignContent: Alignment.Center }) {
        AppIcon({ name: AppIconName.Back, iconSize: 20, iconColor: $r('app.color.text_secondary') })
      }
      .width(34)
      .height(34)
      .borderRadius(17)
      .backgroundColor($r('app.color.topbar_btn_bg'))
      .border({ width: 1, color: $r('app.color.topbar_btn_border') })
      .onClick(() => this.handleBack())
      Text(this.state.timeRange.length > 0 ? this.state.timeRange : this.state.tripTitle)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .margin({ left: 12, right: 12 })
      Button('导出')
        .type(ButtonType.Normal)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.card_bg'))
        .backgroundColor($r('app.color.amber'))
        .height(32)
        .borderRadius(8)
        .padding({ left: 14, right: 14 })
        .onClick(() => this.startNativeExportTask())
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
  }

  @Builder
  PlayerCard() {
    Column({ space: 0 }) {
      Stack({ alignContent: Alignment.Bottom }) {
        if (this.hasPreviewSource()) {
          EditorPreviewArea({
            activeTemplateId: this.state.activeTemplateId,
            tripSnapshot: this.tripSnapshot,
            playing: this.previewPlaying,
            muted: this.previewMuted(),
            speedLabel: this.previewSpeedLabel(),
            seekRequest: this.previewSeek,
            onPlayheadChanged: (playheadMs: number) => this.handlePreviewPlayheadChanged(playheadMs),
            onPlaybackEnded: () => this.handlePreviewEnded()
          })
        } else if (this.hasImageCover()) {
          Image(this.formatCoverUri(this.tripSnapshot.previewFrameUri))
            .width('100%')
            // 不能用 height('100%')：父 Stack 的高度来自它自己的 aspectRatio，
            // 子元素再要 100% 高度就成了循环依赖，首帧会解出一个畸形的框
            // （点播放后 EditorPreviewArea 用内层 aspectRatio 撑开，布局才自洽）。
            // 让封面图自己撑出 16:9。
            .aspectRatio(STAGE_ASPECT_RATIO)
            .objectFit(ImageFit.Cover)
            .backgroundColor($r('app.color.stage_bg'))
        }
        Column() {
          if (this.showPlayerControls && this.hasPreviewSource()) {
            Button() {
              AppIcon({
                name: this.previewPlaying ? AppIconName.Pause : AppIconName.Play,
                iconSize: 22,
                iconColor: $r('app.color.stage_btn_fg')
              })
            }
            .type(ButtonType.Circle)
            .width(56)
            .height(56)
            .backgroundColor($r('app.color.stage_btn_bg'))
            .border({ width: 1, color: $r('app.color.stage_btn_border') })
            .onClick(() => this.togglePreviewPlay())
          } else if (!this.hasPreviewSource() && !this.hasImageCover()) {
            Text('预览区')
              .fontSize(13)
              .fontColor($r('app.color.overlay_text'))
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick(() => this.handleStageTap())
        // 进度条与播放/暂停按钮同生共死：同一个条件、同一个自动隐藏节奏。
        // 此前它常驻 —— 控件条都收起来了它还杵在画面上；而只有封面图、没有可播源时
        // 它又挂在那里拖不动任何东西。两个方向的自相矛盾一起修掉。
        if (this.showPlayerControls && this.hasPreviewSource()) {
          PreviewOverlay({
            playheadSec: this.state.playheadSec,
            totalDurationSec: this.state.totalDurationSec,
            onScrubTo: (sec: number) => this.handleScrubTo(sec)
          })
        }
      }
      .width('100%')
      .aspectRatio(STAGE_ASPECT_RATIO)
      .backgroundColor($r('app.color.stage_bg'))
      .borderRadius(10)
      .clip(true)
      .border({ width: 1, color: $r('app.color.stage_divider') })

      SegmentParamRow({
        segment: this.selectedSegment(),
        ordinal: segmentOrdinal(this.state.segments, this.selectedSegmentId()),
        isRawFull: this.state.isRawFull,
        isGap: this.viewModel.isGap(this.state),
        canToggle: !this.state.isRawFull && !this.viewModel.isGap(this.state),
        canScissors: this.viewModel.canSplitAtPlayhead(),
        onCycleSpeed: () => this.handleCycleSegmentSpeed(),
        onToggleMute: () => this.handleToggleSegmentMute(),
        onScissors: () => this.splitAtPlayhead(),
        onDeleteSegment: () => this.handleDeleteSegment(this.selectedSegmentId()),
        onToggleEnabled: () => this.handleDeleteSegment(this.selectedSegmentId())
      })

      SegmentTrack({
        segments: this.state.segments,
        totalDurationSec: this.state.totalDurationSec,
        selectedSegmentId: this.selectedSegmentId(),
        isRawFull: this.state.isRawFull,
        onSelectSegment: (id: number) => this.handleSelectSegment(id),
        onSelectGap: (startSec: number) => this.handleSelectGap(startSec),
        onAdjustStart: () => this.pauseAllPreview(),
        onAdjustPreview: (sec: number) => this.handleAdjustPreview(sec),
        onAdjustBoundary: (id: number, edge: 'start' | 'end', sec: number) => this.handleAdjustBoundary(id, edge, sec)
      })
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(16)
    .border({ width: 1, color: $r('app.color.card_border') })
    // 之前整张卡只有一层 1px 描边，落在同为浅色的 page_bg 上几乎看不出边界，
    // 这就是「像原型图」的直接来源。加一层极轻的暖色投影把卡从底色上抬起来。
    .shadow({ radius: 10, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 2 })
    .margin({ left: 16, right: 16, top: 8 })
  }

  @Builder
  TemplateCard() {
    Column({ space: 0 }) {
      Row() {
        Text('智能分屏版式')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text('横滑选择版式')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 14, bottom: 2 })

      TemplateStrip({
        cards: this.state.templateCards,
        timeline: this.state.timeline,
        activeTemplateId: this.state.activeTemplateId,
        onSelectTemplate: (id: string) => this.selectTemplateById(id),
        onRejected: (message: string) => this.showToast(message)
      })
    }
    .width('100%')
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(16)
    .border({ width: 1, color: $r('app.color.card_border') })
    .shadow({ radius: 10, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 2 })
    .margin({ left: 16, right: 16, top: 12, bottom: 24 })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column({ space: 0 }) {
        this.TopBar()

        Scroll() {
          Column({ space: 0 }) {
            this.PlayerCard()
            this.TemplateCard()
          }
          .width('100%')
          // Scroll 的内容默认垂直居中：内容比视口矮时（这一页正是如此）会在播放器
          // 上方留一大片底色。ScrollAttribute 上没有 alignContent（编译报错验证过），
          // 所以改成「内容容器至少撑满视口 + 顶对齐」：内容矮时贴顶，内容高时照常滚动。
          .constraintSize({ minHeight: '100%' })
          .justifyContent(FlexAlign.Start)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')

      if (this.toastVisible) {
        Text(this.toastText)
          .fontSize(13)
          .fontColor($r('app.color.card_bg'))
          .backgroundColor($r('app.color.overlay_veil'))
          .padding({ left: 20, right: 20, top: 10, bottom: 10 })
          .borderRadius(8)
          .position({ x: '22%', y: '86%' })
      }

      if (this.backConfirmVisible) {
        Column({ space: 0 }) {
          Column({ space: 12 }) {
            Text('确认放弃修改？')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            Text('返回将丢失未保存的修改')
              .fontSize(13)
              .fontColor($r('app.color.text_tertiary'))
            Row({ space: 12 }) {
              Button('继续编辑')
                .layoutWeight(1)
                .type(ButtonType.Capsule)
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .backgroundColor($r('app.color.track_bg'))
                .onClick(() => this.cancelBack())
              Button('放弃')
                .layoutWeight(1)
                .type(ButtonType.Capsule)
                .fontSize(14)
                .fontColor($r('app.color.card_bg'))
                .backgroundColor($r('app.color.ink'))
                .onClick(() => this.confirmBack())
            }
            .width('100%')
            .margin({ top: 4 })
          }
          .width('84%')
          .padding(24)
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(16)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.export_scrim'))
      }

      if (this.exportLoadingVisible) {
        Column({ space: 14 }) {
          Progress({ value: Math.max(1, this.exportProgress), total: 100, type: ProgressType.Ring })
            .width(56)
            .height(56)
            .color($r('app.color.amber'))
            .style({ strokeWidth: 4, enableScanEffect: true })
          Text(this.exportLoadingText)
            .fontSize(13)
            .fontColor($r('app.color.export_text'))
        }
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.export_scrim'))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
