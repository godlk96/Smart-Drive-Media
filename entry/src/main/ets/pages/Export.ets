import { sharedCoreBridge } from '../bridge/CoreBridge'
import { debugLog } from '../utils/Logger'

@Entry
@Component
struct Export {
  private bridge = sharedCoreBridge
  private pollTimer: number = -1
  @State private tripTitle: string = '导出中'
  @State private statusText: string = '导出处理中 0%'
  @State private progress: number = 0
  @State private remainingText: string = '预计剩余：--'
  @State private isSuccess: boolean = false
  @State private isFailed: boolean = false

  aboutToAppear(): void {
    let params: Record<string, string> = {}
    try {
      params = this.getUIContext().getRouter().getParams() as Record<string, string>
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('导出页', `读取路由参数失败：${message}`)
    }
    this.tripTitle = params.title ?? '导出中'
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
      this.remainingText = '预计剩余：0s'
      return
    }
    if (this.isFailed) {
      this.remainingText = '请返回重试'
      return
    }
    const progressMatch = status.match(/(\d+)%/)
    if (!progressMatch) {
      this.remainingText = '预计剩余：--'
      return
    }
    const nextProgress = Number.parseInt(progressMatch[1] ?? '0')
    const normalized = Math.max(0, Math.min(100, Number.isFinite(nextProgress) ? nextProgress : 0))
    this.progress = normalized
    const remainSec = Math.max(1, Math.round((100 - normalized) / 5))
    this.remainingText = `预计剩余：${remainSec}s`
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

  private shareToWeChat(): void {
    debugLog('导出页', `点击分享，状态=${this.statusText}`)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 10 }) {
        Row()
          .width('88%')
          .height(14)
          .borderRadius(7)
          .backgroundColor('#1E293B')
        Row()
          .width('92%')
          .height(168)
          .borderRadius(14)
          .backgroundColor('#0F172A')
        Row()
          .width('84%')
          .height(12)
          .borderRadius(6)
          .backgroundColor('#1E293B')
        Row()
          .width('78%')
          .height(12)
          .borderRadius(6)
          .backgroundColor('#1E293B')
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor('#020617')
      .opacity(0.45)
      .blur(18)

      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#02061799')

      Column({ space: 18 }) {
        if (!this.isSuccess && !this.isFailed) {
          LoadingProgress()
            .color('#F97316')
            .width(72)
            .height(72)
          Column({ space: 6 }) {
            Text('视频导出中...')
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
            Text('正在应用隐私遮罩并渲染模板。')
              .fontSize(13)
              .fontColor('#94A3B8')
          }
          Stack({ alignContent: Alignment.Start }) {
            Row()
              .width('100%')
              .height(8)
              .borderRadius(10)
              .backgroundColor('#1E293B')
            Row()
              .width(`${this.progress}%`)
              .height(8)
              .borderRadius(10)
              .backgroundColor('#F97316')
          }
          .width('100%')
          Text(this.remainingText)
            .fontSize(12)
            .fontColor('#64748B')
        } else if (this.isSuccess) {
          Text('✓')
            .fontSize(42)
            .fontColor('#22C55E')
            .width(92)
            .height(92)
            .textAlign(TextAlign.Center)
            .borderRadius(46)
            .backgroundColor('#052E16')
          Column({ space: 6 }) {
            Text('导出完成')
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
            Text('视频已保存到相册。')
              .fontSize(13)
              .fontColor('#94A3B8')
          }
          Button('分享至微信')
            .width('100%')
            .height(44)
            .backgroundColor('#EA580C')
            .fontColor('#FFFFFF')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .borderRadius(12)
            .onClick(() => this.shareToWeChat())
          Button('返回行程库')
            .width('100%')
            .height(44)
            .backgroundColor('#1E293B')
            .fontColor('#CBD5E1')
            .fontSize(14)
            .borderRadius(12)
            .onClick(() => this.backToLibrary())
        } else {
          Text('!')
            .fontSize(42)
            .fontColor('#EF4444')
            .width(92)
            .height(92)
            .textAlign(TextAlign.Center)
            .borderRadius(46)
            .backgroundColor('#450A0A')
          Column({ space: 6 }) {
            Text('导出失败')
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
            Text(this.statusText)
              .fontSize(12)
              .fontColor('#FCA5A5')
              .maxLines(3)
          }
          Button('返回剪辑页')
            .width('100%')
            .height(44)
            .backgroundColor('#334155')
            .fontColor('#FFFFFF')
            .fontSize(14)
            .borderRadius(12)
            .onClick(() => this.backToEditor())
        }
      }
      .width('92%')
      .padding({ left: 20, right: 20, top: 28, bottom: 24 })
      .backgroundColor('#0F172ACC')
      .borderRadius(20)
      .border({ width: 1, color: '#334155' })

      Text(this.tripTitle)
        .fontSize(12)
        .fontColor('#64748B')
        .margin({ top: 12 })
      .position({ y: '76%' })
    }
    .width('100%')
    .height('100%')
  }
}
