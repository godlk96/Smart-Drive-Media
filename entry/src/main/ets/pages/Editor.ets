import { sharedCoreBridge } from '../bridge/CoreBridge'
import { EditorStateModel, PreviewSlotModel, TemplateCardModel, TimelineMarkerModel, TimelineTrackModel } from '../model/AppState'
import { debugLog } from '../utils/Logger'

@Entry
@Component
struct Editor {
  private bridge = sharedCoreBridge
  private previewController: VideoController = new VideoController()
  private secondaryControllerA: VideoController = new VideoController()
  private secondaryControllerB: VideoController = new VideoController()
  private secondaryControllerC: VideoController = new VideoController()
  private controlsTimer: number = -1
  private lastLoggedSecond: number = -1
  private previewLogged: boolean = false
  private timelineLogged: boolean = false
  @State private showPlayerControls: boolean = true
  @State private showPreviewCover: boolean = true
  @State private seamlessPendingPlay: boolean = false
  @State private previewPlaying: boolean = true
  @State private showSlotLabels: boolean = false
  @State private playheadSec: number = 0
  @State private timelineStartSec: number = 0
  @State private timelineEndSec: number = 60
  @State private state: EditorStateModel = {
    tripId: '',
    tripTitle: '剪辑工作台',
    timeRange: '',
    previewUri: '',
    previewCamera: '',
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
    this.state = nextState
    this.timelineStartSec = nextState.selectionStartSec
    this.timelineEndSec = nextState.selectionEndSec
    this.playheadSec = Math.max(0, Math.min(this.playheadSec, nextState.totalDurationSec))
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
    this.applyState(this.bridge.createEditorState(tripId, title, subtitle))
    this.showPreviewCover = this.state.previewUri.length > 0
    this.seamlessPendingPlay = false
    this.previewPlaying = true
    this.showPlayerControls = true
    this.applyPlaybackRate()
    this.scheduleHideControls()
    const trackSummary = this.state.timeline.map((item: TimelineTrackModel) => `${item.cameraPosition}:${item.segmentCount}`).join(',')
    debugLog('剪辑诊断', `初始化完成，时长=${this.state.totalDurationSec}s，轨道数=${this.state.timeline.length}，轨道明细=${trackSummary}，预览URI长度=${this.state.previewUri.length}，预览视角=${this.state.previewCamera}`)
  }

  aboutToDisappear(): void {
    this.clearHideControlsTimer()
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

  private previewRotationAngle(camera: string): number {
    return 0
  }

  private getPreviewAspectRatio(): number {
    if (this.state.activeTemplateId === 'T4') {
      return 9 / 16
    }
    return 16 / 9
  }

  private getPrimaryPreviewSlot(): PreviewSlotModel | undefined {
    return this.state.previewSlots[0]
  }

  private isPrimaryPreviewSlot(slotId: string): boolean {
    const primary = this.getPrimaryPreviewSlot()
    return primary !== undefined && primary.id === slotId
  }

  private hasPreviewSource(): boolean {
    return this.state.previewSlots.some((slot: PreviewSlotModel) => slot.uri.length > 0)
  }

  private isMergedTrip(): boolean {
    return this.state.tripId.startsWith('trip-merged-')
  }

  private getSecondaryController(slotId: string): VideoController {
    if (slotId === 'pip' || slotId === 'bottomLeft' || slotId === 'left') {
      return this.secondaryControllerA
    }
    if (slotId === 'bottomRight' || slotId === 'right' || slotId === 'middle') {
      return this.secondaryControllerB
    }
    return this.secondaryControllerC
  }

  private startAllPreview(): void {
    this.previewController.start()
    this.secondaryControllerA.start()
    this.secondaryControllerB.start()
    this.secondaryControllerC.start()
    this.previewPlaying = true
  }

  private pauseAllPreview(): void {
    this.previewController.pause()
    this.secondaryControllerA.pause()
    this.secondaryControllerB.pause()
    this.secondaryControllerC.pause()
    this.previewPlaying = false
  }

  private togglePreviewPlay(): void {
    if (this.previewPlaying) {
      this.pauseAllPreview()
      debugLog('剪辑诊断', '点击暂停预览，已同步暂停全部画面')
    } else {
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
    if (parsed >= 1.5 && parsed <= 4) {
      return parsed
    }
    return 1.5
  }

  private applyPlaybackRate(): void {
    const rate = this.getPlaybackRate()
    const applyRate = (controller: VideoController): void => {
      const controllerHost = controller as Object as Record<string, (value: number) => void>
      const speedHandler = controllerHost['setSpeed']
      if (speedHandler) {
        speedHandler(rate)
      }
    }
    applyRate(this.previewController)
    applyRate(this.secondaryControllerA)
    applyRate(this.secondaryControllerB)
    applyRate(this.secondaryControllerC)
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
    return Math.max(0, Math.floor(globalSecond - clipStart))
  }

  private seekAllControllers(localSecond: number): void {
    this.previewController.setCurrentTime(localSecond)
    this.secondaryControllerA.setCurrentTime(localSecond)
    this.secondaryControllerB.setCurrentTime(localSecond)
    this.secondaryControllerC.setCurrentTime(localSecond)
  }

  private getRangeStartPercent(): string {
    const total = Math.max(1, this.state.totalDurationSec)
    const percent = Math.max(0, Math.min(100, (this.timelineStartSec / total) * 100))
    return `${percent}%`
  }

  private getRangeEndPercent(): string {
    const total = Math.max(1, this.state.totalDurationSec)
    const percent = Math.max(0, Math.min(100, (this.timelineEndSec / total) * 100))
    return `${percent}%`
  }

  private getRangeWidthPercent(): string {
    const total = Math.max(1, this.state.totalDurationSec)
    const widthPercent = Math.max(0, Math.min(100, ((this.timelineEndSec - this.timelineStartSec) / total) * 100))
    return `${widthPercent}%`
  }

  private openExportPage(statusText: string): void {
    try {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/Export',
        params: {
          title: this.state.tripTitle,
          statusText: statusText
        }
      })
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('剪辑页', `跳转导出页失败：${message}`)
    }
  }

  private togglePrivacy(type: string, enabled: boolean): void {
    debugLog('剪辑页', `切换隐私开关，类型=${type}，值=${enabled}`)
    this.applyState(this.bridge.updatePrivacy(type, enabled))
    this.showControlsTemporarily()
  }

  private switchCamera(camera: string): void {
    this.applyState(this.bridge.switchCamera(camera))
    this.showPreviewCover = this.state.previewUri.length > 0
    const angle = this.previewRotationAngle(this.state.previewCamera)
    debugLog('剪辑页', `切换播放器视角=${camera}，片段=${this.state.currentClipIndex}/${this.state.currentClipTotal}，旋转角=${angle}`)
    this.showControlsTemporarily()
  }

  private playPrevClip(): void {
    this.applyState(this.bridge.playPrevClip())
    this.playheadSec = this.getCurrentClipStartSec()
    this.state.playheadText = this.bridge.updatePlayhead(this.playheadSec * 1000)
    this.seekAllControllers(0)
    this.showPreviewCover = this.state.previewUri.length > 0
    this.seamlessPendingPlay = false
    debugLog('剪辑页', `切换上一片，当前=${this.state.currentClipIndex}/${this.state.currentClipTotal}`)
    this.showControlsTemporarily()
  }

  private playNextClip(): void {
    this.applyState(this.bridge.playNextClip())
    this.playheadSec = this.getCurrentClipStartSec()
    this.state.playheadText = this.bridge.updatePlayhead(this.playheadSec * 1000)
    this.seekAllControllers(0)
    this.showPreviewCover = this.state.previewUri.length > 0
    this.seamlessPendingPlay = false
    debugLog('剪辑页', `切换下一片，当前=${this.state.currentClipIndex}/${this.state.currentClipTotal}`)
    this.showControlsTemporarily()
  }

  private updatePlayhead(second: number): void {
    const clamped = Math.max(0, Math.min(Math.floor(second), this.state.totalDurationSec))
    this.playheadSec = clamped
    this.applyState(this.bridge.seekGlobalPlayhead(clamped))
    this.state.playheadText = this.bridge.updatePlayhead(this.playheadSec * 1000)
    const localSecond = this.getLocalSecond(this.playheadSec)
    this.seekAllControllers(localSecond)
    if (clamped !== this.lastLoggedSecond) {
      this.lastLoggedSecond = clamped
      debugLog('剪辑页', `拖动全局进度，秒=${clamped}，片段=${this.state.currentClipIndex}/${this.state.currentClipTotal}，片内秒=${localSecond}`)
    }
    this.showControlsTemporarily()
  }

  private updateRangeStart(value: number): void {
    const nextStart = Math.min(Math.floor(value), this.timelineEndSec)
    this.applyState(this.bridge.updateSelectionRange(nextStart, this.timelineEndSec))
    if (this.playheadSec < this.timelineStartSec) {
      this.updatePlayhead(this.timelineStartSec)
    }
    this.showControlsTemporarily()
  }

  private updateRangeEnd(value: number): void {
    const nextEnd = Math.max(Math.floor(value), this.timelineStartSec)
    this.applyState(this.bridge.updateSelectionRange(this.timelineStartSec, nextEnd))
    if (this.playheadSec > this.timelineEndSec) {
      this.updatePlayhead(this.timelineEndSec)
    }
    this.showControlsTemporarily()
  }

  private selectTemplate(card: TemplateCardModel): void {
    this.applyState(this.bridge.selectTemplate(card.id))
    debugLog('剪辑页', `切换模板=${card.id}`)
    this.showControlsTemporarily()
  }

  private toggleDrawer(): void {
    this.applyState(this.bridge.toggleTemplateDrawer(!this.state.drawerExpanded))
  }

  private cycleSpeed(): void {
    this.applyState(this.bridge.cycleSpeed())
    this.applyPlaybackRate()
    debugLog('剪辑诊断', `切换整体倍速=${this.getPlaybackRate()}X`)
    this.showControlsTemporarily()
  }

  private toggleMuted(): void {
    this.applyState(this.bridge.toggleMuted())
    this.showControlsTemporarily()
  }

  private toggleWatermark(): void {
    this.applyState(this.bridge.toggleWatermark())
    this.showControlsTemporarily()
  }

  build() {
    Column({ space: 0 }) {
      Row() {
        Button('返回')
          .type(ButtonType.Capsule)
          .fontSize(12)
          .onClick(() => {
            debugLog('剪辑页', '点击返回')
            try {
              this.getUIContext().getRouter().back()
            } catch (error) {
              const message = error instanceof Error ? error.message : String(error)
              debugLog('剪辑页', `返回失败：${message}`)
            }
          })
        Column({ space: 2 }) {
          Text(this.state.tripTitle)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#F8FAFC')
          Text(this.state.timeRange)
            .fontSize(11)
            .fontColor('#94A3B8')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
        Button('导出')
          .type(ButtonType.Capsule)
          .fontSize(12)
          .onClick(() => {
            this.state.exportStatusText = this.bridge.startExport()
            debugLog('剪辑页', `点击导出，状态=${this.state.exportStatusText}`)
            this.openExportPage(this.state.exportStatusText)
            this.showControlsTemporarily()
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12 })

      Scroll() {
        Stack({ alignContent: Alignment.Center }) {
        if (this.hasPreviewSource()) {
          ForEach(this.state.previewSlots, (slot: PreviewSlotModel) => {
            if (slot.uri.length === 0) {
              Column()
                .width(this.toPercent(slot.width))
                .height(this.toPercent(slot.height))
                .backgroundColor('#0B1220')
                .position({ x: this.toPercent(slot.x), y: this.toPercent(slot.y) })
            } else if (this.isPrimaryPreviewSlot(slot.id)) {
              Video({
                src: slot.uri,
                controller: this.previewController
              })
                .width(this.toPercent(slot.width))
                .height(this.toPercent(slot.height))
                .objectFit(ImageFit.Cover)
                .autoPlay(false)
                .controls(false)
                .position({ x: this.toPercent(slot.x), y: this.toPercent(slot.y) })
                .onPrepared(() => {
                  debugLog('剪辑诊断', `主轨视频准备完成，视角=${slot.camera}`)
                  this.seekAllControllers(this.getLocalSecond(this.playheadSec))
                  if (this.seamlessPendingPlay) {
                    this.seamlessPendingPlay = false
                    this.startAllPreview()
                    this.showPreviewCover = false
                    this.showControlsTemporarily()
                    debugLog('剪辑诊断', `无缝衔接继续播放，片段=${this.state.currentClipIndex}/${this.state.currentClipTotal}`)
                    return
                  }
                  if (this.showPreviewCover) {
                    this.showPreviewCover = false
                    debugLog('剪辑诊断', '首帧就绪，保持自动播放')
                    this.showControlsTemporarily()
                  }
                  if (this.previewPlaying) {
                    this.startAllPreview()
                  } else {
                    this.pauseAllPreview()
                  }
                })
                .onStart(() => {
                  this.showPreviewCover = false
                  this.previewPlaying = true
                  this.showControlsTemporarily()
                  debugLog('剪辑诊断', `主轨开始播放，视角=${slot.camera}`)
                })
                .onPause(() => {
                  this.previewPlaying = false
                  this.showControlsTemporarily()
                  debugLog('剪辑诊断', '主轨视频暂停')
                })
                .onFinish(() => {
                  if (this.state.canPlayNext) {
                    this.applyState(this.bridge.playNextClip())
                    this.playheadSec = this.getCurrentClipStartSec()
                    this.state.playheadText = this.bridge.updatePlayhead(this.playheadSec * 1000)
                    this.showPreviewCover = false
                    this.seamlessPendingPlay = true
                    this.showControlsTemporarily()
                    debugLog('剪辑诊断', `自动切换下一片实现无缝预览，片段=${this.state.currentClipIndex}/${this.state.currentClipTotal}`)
                    return
                  }
                  this.showPreviewCover = true
                  this.showControlsTemporarily()
                  debugLog('剪辑诊断', '主轨播放结束')
                })
                .onError(() => {
                  this.showPreviewCover = true
                  debugLog('剪辑诊断', `主轨视频播放失败，URI长度=${slot.uri.length}`)
                })
                .rotate({ angle: this.previewRotationAngle(slot.camera), x: 0, y: 0, z: 1 })
            } else {
              Video({
                src: slot.uri,
                controller: this.getSecondaryController(slot.id)
              })
                .width(this.toPercent(slot.width))
                .height(this.toPercent(slot.height))
                .objectFit(ImageFit.Cover)
                .autoPlay(false)
                .controls(false)
                .muted(true)
                .position({ x: this.toPercent(slot.x), y: this.toPercent(slot.y) })
                .onPrepared(() => {
                  if (this.previewPlaying) {
                    this.getSecondaryController(slot.id).start()
                  } else {
                    this.getSecondaryController(slot.id).pause()
                  }
                })
            }
            if (this.showSlotLabels) {
              Text(slot.camera)
                .fontSize(10)
                .fontColor('#E2E8F0')
                .backgroundColor('#020617B3')
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(6)
                .position({ x: this.toPercent(slot.x + 0.01), y: this.toPercent(slot.y + 0.01) })
            }
          }, (slot: PreviewSlotModel) => slot.id)
          if (this.state.hideSpeed) {
            Text('SPEED HIDDEN')
              .fontSize(10)
              .fontColor('#FCA5A5')
              .backgroundColor('#7F1D1DB3')
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .borderRadius(6)
              .position({ x: '5%', y: '86%' })
          }
          if (this.state.watermarkEnabled) {
            Text('Shot on AITO')
              .fontSize(10)
              .fontColor('#64748B')
              .position({ x: '76%', y: '92%' })
          }
          if (this.showPreviewCover) {
            Text('加载首帧中...')
              .fontSize(13)
              .fontColor('#CBD5E1')
              .backgroundColor('#00000099')
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(8)
          }
        } else {
          Text('预览区')
            .fontSize(14)
            .fontColor('#CBD5E1')
        }
        }
        .width('100%')
        .aspectRatio(this.getPreviewAspectRatio())
        .backgroundColor('#111827')
        .borderRadius(10)
        .margin({ left: 12, right: 12, top: 6, bottom: 8 })
      }
      .scrollable(this.state.activeTemplateId === 'T4' ? ScrollDirection.Vertical : ScrollDirection.None)
      .scrollBar(BarState.Off)
      .onClick(() => {
        if (this.showPreviewCover && this.hasPreviewSource()) {
          this.startAllPreview()
          this.showPreviewCover = false
        }
        this.showControlsTemporarily()
      })
      .onAppear(() => {
        if (!this.previewLogged) {
          this.previewLogged = true
          debugLog('剪辑诊断', `预览组件已渲染，占位模式=${this.state.previewUri.length > 0 ? '否' : '是'}，预览URI长度=${this.state.previewUri.length}，行程=${this.state.tripId}`)
        }
      })
      .width('100%')
      .layoutWeight(this.state.layers[0]?.heightRatio ?? 0.5)

      Row({ space: 10 }) {
        if (!this.isMergedTrip()) {
          Button('上一个')
            .type(ButtonType.Capsule)
            .fontSize(11)
            .enabled(this.state.canPlayPrev)
            .onClick(() => this.playPrevClip())
          Button('下一个')
            .type(ButtonType.Capsule)
            .fontSize(11)
            .enabled(this.state.canPlayNext)
            .onClick(() => this.playNextClip())
        } else {
          Text('连续预览')
            .fontSize(11)
            .fontColor('#94A3B8')
        }
        Button(this.previewPlaying ? '暂停预览' : '播放预览')
          .type(ButtonType.Capsule)
          .fontSize(11)
          .onClick(() => this.togglePreviewPlay())
        Button(this.showSlotLabels ? '隐藏视角' : '显示视角')
          .type(ButtonType.Capsule)
          .fontSize(11)
          .onClick(() => this.toggleSlotLabels())
        Blank()
        Text(this.state.playheadText)
          .fontSize(12)
          .fontColor('#CBD5E1')
        Blank()
        Button(this.state.speedLabel)
          .type(ButtonType.Capsule)
          .fontSize(11)
          .onClick(() => this.cycleSpeed())
        Button(this.state.muted ? '已静音' : '静音')
          .type(ButtonType.Capsule)
          .fontSize(11)
          .onClick(() => this.toggleMuted())
      }
      .width('100%')
      .layoutWeight(this.state.layers[1]?.heightRatio ?? 0.12)
      .padding({ left: 12, right: 12, top: 4, bottom: 4 })
      .backgroundColor('#0F172A')

      Column({ space: 2 }) {
        Row() {
          Text(`逻辑选区 ${this.timelineStartSec}s - ${this.timelineEndSec}s`)
            .fontSize(11)
            .fontColor('#94A3B8')
          Blank()
          Text(`全局进度 ${this.playheadSec}s / ${this.state.totalDurationSec}s`)
            .fontSize(11)
            .fontColor('#64748B')
        }
        .width('100%')
          .padding({ left: 12, right: 12, top: 2 })
        Stack({ alignContent: Alignment.Center }) {
          Row()
            .width('100%')
            .height('100%')
            .backgroundColor('#02061766')
          Row()
            .width(this.getRangeWidthPercent())
            .height('100%')
            .backgroundColor('#F9731626')
            .position({ x: this.getRangeStartPercent(), y: '0%' })
          Column()
            .width(18)
            .height('86%')
            .backgroundColor('#F97316')
            .borderRadius(10)
            .position({ x: this.getRangeStartPercent(), y: '7%' })
          Column()
            .width(18)
            .height('86%')
            .backgroundColor('#F97316')
            .borderRadius(10)
            .position({ x: this.getRangeEndPercent(), y: '7%' })
          Row({ space: 2 }) {
            ForEach(this.state.boundaryMarkers, (marker: TimelineMarkerModel) => {
              Text('|')
                .fontSize(12)
                .fontColor('#334155')
                .width('100%')
            }, (marker: TimelineMarkerModel, index: number) => `${marker.positionSec}-${index}`)
          }
          .width('100%')
          .justifyContent(FlexAlign.SpaceBetween)
          Slider({
            value: this.timelineStartSec,
            min: 0,
            max: this.state.totalDurationSec,
            step: 1,
            style: SliderStyle.OutSet
          })
            .blockColor('#F97316')
            .selectedColor('#F97316')
            .onChange((value: number) => this.updateRangeStart(value))
            .width('100%')
          Slider({
            value: this.timelineEndSec,
            min: 0,
            max: this.state.totalDurationSec,
            step: 1,
            style: SliderStyle.OutSet
          })
            .blockColor('#F97316')
            .selectedColor('#F97316')
            .onChange((value: number) => this.updateRangeEnd(value))
            .width('100%')
          Slider({
            value: this.playheadSec,
            min: 0,
            max: this.state.totalDurationSec,
            step: 1,
            style: SliderStyle.OutSet
          })
            .blockColor('#FFFFFF')
            .selectedColor('#FFFFFF')
            .onChange((value: number) => this.updatePlayhead(value))
            .width('100%')
            .padding({ left: 4, right: 4 })
        }
        .height(70)
        .margin({ left: 12, right: 12, top: 2, bottom: 2 })
        .backgroundColor('#0B1220')
        .borderRadius(8)
      }
      .layoutWeight(this.state.layers[2]?.heightRatio ?? 0.16)
      .width('100%')
      .backgroundColor('#0F172A')

      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Toggle({ type: ToggleType.Checkbox, isOn: this.state.hideSpeed })
            .onChange((value: boolean) => this.togglePrivacy('speed', value))
          Text('车速')
            .fontSize(11)
            .fontColor('#CBD5E1')
          Toggle({ type: ToggleType.Checkbox, isOn: this.state.hideGps })
            .onChange((value: boolean) => this.togglePrivacy('gps', value))
          Text('GPS')
            .fontSize(11)
            .fontColor('#CBD5E1')
          Toggle({ type: ToggleType.Checkbox, isOn: this.state.hideVin })
            .onChange((value: boolean) => this.togglePrivacy('vin', value))
          Text('VIN')
            .fontSize(11)
            .fontColor('#CBD5E1')
          Blank()
          Button(this.state.watermarkEnabled ? '尾标开' : '尾标关')
            .type(ButtonType.Capsule)
            .fontSize(10)
            .onClick(() => this.toggleWatermark())
          Button(this.state.drawerExpanded ? '收起' : '展开')
            .type(ButtonType.Capsule)
            .fontSize(10)
            .onClick(() => this.toggleDrawer())
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 6 })
        if (this.state.drawerExpanded) {
          Scroll() {
            Row({ space: 8 }) {
              ForEach(this.state.templateCards, (card: TemplateCardModel) => {
                Column({ space: 4 }) {
                  Text(card.title)
                    .fontSize(12)
                    .fontColor(card.id === this.state.activeTemplateId ? '#FB923C' : '#CBD5E1')
                  Text(card.subtitle)
                    .fontSize(10)
                    .fontColor(card.id === this.state.activeTemplateId ? '#FB923C' : '#64748B')
                }
                .width(84)
                .height(72)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(card.id === this.state.activeTemplateId ? '#1E293B' : '#0B1220')
                .borderRadius(10)
                .border({
                  width: card.id === this.state.activeTemplateId ? 2 : 1,
                  color: card.id === this.state.activeTemplateId ? '#F97316' : '#334155'
                })
                .scale({
                  x: card.id === this.state.activeTemplateId ? 1.03 : 1,
                  y: card.id === this.state.activeTemplateId ? 1.03 : 1
                })
                .onClick(() => this.selectTemplate(card))
              }, (card: TemplateCardModel) => card.id)
            }
            .padding({ left: 12, right: 12, bottom: 8 })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
        }
        List({ space: 4 }) {
          ForEach(this.state.timeline, (track: TimelineTrackModel) => {
            ListItem() {
              Row() {
                Text(track.cameraPosition)
                  .fontSize(11)
                  .fontColor(track.cameraPosition === this.state.previewCamera ? '#60A5FA' : '#CBD5E1')
                Blank()
                Text(`片段 ${track.segmentCount}`)
                  .fontSize(10)
                  .fontColor(track.degraded ? '#F59E0B' : '#64748B')
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 8, bottom: 8 })
              .backgroundColor('#111827')
              .borderRadius(8)
              .onClick(() => this.switchCamera(track.cameraPosition))
            }
          }, (track: TimelineTrackModel, index: number) => `${track.cameraPosition}-${index}`)
        }
        .onAppear(() => {
          if (!this.timelineLogged) {
            this.timelineLogged = true
            const trackSummary = this.state.timeline.map((item: TimelineTrackModel) => `${item.cameraPosition}:${item.segmentCount}`).join(',')
            debugLog('剪辑诊断', `时间轴渲染完成，轨道数=${this.state.timeline.length}，轨道明细=${trackSummary}`)
          }
        })
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 12, right: 12 })

        Text(`导出状态：${this.state.exportStatusText}`)
          .fontSize(11)
          .fontColor('#60A5FA')
          .width('100%')
          .padding({ left: 12, right: 12, bottom: 8 })
      }
      .layoutWeight(this.state.layers[3]?.heightRatio ?? 0.22)
      .width('100%')
      .backgroundColor('#020617')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0F172A')
  }
}
