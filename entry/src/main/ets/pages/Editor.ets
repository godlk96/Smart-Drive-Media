import { EditorPreviewArea } from '../components/EditorPreviewArea'
import { SegmentParamRow } from '../components/SegmentParamRow'
import { PreviewOverlay, SegmentTrack } from '../components/SegmentTrack'
import { TemplateStrip } from '../components/TemplateStrip'
import { sharedCoreBridge } from '../bridge/CoreBridge'
import { EditorStateModel, PreviewSeekRequest, TemplateCardModel, TimelineTrackModel } from '../model/AppState'
import { Segment, MAX_SEGMENTS, canToggleSegment, createFullSegment, enabledCount, playbackSkipTargetSec, segmentIndexAtSec } from '../model/SegmentModel'
import { TripSnapshot } from '../model/TripModels'
import { startNativeExport } from '../NativeExportManager'
import { debugLog } from '../utils/Logger'
import common from '@ohos.app.ability.common'
import { EditorViewModel } from '../viewmodel/EditorViewModel'

@Entry
@Component
struct Editor {
  private viewModel: EditorViewModel = new EditorViewModel()
  private bridge = sharedCoreBridge
  private exportSessionSeed: string = ''
  private controlsTimer: number = -1
  private lastLoggedSecond: number = -1
  @State private showPlayerControls: boolean = true
  @State private showPreviewCover: boolean = true
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
    exportStatusText: '待导出'
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
    this.showPreviewCover = this.hasPreviewSource()
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

  private getPreviewAspectRatio(): number {
    return this.viewModel.getPreviewAspectRatio(this.state.activeTemplateId)
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
    return this.viewModel.getTemplateUiName(card)
  }

  private getTemplateResolution(card: TemplateCardModel): string {
    return this.viewModel.getTemplateResolution(card)
  }

  private getTemplateIcon(card: TemplateCardModel): string {
    return this.viewModel.getTemplateIcon(card)
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
   * 剪刀：在播放头处落刀。规则见 spec §5.3；满 3 段或切出短于 2 秒的段时拒绝并提示（spec §5.5）。
   */
  private splitAtPlayhead(): void {
    if (enabledCount(this.state.segments) >= MAX_SEGMENTS) {
      this.showToast('最多只能添加3个剪辑点')
      return
    }
    if (!this.viewModel.canSplitAtPlayhead()) {
      this.showToast('片段太短，至少 2 秒')
      return
    }
    this.applyState(this.viewModel.splitAtPlayhead())
    this.markUnsaved()
    this.showControlsTemporarily()
  }

  /** 点画面：有封面就先起播并收掉封面，其余情况把控制条唤回来（spec §5.2）。 */
  private handleStageTap(): void {
    if (this.showPreviewCover && this.hasPreviewSource()) {
      this.startAllPreview()
      this.showPreviewCover = false
    }
    this.showControlsTemporarily()
  }

  /** 点片段块：选中该段，圆钮跳到该段起点（spec §5.4）。 */
  private handleSelectSegment(id: number): void {
    const target = this.state.segments.find((item: Segment) => item.id === id)
    this.applyState(this.viewModel.selectSegment(id))
    if (target !== undefined) {
      this.syncGlobalPlayhead(target.startSec, false)
    }
  }

  /** 拖圆钮：先跳转，再让圆钮落点所在的那一段选中（spec §5.4）。 */
  private handleScrubTo(sec: number): void {
    this.syncGlobalPlayhead(sec, true)
    const index = segmentIndexAtSec(this.state.segments, sec)
    if (index >= 0) {
      this.applyState(this.viewModel.selectSegment(this.state.segments[index].id))
    }
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
    this.applyState(this.viewModel.toggleSegmentEnabled(id))
    this.markUnsaved()
    this.showControlsTemporarily()
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
    return found !== undefined ? found : this.state.segments[0]
  }

  private selectedSegmentId(): number {
    const found = this.viewModel.getSelectedSegment(this.state)
    return found !== undefined ? found.id : -1
  }

  private canToggleSelected(): boolean {
    return canToggleSegment(this.state.segments, this.selectedSegmentId())
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
    // 播放跳过灰段与空档：落点不在活段内就直接跳到下一个活段起点（spec §5.4）。
    const skipTarget = playbackSkipTargetSec(this.state.segments, nextSec, this.state.totalDurationSec)
    if (Math.abs(skipTarget - nextSec) > 1e-6) {
      this.syncGlobalPlayhead(skipTarget, false)
      return
    }
    this.updatePlayheadSec(nextSec)
    this.updatePlayheadText(this.viewModel.updatePlayheadText(nextSec))
  }

  private handlePreviewEnded(): void {
    this.previewPlaying = false
    this.showPreviewCover = true
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
    this.showPreviewCover = this.hasPreviewSource()
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
   * 意图同步下去；时钟位置不变（播放头由 TimelineClock 持有，不必在此重设）。
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
      this.showPreviewCover = !wasPlaying
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
      Text('←')
        .fontSize(19)
        .fontColor($r('app.color.text_secondary'))
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
        .fontColor($r('app.color.card_bg'))
        .backgroundColor($r('app.color.ink'))
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
        }
        Column() {
          if (this.showPlayerControls && this.hasPreviewSource()) {
            Button() {
              Text('▶')
                .fontSize(16)
                .fontColor($r('app.color.stage_btn_fg'))
            }
            .type(ButtonType.Circle)
            .width(56)
            .height(56)
            .backgroundColor($r('app.color.stage_btn_bg'))
            .border({ width: 1, color: $r('app.color.stage_btn_border') })
            .onClick(() => this.togglePreviewPlay())
          } else if (!this.hasPreviewSource()) {
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
        PreviewOverlay({
          playheadSec: this.state.playheadSec,
          totalDurationSec: this.state.totalDurationSec,
          canScissors: this.viewModel.canSplitAtPlayhead(),
          onScrubTo: (sec: number) => this.handleScrubTo(sec),
          onScissors: () => this.splitAtPlayhead()
        })
      }
      .width('100%')
      .aspectRatio(this.viewModel.getPreviewAspectRatio(this.state.activeTemplateId))
      .backgroundColor($r('app.color.stage_bg'))

      SegmentParamRow({
        segment: this.selectedSegment(),
        canToggle: this.canToggleSelected(),
        onCycleSpeed: () => this.handleCycleSegmentSpeed(),
        onToggleMute: () => this.handleToggleSegmentMute(),
        onToggleEnabled: () => this.handleToggleSegmentEnabled(this.selectedSegmentId())
      })

      SegmentTrack({
        segments: this.state.segments,
        totalDurationSec: this.state.totalDurationSec,
        selectedSegmentId: this.selectedSegmentId(),
        onSelectSegment: (id: number) => this.handleSelectSegment(id)
      })
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(16)
    .border({ width: 1, color: $r('app.color.card_border') })
    .margin({ left: 16, right: 16, top: 8 })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column({ space: 0 }) {
        this.TopBar()

        Scroll() {
          Column({ space: 0 }) {
            this.PlayerCard()
            TemplateStrip({
              cards: this.state.templateCards,
              timeline: this.state.timeline,
              activeTemplateId: this.state.activeTemplateId,
              onSelectTemplate: (id: string) => this.selectTemplateById(id),
              onRejected: (message: string) => this.showToast(message)
            })
          }
          .width('100%')
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
