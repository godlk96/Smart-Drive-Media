import { Segment, segmentDurationSec } from '../model/SegmentModel'

/**
 * 片段轨道（spec §6.6）：段块按各自时长占宽、段间 3vp 缝。
 * 选中段只换 1.5vp 琥珀描边 + 两端竖向手柄，不铺底色（spec D11）；灰段加删除线。
 * 点段块 = 选中该段（含灰段 —— 灰段要能被选中才能用 ✕ 点回来，spec D13）。
 */
@Component
export struct SegmentTrack {
  @Prop segments: Array<Segment> = []
  @Prop totalDurationSec: number = 0
  @Prop selectedSegmentId: number = -1
  onSelectSegment?: (id: number) => void

  private isSelected(segment: Segment): boolean {
    return segment.enabled && segment.id === this.selectedSegmentId
  }

  /**
   * ForEach 的键必须带上所有影响渲染的字段：`segments` 每次都是新数组，
   * 但键不变时 ArkUI 会复用旧节点而不会刷新内容（Segment 是纯类，不能挂 @Observed）。
   */
  private blockKey(segment: Segment): string {
    return `${segment.id}-${segment.startSec}-${segment.endSec}-${segment.speedLabel}-${segment.muted}-${segment.enabled}-${this.isSelected(segment)}`
  }

  @Builder
  handles() {
    Row() {
      Row()
        .width(6)
        .height(44)
        .borderRadius(3)
        .backgroundColor($r('app.color.amber'))
        .offset({ x: -4 })
      Blank()
      Row()
        .width(6)
        .height(44)
        .borderRadius(3)
        .backgroundColor($r('app.color.amber'))
        .offset({ x: 4 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  segmentBlock(segment: Segment) {
    Stack({ alignContent: Alignment.Center }) {
      Text(`片段 ${segment.id + 1}`)
        .fontSize(12)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
        .fontColor(segment.enabled
          ? (this.isSelected(segment) ? $r('app.color.amber_deep') : $r('app.color.text_secondary'))
          : $r('app.color.text_disabled'))
        .decoration(segment.enabled
          ? { type: TextDecorationType.None }
          : { type: TextDecorationType.LineThrough, color: $r('app.color.text_disabled') })
      if (this.isSelected(segment)) {
        this.handles()
      }
    }
    .layoutWeight(segmentDurationSec(segment))
    .height('100%')
    .borderRadius(7)
    .borderWidth(this.isSelected(segment) ? 1.5 : 1)
    .borderColor(segment.enabled
      ? (this.isSelected(segment) ? $r('app.color.amber') : $r('app.color.segment_border'))
      : $r('app.color.segment_off_border'))
    .backgroundColor(segment.enabled ? $r('app.color.card_bg') : $r('app.color.segment_off_bg'))
    .onClick(() => {
      if (this.onSelectSegment) {
        this.onSelectSegment(segment.id)
      }
    })
  }

  build() {
    Row({ space: 3 }) {
      ForEach(this.segments, (segment: Segment) => {
        this.segmentBlock(segment)
      }, (segment: Segment) => this.blockKey(segment))
    }
    .width('100%')
    .height(52)
    .padding(3)
    .borderRadius(9)
    .backgroundColor($r('app.color.track_bg'))
  }
}

/**
 * 画面区浮层（spec §5.2 / §6.4）：底部 84vp 渐变（底部渐变到透明），
 * 自上而下 = 进度条行 20 · 两端时间 · 控制行 28（左空、右剪刀圆钮）。
 *
 * 浮层盖在画面上（Task 9 把本组件放进画面区 Stack 的底部），所以：
 * - 进度条行整条都能按/拖：按下即出时间气泡，松手消失（spec §5.2）。
 * - 圆钮落在哪一段由父层决定选中（spec §5.4），这里只上报秒数。
 * - 剪刀是否可用只影响观感，点击一律上报，父层负责「满 3 段就提示」（spec §5.5）。
 */
@Component
export struct PreviewOverlay {
  @Prop playheadSec: number = 0
  @Prop totalDurationSec: number = 0
  @Prop canScissors: boolean = false
  onScrubTo?: (sec: number) => void
  onScissors?: () => void

  @State private dragging: boolean = false
  @State private dragSec: number = 0
  @State private barWidth: number = 0

  private percent(): number {
    if (this.totalDurationSec <= 0) {
      return 0
    }
    const sec = this.dragging ? this.dragSec : this.playheadSec
    return Math.min(100, Math.max(0, (sec / this.totalDurationSec) * 100))
  }

  private formatTime(sec: number): string {
    const whole = Math.max(0, Math.floor(sec))
    const minutes = Math.floor(whole / 60)
    const seconds = whole % 60
    return `${minutes}:${seconds < 10 ? '0' : ''}${seconds}`
  }

  private handleTouch(event: TouchEvent): void {
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.dragging = false
      return
    }
    if (this.barWidth <= 0 || this.totalDurationSec <= 0 || event.touches.length === 0) {
      return
    }
    const ratio = Math.min(1, Math.max(0, event.touches[0].x / this.barWidth))
    this.dragSec = ratio * this.totalDurationSec
    this.dragging = true
    if (this.onScrubTo) {
      this.onScrubTo(this.dragSec)
    }
  }

  @Builder
  progressRow() {
    Stack({ alignContent: Alignment.Start }) {
      Row()
        .width('100%')
        .height(2)
        .borderRadius(1)
        .backgroundColor($r('app.color.overlay_track'))
      Row() {
        Blank()
        Row()
          .width(14)
          .height(14)
          .borderRadius(7)
          .backgroundColor($r('app.color.card_bg'))
          .shadow({ radius: 4, color: $r('app.color.knob_shadow'), offsetX: 0, offsetY: 1 })
      }
      .width(`${this.percent()}%`)
      .height(20)
      if (this.dragging) {
        Row() {
          Blank()
          Text(this.formatTime(this.dragSec))
            .fontSize(11)
            .fontColor($r('app.color.card_bg'))
            .padding({ left: 6, right: 6, top: 3, bottom: 3 })
            .borderRadius(4)
            .backgroundColor($r('app.color.overlay_veil'))
        }
        .width(`${this.percent()}%`)
        .offset({ y: -24 })
      }
    }
    .width('100%')
    .height(20)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.barWidth = Number(newValue.width)
    })
    .onTouch((event: TouchEvent) => {
      this.handleTouch(event)
    })
  }

  @Builder
  timeRow() {
    Row() {
      Text(this.formatTime(this.playheadSec))
        .fontSize(11)
        .fontColor($r('app.color.overlay_text'))
      Blank()
      Text(this.formatTime(this.totalDurationSec))
        .fontSize(11)
        .fontColor($r('app.color.overlay_text'))
    }
    .width('100%')
    .height(16)
  }

  @Builder
  controlRow() {
    Row() {
      Blank()
      Stack({ alignContent: Alignment.Center }) {
        Text('✂')
          .fontSize(16)
          .fontColor($r('app.color.card_bg'))
      }
      .width(28)
      .height(28)
      .borderRadius(14)
      .borderWidth(1)
      .borderColor($r('app.color.overlay_btn_border'))
      .backgroundColor($r('app.color.overlay_btn_bg'))
      .opacity(this.canScissors ? 1 : 0.35)
      .onClick(() => {
        if (this.onScissors) {
          this.onScissors()
        }
      })
    }
    .width('100%')
    .height(28)
  }

  build() {
    Column() {
      this.progressRow()
      this.timeRow()
      this.controlRow()
    }
    .width('100%')
    .height(84)
    .padding({ left: 12, right: 12, bottom: 8 })
    .justifyContent(FlexAlign.End)
    .linearGradient({
      angle: 180,
      colors: [[$r('app.color.overlay_veil'), 0.0], [$r('app.color.overlay_fade'), 1.0]]
    })
  }
}
