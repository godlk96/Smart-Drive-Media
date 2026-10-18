import { EditorPreviewArea } from '../components/EditorPreviewArea'
import { AppIcon, AppIconName } from '../components/AppIcon'
import { SegmentParamRow } from '../components/SegmentParamRow'
import { PreviewOverlay, SegmentTrack } from '../components/SegmentTrack'
import { TemplateStrip } from '../components/TemplateStrip'
import { sharedCoreBridge } from '../bridge/CoreBridge'
import { EditorStateModel, PreviewSeekRequest, TemplateCardModel, TimelineTrackModel } from '../model/AppState'
import { Segment, MAX_SEGMENTS, createFullSegment, segmentIndexAtSec, segmentOrdinal } from '../model/SegmentModel'
import { TripSnapshot } from '../model/TripModels'
import { DEFAULT_TEMPLATE_ID, parseExportSnapshot, snapshotMatchesTrip } from '../model/Models'
import { EditRecord, findRecordById, recordMatchesTrip, recordsForTrip } from '../model/EditRecord'
import { EditHistoryService } from '../service/EditHistoryService'
import { startNativeExport, cancelNativeExport } from '../NativeExportManager'
import { debugLog } from '../utils/Logger'
import { formatTripDay, formatTripDuration } from '../utils/TripFormat'
import common from '@ohos.app.ability.common'
import window from '@ohos.window'
import { EditorViewModel, EditorHydrateResult } from '../viewmodel/EditorViewModel'

/**
 * 画面区恒为 3:2。
 *
 * 以前这里跟模板走 `getPreviewAspectRatio()`，五个模板的自然高度是 366/275/92/92/183px
 * （内容宽 326px 时），最大差 4 倍 —— 每切一次模板，下面的参数行和片段轨道就上下弹一次。
 * 所以定成一个常量，模板组合由 EditorPreviewArea 自己按 Contain 缩放居中、
 * 四周留 stage_bg 黑边（它内部本来就有这层等比约束），切模板时下方一动不动。
 *
 * 比例是两轮调整的结果：16:9 → 16:10 → 3:2。宽 304vp 时高度依次是 171 / 190 / 202.7vp。
 * 继续往高走是有上限的 —— 五个版式里 T3/T4 是 32:9 的超宽画布，框越高它们上下留的黑边越厚
 * （304 宽时 T3/T4 只有 85.5vp 高）。所以停在 3:2，再高就该改版式画布本身了。
 * 比例仍然是常量，所以「切模板下方不动」这条性质不变。
 */
const STAGE_ASPECT_RATIO: number = 3 / 2

@Entry
@Component
struct Editor {
  private viewModel: EditorViewModel = new EditorViewModel()
  @StorageProp('statusBarHeight') statusBarHeight: number = 38
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
  /** 从「我的剪辑」进来的那条记录的 id；空串 = 从行程库进来的，没有历史上下文 */
  @State private recordId: string = ''
  /** 记录还原是异步的，首帧到还原完成之间不允许导出 */
  @State private restorePending: boolean = false
  /** 记录与现场行程对不上时的明确出口（反目标 3：绝不静默用错素材） */
  @State private driftVisible: boolean = false
  @State private overwritePromptVisible: boolean = false
  /** 这趟行程已有几条作品，覆盖询问文案要用 */
  @State private overwriteCount: number = 0
  private overwriteCandidate: EditRecord | undefined = undefined
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
    activeTemplateId: DEFAULT_TEMPLATE_ID,
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
    try {
      const uiContext = this.getUIContext()
      if (uiContext) {
        const hostContext = uiContext.getHostContext() as common.UIAbilityContext
        if (hostContext) {
          window.getLastWindow(hostContext, (err, win) => {
            if (!err && win) {
              const area = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM)
              const h = uiContext.px2vp(area.topRect.height)
              if (h > 0) {
                this.statusBarHeight = h
              }
            }
          })
        }
      }
    } catch (_) { }
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
    const recordId = params.recordId ?? ''
    debugLog('剪辑页', `进入页面，行程ID=${tripId}，标题提示=${title}，副标题提示=${subtitle}，记录ID=${recordId}`)
    if (recordId.length > 0) {
      // 从「我的剪辑」进来：要先把记录读出来才能判断能不能还原，是异步的。
      // 生命周期保持同步（ArkUI 不保证 async 生命周期），这里 fire-and-forget。
      this.restorePending = true
      void this.resolveRestore(recordId, tripId)
      return
    }
    this.applyHydrateResult(this.viewModel.hydrate(tripId))
  }

  /**
   * 从一条历史记录还原剪辑页。
   *
   * 「能不能还原」的判断放在这里而不是 CoreBridge：只有页面知道还原失败时该给用户
   * 说什么（弹窗 + 两条出口）；桥接层只负责「能还原时怎么装配」。
   * 参数以记录为准、素材以现场为准，两边对不上就明确报错，绝不静默换素材。
   */
  private async resolveRestore(recordId: string, tripId: string): Promise<void> {
    try {
      const record: EditRecord | undefined = await EditHistoryService.getInstance().findById(recordId)
      const stored = record ? parseExportSnapshot(record.snapshot) : undefined
      // tripId 会随源素材增删而整体重编号，所以先按 (标题, 起始时间) 找回
      // 现场的真实 id；找不回来才退回参数里的 tripId（此时后续校验会判漂移）。
      const liveTripId = record !== undefined
        ? this.viewModel.resolveTripIdByTitleStartTs(record.tripTitle, record.tripStartTs)
        : ''
      const effectiveTripId = liveTripId.length > 0 ? liveTripId : tripId
      const live = this.viewModel.getTripSnapshot(effectiveTripId)
      if (record && stored && snapshotMatchesTrip(stored, live)) {
        this.recordId = recordId
        this.applyHydrateResult(this.viewModel.hydrateFromRecord(effectiveTripId, JSON.stringify([record])))
        debugLog('剪辑页', `按记录还原成功 recordId=${recordId} 现场行程=${effectiveTripId}`)
      } else {
        debugLog('剪辑页', `还原不可用：记录存在=${record !== undefined}，快照可用=${stored !== undefined}，判定为素材已漂移`)
        // 先把页面铺成白纸再弹窗：关掉弹窗后用户看到的是可编辑的正常页面，而不是空壳。
        this.applyHydrateResult(this.viewModel.hydrate(tripId))
        this.driftVisible = true
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('剪辑页', `还原过程异常：${message}`)
      this.applyHydrateResult(this.viewModel.hydrate(tripId))
      this.driftVisible = true
    } finally {
      this.restorePending = false
    }
  }

  private applyHydrateResult(hydrateResult: EditorHydrateResult): void {
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

  /**
   * 点画面：控件条开着就**立刻收起**，收起了再点才唤回来（spec §5.2）。
   *
   * 以前这里只有 `showControlsTemporarily()` —— 点一下只是把控件"续命" 3 秒，
   * 想让它消失只能等定时器到点，用户反馈"没法主动消失"。
   * 现在是个开关：可见 → 立即隐藏并清掉定时器（不清的话 3 秒后那次赋值只是重复设假，
   * 但如果用户在这 3 秒内又点开，残留的定时器会把它再关一次）；
   * 不可见 → 显示并重新计时。
   */
  private handleStageTap(): void {
    if (this.showPlayerControls) {
      this.clearHideControlsTimer()
      this.showPlayerControls = false
      debugLog('剪辑诊断', '点击画面，播放控件已收起')
      return
    }
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

  /**
   * 导出入口：**先问要不要覆盖，再真正开跑**。
   *
   * 覆盖是在保存阶段跳过相册对话框、直接就地覆写旧条目（spec 4.5），
   * 所以这个问题必须在合成开始之前问 —— 问晚了相册里就已经多出一条新成片，
   * 而删掉它需要我们没有的受控权限，就变成永远收不回来的重复文件。
   */
  private async startNativeExportTask(): Promise<void> {
    if (this.exportLoadingVisible || this.restorePending || this.overwritePromptVisible) {
      return
    }
    this.pauseAllPreview()
    let existing: Array<EditRecord> = []
    try {
      const all: Array<EditRecord> = await EditHistoryService.getInstance().list()
      // 先按 (标题, 起始时间) 匹配：tripId 会随源素材增删重编号，只按 id 找
      // 会漏掉明明存在的记录，于是覆盖询问被跳过、相册里多出一份重复成片。
      existing = all.filter((item: EditRecord) =>
        recordMatchesTrip(item, this.tripSnapshot.tripTitle, this.tripSnapshot.startTs))
      if (existing.length === 0) {
        existing = recordsForTrip(all, this.state.tripId)
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('导出', `读取历史记录失败，按无历史处理：${message}`)
    }
    // 从「我的剪辑」进来时目标是那条记录本身；从行程库进来时目标是最近一条（spec 5.1）。
    const target: EditRecord | undefined = this.recordId.length > 0
      ? findRecordById(existing, this.recordId)
      : (existing.length > 0 ? existing[0] : undefined)
    if (target) {
      this.overwriteCandidate = target
      this.overwriteCount = existing.length
      this.overwritePromptVisible = true
      return
    }
    await this.launchExport('')
  }

  /** 真正的导出。overwriteTargetUri 为空 = 新建相册条目；非空 = 就地覆写那一条。 */
  private async launchExport(overwriteTargetUri: string): Promise<void> {
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
    this.exportLoadingText = '准备导出...'
    this.exportProgress = 0
    this.updateExportStatus('准备导出...')
    debugLog('导出', `====================【导出开始】====================`)
    debugLog('导出', `【导出参数-前端状态】tripId=${this.state.tripId} activeTemplateId=${this.state.activeTemplateId} totalDurationSec=${this.state.totalDurationSec} selectedSegmentId=${this.state.selectedSegmentId} watermarkEnabled=${this.state.watermarkEnabled} 覆盖=${overwriteTargetUri.length > 0 ? 'YES' : 'NO'}`)
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
      }, overwriteTargetUri)
      // 覆盖与新建共用这一句：用户要的就是「保存成功」的回执（spec 4.9）。
      // 注意这里不解析 outputPath —— NativeExportManager 在第一个终结事件上就 resolve，
      // 拿到的可能是文件名而不是相册 URI，但成功与否是确定的。
      debugLog('导出', `导出返回：${outputPath}`)
      this.updateExportStatus('已保存到相册')
      // 成片进了相册，但记录可能只落在内存里（偏好写入失败 / 无 context）。
      // 那种情况下重启就看不到这条作品，必须如实说出来，不能假装一切正常。
      if (EditHistoryService.getInstance().isRecordsDurable()) {
        this.showToast('已保存到相册')
      } else {
        this.showToast('已保存到相册，但历史记录暂时不可用')
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      if (message.indexOf('已取消') >= 0 || message.indexOf('cancel') >= 0) {
        this.updateExportStatus('已取消导出')
        this.showToast('已取消导出')
        debugLog('导出', '导出已被用户取消')
      } else {
        this.updateExportStatus(`导出失败：${message}`)
      }
    } finally {
      this.exportLoadingVisible = false
    }
  }

  /** 覆盖询问的两个出口。candidate 可能在弹窗打开期间被清空，故此处再取一次。 */
  private chooseOverwrite(overwrite: boolean): void {
    const candidate: EditRecord | undefined = this.overwriteCandidate
    this.overwritePromptVisible = false
    this.overwriteCandidate = undefined
    const targetUri: string = (overwrite && candidate) ? candidate.albumUri : ''
    void this.launchExport(targetUri)
  }

  private overwritePromptText(): string {
    if (this.recordId.length > 0) {
      return '这条作品已经导出过，要覆盖它吗？'
    }
    return `这趟行程已经导出过 ${this.overwriteCount} 条，要覆盖最近那一条吗？`
  }

  private cancelExportTask(): void {
    cancelNativeExport()
    this.exportLoadingVisible = false
    this.updateExportStatus('已取消导出')
    this.showToast('已取消导出')
    debugLog('导出', '用户点击浮层关闭按钮，已中断后台导出')
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

  /**
   * 顶栏主行：哪一天的行车。`tripSnapshot.title` 就是 `firstSlice[0].date`
   * （形如 `2026-10-01`），过现成的 `formatTripDay()` 变成「10月1日 周四」。
   * 解析失败时 formatTripDay 原样返回，于是退化成日期原文，不会空。
   */
  private tripIdentityTitle(): string {
    const day: string = formatTripDay(this.tripSnapshot.title)
    return day.length > 0 ? day : this.state.tripTitle
  }

  /**
   * 顶栏副行：时长 · 段数 · 视角数。
   *
   * 这里以前放的是 `state.timeRange`（`13:28:05 - 13:52:41`）—— 一个没有上下文、
   * 也没人看的时钟区间。换成三个能从 state 直接取到的量：素材总时长、切了几段、
   * 这台车这次录到了几个视角。
   */
  private tripIdentityMeta(): string {
    const duration: string = formatTripDuration(this.state.totalDurationSec)
    const segments: number = this.state.isRawFull && this.tripSnapshot.segmentCount > 1
      ? this.tripSnapshot.segmentCount
      : this.state.segments.length
    const cameras: number = this.state.timeline.length
    return `${duration} · ${segments} 段 · ${cameras} 视角`
  }

  @Builder
  TopBar() {
    Row() {
      Stack({ alignContent: Alignment.Center }) {
        AppIcon({ name: AppIconName.Back, iconSize: 22, iconColor: $r('app.color.text_secondary') })
      }
      .width(38)
      .height(38)
      .borderRadius(19)
      .backgroundColor($r('app.color.ed_surface'))
      .border({ width: 1, color: $r('app.color.ed_line') })
      .onClick(() => this.handleBack())
      Column({ space: 0 }) {
        Text(this.tripIdentityTitle())
          .fontSize(15)
          .lineHeight(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
        Text(this.tripIdentityMeta())
          .fontSize(11.5)
          .lineHeight(16)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .margin({ left: 12, right: 12 })
      Button('导出')
        .type(ButtonType.Normal)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.card_bg'))
        .backgroundColor($r('app.color.amber'))
        .height(38)
        .borderRadius(10)
        .padding({ left: 17, right: 17 })
        .onClick(() => {
          // 丢掉返回的 Promise 会让内部异常变成未处理的 rejection；
          // 这里显式 void，异常由 startNativeExportTask 自己的 try/catch 兜住。
          void this.startNativeExportTask()
        })
    }
    .width('100%')
    // 52 → 64，并且上下留出不对称的内边距（上 12 / 下 8）。
    //
    // 原来高度 52、上下 0 内边距，内容虽然被 Row 垂直居中，但整条贴着屏幕顶边，
    // 视觉重心比几何中心还高 —— 用户看到的就是"居中了但偏上"（文字和导出按钮都偏上）。
    // 上面多给 4vp 是为了抵消两行文字"上重下轻"（标题 15px 压在 11.5px 的次级行上）
    // 造成的光学偏差，让文字块看起来真的在中间。
    .height(56 + (this.statusBarHeight > 0 ? this.statusBarHeight : 38))
    .padding({
      left: 16,
      right: 16,
      top: (this.statusBarHeight > 0 ? this.statusBarHeight : 38) + 8,
      bottom: 8
    })
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
            // 让封面图自己撑出 STAGE_ASPECT_RATIO。
            .aspectRatio(STAGE_ASPECT_RATIO)
            .objectFit(ImageFit.Cover)
            .backgroundColor($r('app.color.stage_bg'))
        }
        // 铺满整块画面的点击层，专门负责"点画面收起 / 唤回播放控件"。
        //
        // 它必须和控件层是**兄弟**、而不是把 onClick 挂在控件层上。挂在控件层上会有个
        // 躲不掉的问题：播放钮是控件层的子节点，点钮时父层的 onClick 会不会跟着触发
        // 取决于 ArkUI 的点击冒泡行为 —— 冒泡就会"点播放反而把控件收起来"。
        // 拆成兄弟层之后，命中关系由 hitTestBehavior 明确决定，不依赖冒泡：
        //   控件层 .hitTestBehavior(HitTestMode.None) —— 自己不吃事件，但子节点（播放钮）照常吃；
        //   于是点在钮上 → 钮响应（它的默认 HitTestMode 挡住下面的兄弟）；
        //       点在空白处 → 控件层不吃，落到这一层 → handleStageTap()。
        Column()
          .width('100%')
          .height('100%')
          .onClick(() => this.handleStageTap())
        Column() {
          if (this.showPlayerControls && this.hasPreviewSource()) {
            // 触摸区 76×76，看得见的圆盘只有 54×54 —— 用户要的是"大按钮一小圈"。
            // 钮本身铺 76 是为了手指够得着（44vp 是下限，76 更好按），
            // 视觉全部交给里面那个圆盘，所以外层底色透明、也不描边。
            Button() {
              Stack({ alignContent: Alignment.Center }) {
                AppIcon({
                  name: this.previewPlaying ? AppIconName.Pause : AppIconName.Play,
                  iconSize: 24,
                  iconColor: $r('app.color.stage_btn_fg')
                })
              }
              .width(54)
              .height(54)
              .borderRadius(27)
              // 圆盘是 40% 的暖黑（见 color.json 的 stage_btn_bg），描边同色。
              //
              // 这里走过一段弯路：上一轮把底和描边都设成全透明、只留白色图标，
              // 压在大片亮画面（雪地、天空）上白三角直接糊掉，用户否掉了。
              // 结论是**这个钮必须有底**，区别只在底色：现在是暖黑半透明
              //（保住画面、亮暗画面上都读得出），另一条路是实心琥珀
              //（品牌色更响，但会把画面盖掉一块）。
              .backgroundColor($r('app.color.stage_btn_bg'))
              .border({ width: 1, color: $r('app.color.stage_btn_border') })
            }
            .type(ButtonType.Circle)
            .width(76)
            .height(76)
            .backgroundColor(Color.Transparent)
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
        // None：这一层自己不参与命中，但子节点（播放钮）照常参与 —— 见上面点击层的注释。
        .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .aspectRatio(STAGE_ASPECT_RATIO)
      .backgroundColor($r('app.color.stage_bg'))
      .borderRadius(14)
      .clip(true)

      // 进度条从画面里搬出来，单独占画面下方一行。
      // 以前它压在画面上、并且跟播放键同生共死（同一个 showPlayerControls 条件）：
      // 控件条收起来了它还杵在画面中央，而只有封面图、没有可播源时它又挂在那里拖不动。
      // 搬出来之后它变成卡片布局的一部分 —— 常驻、不遮画面，也不会让卡片高度跳。
      PreviewOverlay({
        playheadSec: this.state.playheadSec,
        totalDurationSec: this.state.totalDurationSec,
        onScrubTo: (sec: number) => this.handleScrubTo(sec)
      })

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
    .backgroundColor($r('app.color.ed_surface'))
    .borderRadius(18)
    .border({ width: 1, color: $r('app.color.ed_line') })
    // 之前整张卡只有一层 1px 描边，落在同为浅色的底色上几乎看不出边界，
    // 这就是「像原型图」的直接来源。加一层极轻的暖色投影把卡从底色上抬起来。
    .shadow({ radius: 10, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 2 })
    .margin({ top: 12, bottom: 24 })
  }

  @Builder
  TemplateCard() {
    Column({ space: 0 }) {
      Row() {
        Text('模版')
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
    .backgroundColor($r('app.color.ed_surface'))
    .borderRadius(18)
    .border({ width: 1, color: $r('app.color.ed_line') })
    .shadow({ radius: 10, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 2 })
    .margin({ top: 12, bottom: 0 })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column({ space: 0 }) {
        this.TopBar()

        Scroll() {
          Column({ space: 0 }) {
            // 模版在播放器上方：选版式是这一页的第一个决定，先选版式再看画面。
            // （原来播放器在前、模版在最下面，滑到版式行要先划过大半屏。）
            this.TemplateCard()
            this.PlayerCard()
          }
          .width('100%')
          .padding({ left: 10, right: 10 })
          .constraintSize({ minHeight: '100%' })
          .justifyContent(FlexAlign.Start)
        }
        .layoutWeight(1)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
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
          .backgroundColor($r('app.color.ed_surface'))
          .borderRadius(18)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.export_scrim'))
      }

      if (this.exportLoadingVisible) {
        Column({ space: 0 }) {
          Stack({ alignContent: Alignment.TopEnd }) {
            Column({ space: 14 }) {
              Text('正在导出视频')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
                .margin({ top: 4 })

              Stack({ alignContent: Alignment.Center }) {
                Progress({ value: Math.max(1, this.exportProgress), total: 100, type: ProgressType.Ring })
                  .width(68)
                  .height(68)
                  .color($r('app.color.amber'))
                  .style({ strokeWidth: 5, enableScanEffect: true, enableSmoothEffect: true })
                Text(`${Math.max(0, this.exportProgress).toFixed(1)}%`)
                  .fontSize(13)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
              }
              .margin({ top: 4, bottom: 4 })

              Text(this.exportLoadingText)
                .fontSize(13)
                .fontColor($r('app.color.text_tertiary'))
                .textAlign(TextAlign.Center)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)

            // 右上角关闭 X 按钮
            Button() {
              Stack({ alignContent: Alignment.Center }) {
                AppIcon({ name: AppIconName.Close, iconSize: 13, iconColor: $r('app.color.text_secondary') })
              }
              .width(28)
              .height(28)
              .borderRadius(14)
              .backgroundColor($r('app.color.track_bg'))
              .border({ width: 1, color: $r('app.color.ed_line') })
            }
            .type(ButtonType.Circle)
            .width(36)
            .height(36)
            .backgroundColor(Color.Transparent)
            .onClick(() => this.cancelExportTask())
          }
          .width('84%')
          .padding({ left: 20, right: 20, top: 18, bottom: 24 })
          .backgroundColor($r('app.color.ed_surface'))
          .borderRadius(18)
          .border({ width: 1, color: $r('app.color.ed_line') })
          .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.export_scrim'))
      }

      if (this.driftVisible) {
        Column({ space: 0 }) {
          Column({ space: 12 }) {
            Text('原始行程素材已不在')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            Text('这次剪辑无法还原。可能是源素材被删除、被移动，或这是一次合并剪辑（重启后合并行程不再存在）。')
              .fontSize(13)
              .fontColor($r('app.color.text_tertiary'))
              .lineHeight(19)
            Row({ space: 12 }) {
              Button('返回')
                .layoutWeight(1)
                .type(ButtonType.Capsule)
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .backgroundColor($r('app.color.track_bg'))
                .onClick(() => {
                  this.driftVisible = false
                  this.getUIContext().getRouter().back()
                })
              Button('当作新剪辑打开')
                .layoutWeight(1)
                .type(ButtonType.Capsule)
                .fontSize(14)
                .fontColor($r('app.color.card_bg'))
                .backgroundColor($r('app.color.ink'))
                .onClick(() => {
                  // 页面在弹窗打开前已经铺成白纸，这里只需收起弹窗。
                  this.driftVisible = false
                })
            }
            .width('100%')
            .margin({ top: 4 })
          }
          .width('84%')
          .padding(24)
          .backgroundColor($r('app.color.ed_surface'))
          .borderRadius(18)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.export_scrim'))
      }

      if (this.overwritePromptVisible) {
        Column({ space: 0 }) {
          Column({ space: 12 }) {
            Text(this.overwritePromptText())
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            Text('覆盖会直接替换相册里那条成片，并更新「我的剪辑」里的这条作品；存成新的则保留旧的、多出一条。')
              .fontSize(13)
              .fontColor($r('app.color.text_tertiary'))
              .lineHeight(19)
            Row({ space: 12 }) {
              Button('存成新的')
                .layoutWeight(1)
                .type(ButtonType.Capsule)
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .backgroundColor($r('app.color.track_bg'))
                .onClick(() => this.chooseOverwrite(false))
              Button('覆盖那一条')
                .layoutWeight(1)
                .type(ButtonType.Capsule)
                .fontSize(14)
                .fontColor($r('app.color.card_bg'))
                .backgroundColor($r('app.color.amber'))
                .onClick(() => this.chooseOverwrite(true))
            }
            .width('100%')
            .margin({ top: 4 })
          }
          .width('84%')
          .padding(24)
          .backgroundColor($r('app.color.ed_surface'))
          .borderRadius(18)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.export_scrim'))
      }
    }
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.ed_bg'))
  }
}
