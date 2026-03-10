import { sharedCoreBridge } from '../bridge/CoreBridge'
import { EditorStateModel, TemplateCardModel, TimelineMarkerModel, TimelineTrackModel } from '../model/AppState'
import { debugLog } from '../utils/Logger'

@Entry
@Component
struct Editor {
  private bridge = sharedCoreBridge
  private previewController: VideoController = new VideoController()
  private controlsTimer: number = -1
  private exportPollTimer: number = -1
  private lastLoggedSecond: number = -1
  private previewLogged: boolean = false
  private timelineLogged: boolean = false
  @State private showPlayerControls: boolean = true
  @State private showPreviewCover: boolean = true
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
    this.playheadSec = Math.max(nextState.selectionStartSec, Math.min(this.playheadSec, nextState.selectionEndSec))
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
    this.showPlayerControls = true
    this.scheduleHideControls()
    const trackSummary = this.state.timeline.map((item: TimelineTrackModel) => `${item.cameraPosition}:${item.segmentCount}`).join(',')
    debugLog('剪辑诊断', `初始化完成，时长=${this.state.totalDurationSec}s，轨道数=${this.state.timeline.length}，轨道明细=${trackSummary}，预览URI长度=${this.state.previewUri.length}，预览视角=${this.state.previewCamera}`)
  }

  aboutToDisappear(): void {
    this.clearHideControlsTimer()
    this.clearExportPollTimer()
  }

  private clearHideControlsTimer(): void {
    if (this.controlsTimer >= 0) {
      clearTimeout(this.controlsTimer)
      this.controlsTimer = -1
    }
  }

  private clearExportPollTimer(): void {
    if (this.exportPollTimer >= 0) {
      clearInterval(this.exportPollTimer)
      this.exportPollTimer = -1
    }
  }

  private startExportPoll(): void {
    this.clearExportPollTimer()
    this.exportPollTimer = setInterval(() => {
      const latestStatus = this.bridge.getExportStatusText()
      if (latestStatus === this.state.exportStatusText) {
        return
      }
      this.state.exportStatusText = latestStatus
      if (latestStatus.includes('导出完成') || latestStatus.includes('导出失败')) {
        this.clearExportPollTimer()
      }
    }, 300)
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
    this.showPreviewCover = this.state.previewUri.length > 0
    debugLog('剪辑页', `切换上一片，当前=${this.state.currentClipIndex}/${this.state.currentClipTotal}`)
    this.showControlsTemporarily()
  }

  private playNextClip(): void {
    this.applyState(this.bridge.playNextClip())
    this.showPreviewCover = this.state.previewUri.length > 0
    debugLog('剪辑页', `切换下一片，当前=${this.state.currentClipIndex}/${this.state.currentClipTotal}`)
    this.showControlsTemporarily()
  }

  private updatePlayhead(second: number): void {
    const clamped = Math.max(this.timelineStartSec, Math.min(Math.floor(second), this.timelineEndSec))
    this.playheadSec = clamped
    this.state.playheadText = this.bridge.updatePlayhead(clamped * 1000)
    if (clamped !== this.lastLoggedSecond) {
      this.lastLoggedSecond = clamped
      debugLog('剪辑页', `拖动进度，秒=${clamped}，文案=${this.state.playheadText}`)
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
            this.startExportPoll()
            this.showControlsTemporarily()
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12 })

      Stack({ alignContent: Alignment.Center }) {
        if (this.state.previewUri.length > 0) {
          Video({
            src: this.state.previewUri,
            controller: this.previewController
          })
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
            .autoPlay(false)
            .controls(this.showPlayerControls && !this.showPreviewCover)
            .onPrepared(() => {
              debugLog('剪辑诊断', `视频准备完成，预览视角=${this.state.previewCamera}`)
              if (this.showPreviewCover) {
                this.previewController.start()
                setTimeout(() => {
                  this.previewController.pause()
                  this.showPreviewCover = false
                  debugLog('剪辑诊断', '首帧预加载完成')
                  this.showControlsTemporarily()
                }, 120)
              }
            })
            .onStart(() => {
              this.showPreviewCover = false
              this.showControlsTemporarily()
              debugLog('剪辑诊断', `视频开始播放，视角=${this.state.previewCamera}`)
            })
            .onPause(() => {
              this.showControlsTemporarily()
              debugLog('剪辑诊断', '视频暂停')
            })
            .onFinish(() => {
              this.showPreviewCover = true
              this.showControlsTemporarily()
              debugLog('剪辑诊断', '视频播放结束')
            })
            .onError(() => {
              this.showPreviewCover = true
              debugLog('剪辑诊断', `视频播放失败，URI长度=${this.state.previewUri.length}`)
            })
            .rotate({ angle: this.previewRotationAngle(this.state.previewCamera), x: 0, y: 0, z: 1 })
          if (this.state.activeTemplateId === 'T2') {
            Stack({ alignContent: Alignment.Center }) {
              Text('REAR')
                .fontSize(10)
                .fontWeight(FontWeight.Bold)
                .fontColor('#94A3B8')
            }
            .width('28%')
            .height('24%')
            .backgroundColor('#111827')
            .borderRadius(8)
            .border({ width: 1, color: '#334155' })
            .position({ x: '68%', y: '8%' })
          }
          if (this.state.hideSpeed) {
            Text('SPEED HIDDEN')
              .fontSize(10)
              .fontColor('#FCA5A5')
              .backgroundColor('#7F1D1D88')
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
              .backgroundColor('#00000066')
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(8)
          }
        } else {
          Text('预览区')
            .fontSize(14)
            .fontColor('#CBD5E1')
        }
      }
      .onClick(() => {
        if (this.showPreviewCover && this.state.previewUri.length > 0) {
          this.previewController.start()
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
      .backgroundColor('#111827')
      .borderRadius(10)
      .margin({ left: 12, right: 12, top: 6, bottom: 8 })

      Row({ space: 10 }) {
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
          Text(`当前片段 ${this.state.currentClipIndex}/${this.state.currentClipTotal}`)
            .fontSize(11)
            .fontColor('#64748B')
        }
        .width('100%')
          .padding({ left: 12, right: 12, top: 2 })
        Stack({ alignContent: Alignment.Center }) {
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
            min: this.timelineStartSec,
            max: this.timelineEndSec,
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
