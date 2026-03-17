import { sharedCoreBridge } from '../bridge/CoreBridge'
import { debugLog } from '../utils/Logger'

@Entry
@Component
struct Export {
  private bridge = sharedCoreBridge
  private pollTimer: number = -1
  @State private pageTitle: string = '导出单组视频'
  @State private statusText: string = '导出处理中 0%'
  @State private progress: number = 0
  @State private isSuccess: boolean = false
  @State private isFailed: boolean = false
  @State private showCancelModal: boolean = false
  @State private templateName: string = '单视角'
  @State private resolution: string = '1920×1080'
  @State private contentInfo: string = '单组视频 | 裁剪后时长60秒'

  aboutToAppear(): void {
    let params: Record<string, string> = {}
    try {
      params = this.getUIContext().getRouter().getParams() as Record<string, string>
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('导出页', `读取路由参数失败：${message}`)
    }
    const type = params.type ?? 'single'
    if (type === 'merge') {
      this.pageTitle = '导出合并视频'
      this.contentInfo = '多组合并 | 裁剪后时长120秒'
    } else {
      this.pageTitle = '导出单组视频'
      this.contentInfo = '单组视频 | 裁剪后时长60秒'
    }
    if ((params.title ?? '').length > 0) {
      this.pageTitle = params.title ?? this.pageTitle
    }
    if ((params.templateName ?? '').length > 0) {
      this.templateName = params.templateName ?? this.templateName
    }
    if ((params.resolution ?? '').length > 0) {
      this.resolution = params.resolution ?? this.resolution
    }
    const routeStatus = params.statusText ?? ''
    const initialStatus = routeStatus.length > 0 ? routeStatus : this.bridge.getExportStatusText()
    this.applyStatus(initialStatus)
    this.startPoll()
  }

  aboutToDisappear(): void {
    this.clearPollTimer()
  }

  private clearPollTimer(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer)
      this.pollTimer = -1
    }
  }

  private startPoll(): void {
    this.clearPollTimer()
    this.pollTimer = setInterval(() => {
      const latestStatus = this.bridge.getExportStatusText()
      if (latestStatus === this.statusText) {
        return
      }
      this.applyStatus(latestStatus)
      if (this.isSuccess || this.isFailed) {
        this.clearPollTimer()
      }
    }, 300)
  }

  private applyStatus(status: string): void {
    this.statusText = status
    this.isSuccess = status.includes('导出完成')
    this.isFailed = status.includes('导出失败')
    if (this.isSuccess) {
      this.progress = 100
      return
    }
    if (this.isFailed) {
      return
    }
    const progressMatch = status.match(/(\d+)%/)
    if (!progressMatch) {
      return
    }
    const nextProgress = Number.parseInt(progressMatch[1] ?? '0')
    const normalized = Math.max(0, Math.min(100, Number.isFinite(nextProgress) ? nextProgress : 0))
    this.progress = normalized
  }

  private getDisplayStatusText(): string {
    if (this.isSuccess) {
      return '导出完成！'
    }
    if (this.isFailed) {
      return '导出失败'
    }
    return '导出中...'
  }

  private getEstimatedTimeText(): string {
    if (this.isSuccess || this.isFailed) {
      return ''
    }
    const remaining = Math.ceil((100 - this.progress) * 0.6)
    return `预估剩余：${Math.max(0, remaining)}秒`
  }

  private openCancelModal(): void {
    if (this.isSuccess || this.isFailed) {
      return
    }
    this.showCancelModal = true
  }

  private closeCancelModal(): void {
    this.showCancelModal = false
  }

  private confirmCancelExport(): void {
    this.showCancelModal = false
    this.backToEditor()
  }

  private backToLibrary(): void {
    try {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/Index',
        params: {}
      })
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('导出页', `返回行程库失败：${message}`)
    }
  }

  private backToEditor(): void {
    try {
      this.getUIContext().getRouter().back()
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('导出页', `返回剪辑页失败：${message}`)
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Row() {
          Text('← 返回')
            .fontSize(16)
            .fontColor('#666666')
            .padding(8)
          Text(this.pageTitle)
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
          Row()
            .width(60)
      }
      .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
        .padding({ top: 16, bottom: 16 })

        Column({ space: 0 }) {
          Text(this.getDisplayStatusText())
            .fontSize(24)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .textAlign(TextAlign.Center)
            .width('100%')
            .margin({ bottom: 40 })

          Column({ space: 0 }) {
            Stack({ alignContent: Alignment.Start }) {
              Row()
                .width('100%')
                .height(8)
                .borderRadius(4)
                .backgroundColor('#333333')
              Row()
                .width(`${this.progress}%`)
                .height(8)
                .borderRadius(4)
                .backgroundColor('#0A59F7')
            }
            .width('100%')
            .margin({ bottom: 12 })
            Row() {
              Text(`${this.progress}%`)
                .fontSize(14)
                .fontColor('#999999')
              Text(this.getEstimatedTimeText())
                .fontSize(14)
                .fontColor('#999999')
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
          }
          .width('100%')
          .margin({ bottom: 24 })

          Column({ space: 8 }) {
            Row() {
              Text('模板：')
                .fontSize(14)
                .fontColor('#999999')
              Text(this.templateName)
                .fontSize(14)
                .fontColor('#FFFFFF')
            }
            Row() {
              Text('分辨率：')
                .fontSize(14)
                .fontColor('#999999')
              Text(this.resolution)
                .fontSize(14)
                .fontColor('#FFFFFF')
            }
            Row() {
              Text('内容：')
                .fontSize(14)
                .fontColor('#999999')
              Text(this.contentInfo)
                .fontSize(14)
                .fontColor('#FFFFFF')
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor('#282828')
          .borderRadius(12)
          .margin({ bottom: 40 })

          Column({ space: 0 }) {
            if (!this.isSuccess && !this.isFailed) {
              Button('取消导出')
                .width('100%')
                .height(56)
                .backgroundColor('#333333')
                .fontColor('#FFFFFF')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .borderRadius(8)
                .onClick(() => this.openCancelModal())
            } else if (this.isSuccess) {
              Button('返回列表')
                .width('100%')
                .height(56)
                .backgroundColor('#FF7A00')
                .fontColor('#FFFFFF')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .borderRadius(8)
                .onClick(() => this.backToLibrary())
            } else {
              Button('返回剪辑页')
                .width('100%')
                .height(56)
                .backgroundColor('#0A59F7')
                .fontColor('#FFFFFF')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .borderRadius(8)
                .onClick(() => this.backToEditor())
              Text(this.statusText)
                .fontSize(13)
                .fontColor('#999999')
                .textAlign(TextAlign.Center)
                .width('100%')
                .margin({ top: 12 })
            }
          }
          .width('100%')
          .margin({ bottom: 24 })

          Text('导出完成后将自动保存到本地相册')
            .fontSize(14)
            .fontColor('#666666')
            .textAlign(TextAlign.Center)
            .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16 })
      .backgroundColor('#181818')

      if (this.showCancelModal) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#B3000000')
        Column({ space: 0 }) {
          Text('确认取消导出？')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .textAlign(TextAlign.Center)
            .width('100%')
            .margin({ bottom: 12 })
          Text('取消导出将丢失当前进度')
            .fontSize(14)
            .fontColor('#999999')
            .textAlign(TextAlign.Center)
            .width('100%')
            .margin({ bottom: 24 })
          Row({ space: 12 }) {
            Button('继续导出')
              .layoutWeight(1)
              .height(48)
              .backgroundColor('#333333')
              .fontColor('#FFFFFF')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .borderRadius(8)
              .onClick(() => this.closeCancelModal())
            Button('取消')
              .layoutWeight(1)
              .height(48)
              .backgroundColor('#0A59F7')
              .fontColor('#FFFFFF')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .borderRadius(8)
              .onClick(() => this.confirmCancelExport())
          }
          .width('100%')
        }
        .width('82%')
        .padding(24)
        .backgroundColor('#282828')
        .borderRadius(16)
        .position({ x: '9%', y: '38%' })
      }
    }
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
  }
}
