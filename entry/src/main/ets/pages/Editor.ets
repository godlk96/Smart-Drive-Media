import router from '@ohos.router'
import { sharedCoreBridge } from '../bridge/CoreBridge'
import { EditorStateModel, TimelineTrackModel } from '../model/AppState'
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
  @State private fullScreen: boolean = false
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
    hideSpeed: true,
    hideGps: true,
    hideVin: true,
    exportStatusText: '待导出'
  }

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, string>
    const tripId = params?.tripId ?? 'trip-demo-1'
    const title = params?.title ?? ''
    const subtitle = params?.subtitle ?? ''
    debugLog('剪辑页', `进入页面，行程ID=${tripId}，标题提示=${title}，副标题提示=${subtitle}`)
    this.state = this.bridge.createEditorState(tripId, title, subtitle)
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
      this.state = {
        tripId: this.state.tripId,
        tripTitle: this.state.tripTitle,
        timeRange: this.state.timeRange,
        previewUri: this.state.previewUri,
        previewCamera: this.state.previewCamera,
        canPlayPrev: this.state.canPlayPrev,
        canPlayNext: this.state.canPlayNext,
        currentClipIndex: this.state.currentClipIndex,
        currentClipTotal: this.state.currentClipTotal,
        playheadText: this.state.playheadText,
        totalDurationSec: this.state.totalDurationSec,
        timeline: this.state.timeline,
        hideSpeed: this.state.hideSpeed,
        hideGps: this.state.hideGps,
        hideVin: this.state.hideVin,
        exportStatusText: latestStatus
      }
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
    this.state = this.bridge.updatePrivacy(type, enabled)
    this.showControlsTemporarily()
  }

  private switchCamera(camera: string): void {
    this.state = this.bridge.switchCamera(camera)
    this.showPreviewCover = this.state.previewUri.length > 0
    const angle = this.previewRotationAngle(this.state.previewCamera)
    debugLog('剪辑页', `切换播放器视角=${camera}，片段=${this.state.currentClipIndex}/${this.state.currentClipTotal}，旋转角=${angle}`)
    this.showControlsTemporarily()
  }

  private playPrevClip(): void {
    this.state = this.bridge.playPrevClip()
    this.showPreviewCover = this.state.previewUri.length > 0
    debugLog('剪辑页', `切换上一片，当前=${this.state.currentClipIndex}/${this.state.currentClipTotal}`)
    this.showControlsTemporarily()
  }

  private playNextClip(): void {
    this.state = this.bridge.playNextClip()
    this.showPreviewCover = this.state.previewUri.length > 0
    debugLog('剪辑页', `切换下一片，当前=${this.state.currentClipIndex}/${this.state.currentClipTotal}`)
    this.showControlsTemporarily()
  }

  build() {
    Column({ space: 8 }) {
      Row() {
        Button('返回')
          .type(ButtonType.Capsule)
          .fontSize(12)
          .onClick(() => {
            debugLog('剪辑页', '点击返回')
            router.back()
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
            this.state = {
              tripId: this.state.tripId,
              tripTitle: this.state.tripTitle,
              timeRange: this.state.timeRange,
              previewUri: this.state.previewUri,
              previewCamera: this.state.previewCamera,
              canPlayPrev: this.state.canPlayPrev,
              canPlayNext: this.state.canPlayNext,
              currentClipIndex: this.state.currentClipIndex,
              currentClipTotal: this.state.currentClipTotal,
              playheadText: this.state.playheadText,
              totalDurationSec: this.state.totalDurationSec,
              timeline: this.state.timeline,
              hideSpeed: this.state.hideSpeed,
              hideGps: this.state.hideGps,
              hideVin: this.state.hideVin,
              exportStatusText: this.bridge.startExport()
            }
            debugLog('剪辑页', `点击导出，状态=${this.state.exportStatusText}`)
            this.startExportPoll()
            this.showControlsTemporarily()
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12 })

      Text(`导出状态：${this.state.exportStatusText}`)
        .fontSize(12)
        .fontColor('#60A5FA')
        .width('100%')
        .padding({ left: 12, right: 12, top: 2, bottom: 2 })

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
      .height(this.fullScreen ? '58%' : '32%')
      .backgroundColor('#111827')
      .borderRadius(10)
      .margin({ left: 12, right: 12, top: 4 })

      Row() {
        Text(`当前片段 ${this.state.currentClipIndex}/${this.state.currentClipTotal}`)
          .fontSize(11)
          .fontColor('#94A3B8')
        Blank()
        Button(this.fullScreen ? '退出全屏' : '全屏')
          .type(ButtonType.Capsule)
          .fontSize(11)
          .onClick(() => {
            this.fullScreen = !this.fullScreen
            this.showControlsTemporarily()
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 2 })

      Row({ space: 8 }) {
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
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 2 })

      Row({ space: 10 }) {
        Toggle({ type: ToggleType.Checkbox, isOn: this.state.hideSpeed })
          .onChange((value: boolean) => this.togglePrivacy('speed', value))
        Text('车速')
          .fontSize(12)
          .fontColor('#CBD5E1')
        Toggle({ type: ToggleType.Checkbox, isOn: this.state.hideGps })
          .onChange((value: boolean) => this.togglePrivacy('gps', value))
        Text('GPS')
          .fontSize(12)
          .fontColor('#CBD5E1')
        Toggle({ type: ToggleType.Checkbox, isOn: this.state.hideVin })
          .onChange((value: boolean) => this.togglePrivacy('vin', value))
        Text('VIN码')
          .fontSize(12)
          .fontColor('#CBD5E1')
      }
      .width('100%')
      .padding({ left: 12, right: 12 })

      Text(this.state.playheadText)
        .fontSize(12)
        .fontColor('#94A3B8')
        .width('100%')
        .padding({ left: 12, right: 12 })

      Slider({
        value: 0,
        min: 0,
        max: this.state.totalDurationSec,
        step: 1,
        style: SliderStyle.OutSet
      })
        .onChange((value: number) => {
          this.state = {
            tripId: this.state.tripId,
            tripTitle: this.state.tripTitle,
            timeRange: this.state.timeRange,
            previewUri: this.state.previewUri,
            previewCamera: this.state.previewCamera,
            canPlayPrev: this.state.canPlayPrev,
            canPlayNext: this.state.canPlayNext,
            currentClipIndex: this.state.currentClipIndex,
            currentClipTotal: this.state.currentClipTotal,
            playheadText: this.bridge.updatePlayhead(value * 1000),
            totalDurationSec: this.state.totalDurationSec,
            timeline: this.state.timeline,
            hideSpeed: this.state.hideSpeed,
            hideGps: this.state.hideGps,
            hideVin: this.state.hideVin,
            exportStatusText: this.state.exportStatusText
          }
          const second = Math.floor(value)
          if (second !== this.lastLoggedSecond) {
            this.lastLoggedSecond = second
            debugLog('剪辑页', `拖动进度，秒=${second}，文案=${this.state.playheadText}`)
          }
          this.showControlsTemporarily()
        })
        .width('100%')
        .padding({ left: 12, right: 12 })

      List({ space: 6 }) {
        ForEach(this.state.timeline, (track: TimelineTrackModel) => {
          ListItem() {
            Row() {
              Text(track.cameraPosition)
                .fontSize(12)
                .fontColor(track.cameraPosition === this.state.previewCamera ? '#60A5FA' : '#CBD5E1')
              Blank()
              Text(`片段 ${track.segmentCount}`)
                .fontSize(11)
                .fontColor(track.degraded ? '#F59E0B' : '#94A3B8')
            }
            .width('100%')
            .padding(10)
            .backgroundColor('#1E293B')
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

      Text(this.state.exportStatusText)
        .fontSize(12)
        .fontColor('#3B82F6')
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 12 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0F172A')
  }
}
