import { Segment, segmentDurationSec, MIN_SEGMENT_SEC } from '../model/SegmentModel'
import { AppIcon, AppIconName } from './AppIcon'

/**
 * 轨道项数据结构（片段或空白区间）
 */
class TrackTimelineItem {
  isGap: boolean = false
  segment: Segment = new Segment()
  startSec: number = 0
  endSec: number = 0
  durationSec: number = 0
  key: string = ''

  constructor(isGap: boolean, segment: Segment, startSec: number, endSec: number, durationSec: number, key: string) {
    this.isGap = isGap
    this.segment = segment
    this.startSec = startSec
    this.endSec = endSec
    this.durationSec = durationSec
    this.key = key
  }
}

/**
 * 片段轨道（spec §6.6 / Task 3）：
 * - 段块与空白区间按各自时长占宽、段间 3vp 缝。
 * - 全片态（isRawFull）：单块通宽展示，文案“全片”，无琥珀描边，无拉动手柄。
 * - 多段态（SEGMENTED）：选中的片段具有 1.5vp 琥珀描边 + 左右两侧双向手柄。
 * - 双向手柄拖拽（零 Seek）：水平 PanGesture 拖动过程中严禁触发 Seek 或边界修改，
 *   仅 60Hz 响应更新本地浮动时间气泡与手柄位移，松手（onActionEnd）时一次性结算边界。
 * - 硬阻挡（Clamp）：手柄向外拉受限于片头(0)/片尾/相邻段，向内拉受限于 MIN_SEGMENT_SEC(10s)。
 */
@Component
export struct SegmentTrack {
  @Prop segments: Array<Segment> = []
  @Prop totalDurationSec: number = 0
  @Prop selectedSegmentId: number = -1
  @Prop isRawFull: boolean = false
  onSelectSegment?: (id: number) => void
  onAdjustBoundary?: (id: number, edge: 'start' | 'end', sec: number) => void

  @State private isDraggingLeft: boolean = false
  @State private dragLeftSec: number = 0
  @State private dragLeftBaseSec: number = 0
  @State private draggingSegmentId: number = -1

  @State private isDraggingRight: boolean = false
  @State private dragRightSec: number = 0
  @State private dragRightBaseSec: number = 0

  @State private trackWidth: number = 320

  private isSelected(segment: Segment): boolean {
    return !this.isRawFull && segment.enabled && segment.id === this.selectedSegmentId
  }

  /**
   * ForEach 的键必须带上所有影响渲染的字段
   */
  private blockKey(segment: Segment): string {
    return `${segment.id}-${segment.startSec}-${segment.endSec}-${segment.speedLabel}-${segment.muted}-${segment.enabled}-${this.isSelected(segment)}-${this.isRawFull}`
  }

  private formatTime(sec: number): string {
    const whole = Math.max(0, Math.round(sec))
    const minutes = Math.floor(whole / 60)
    const seconds = whole % 60
    return `${minutes}:${seconds < 10 ? '0' : ''}${seconds}`
  }

  private clampStartSec(segment: Segment, targetSec: number): number {
    const sorted: Array<Segment> = []
    for (let i = 0; i < this.segments.length; i++) {
      sorted.push(this.segments[i])
    }
    sorted.sort((a: Segment, b: Segment) => a.startSec - b.startSec)
    let idx = -1
    for (let i = 0; i < sorted.length; i++) {
      if (sorted[i].id === segment.id) {
        idx = i
        break
      }
    }
    const minSec = idx > 0 ? sorted[idx - 1].endSec : 0
    const maxSec = segment.endSec - MIN_SEGMENT_SEC
    return Math.max(minSec, Math.min(targetSec, maxSec))
  }

  private clampEndSec(segment: Segment, targetSec: number): number {
    const sorted: Array<Segment> = []
    for (let i = 0; i < this.segments.length; i++) {
      sorted.push(this.segments[i])
    }
    sorted.sort((a: Segment, b: Segment) => a.startSec - b.startSec)
    let idx = -1
    for (let i = 0; i < sorted.length; i++) {
      if (sorted[i].id === segment.id) {
        idx = i
        break
      }
    }
    const minSec = segment.startSec + MIN_SEGMENT_SEC
    const total = this.totalDurationSec > 0 ? this.totalDurationSec : 60
    const maxSec = idx >= 0 && idx < sorted.length - 1 ? sorted[idx + 1].startSec : total
    return Math.max(minSec, Math.min(targetSec, maxSec))
  }

  private getLeftHandleDragOffset(): number {
    if (this.totalDurationSec <= 0 || this.trackWidth <= 0) {
      return 0
    }
    const deltaSec = this.dragLeftSec - this.dragLeftBaseSec
    return (deltaSec / this.totalDurationSec) * this.trackWidth
  }

  private getRightHandleDragOffset(): number {
    if (this.totalDurationSec <= 0 || this.trackWidth <= 0) {
      return 0
    }
    const deltaSec = this.dragRightSec - this.dragRightBaseSec
    return (deltaSec / this.totalDurationSec) * this.trackWidth
  }

  private buildTimelineItems(): Array<TrackTimelineItem> {
    const items: Array<TrackTimelineItem> = []
    if (this.isRawFull) {
      const seg = this.segments.length > 0 ? this.segments[0] : new Segment()
      const dur = this.totalDurationSec > 0 ? this.totalDurationSec : Math.max(1, segmentDurationSec(seg))
      items.push(new TrackTimelineItem(false, seg, 0, dur, dur, `raw-full-${dur}`))
      return items
    }

    const sorted: Array<Segment> = []
    for (let i = 0; i < this.segments.length; i++) {
      sorted.push(this.segments[i])
    }
    sorted.sort((a: Segment, b: Segment) => a.startSec - b.startSec)

    if (sorted.length === 0) {
      if (this.totalDurationSec > 0) {
        items.push(new TrackTimelineItem(true, new Segment(), 0, this.totalDurationSec, this.totalDurationSec, `gap-0-${this.totalDurationSec}`))
      }
      return items
    }

    // 片头空白区
    if (sorted[0].startSec > 0.05) {
      const gapDur = sorted[0].startSec
      items.push(new TrackTimelineItem(true, new Segment(), 0, sorted[0].startSec, gapDur, `gap-0-${sorted[0].startSec}`))
    }

    for (let i = 0; i < sorted.length; i++) {
      const seg = sorted[i]
      const segDur = Math.max(0.1, segmentDurationSec(seg))
      items.push(new TrackTimelineItem(false, seg, seg.startSec, seg.endSec, segDur, this.blockKey(seg)))

      // 片段间空白区
      if (i < sorted.length - 1) {
        const nextSeg = sorted[i + 1]
        if (nextSeg.startSec - seg.endSec > 0.05) {
          const gapDur = nextSeg.startSec - seg.endSec
          items.push(new TrackTimelineItem(true, new Segment(), seg.endSec, nextSeg.startSec, gapDur, `gap-${seg.endSec}-${nextSeg.startSec}`))
        }
      }
    }

    // 片尾空白区
    const lastSeg = sorted[sorted.length - 1]
    if (this.totalDurationSec - lastSeg.endSec > 0.05) {
      const gapDur = this.totalDurationSec - lastSeg.endSec
      items.push(new TrackTimelineItem(true, new Segment(), lastSeg.endSec, this.totalDurationSec, gapDur, `gap-${lastSeg.endSec}-${this.totalDurationSec}`))
    }

    return items
  }

  @Builder
  handleDot() {
    Row()
      .width(2)
      .height(2)
      .borderRadius(1)
      .backgroundColor($r('app.color.card_bg'))
  }

  @Builder
  handleBar() {
    Stack({ alignContent: Alignment.Center }) {
      Row()
        .width(6)
        .height(44)
        .borderRadius(3)
        .backgroundColor($r('app.color.amber'))
      Column({ space: 3 }) {
        this.handleDot()
        this.handleDot()
        this.handleDot()
      }
    }
    .width(6)
    .height(44)
  }

  @Builder
  bubble(timeText: string) {
    Row() {
      Text(timeText)
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.card_bg'))
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .borderRadius(4)
        .backgroundColor($r('app.color.overlay_veil'))
    }
    .offset({ y: -30 })
    .shadow({ radius: 4, color: $r('app.color.knob_shadow'), offsetX: 0, offsetY: 1 })
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  leftHandle(segment: Segment) {
    Stack({ alignContent: Alignment.Center }) {
      this.handleBar()
      if (this.isDraggingLeft && this.draggingSegmentId === segment.id) {
        this.bubble(this.formatTime(this.dragLeftSec))
      }
    }
    .width(16)
    .height(44)
    .offset({
      x: -9 + (this.isDraggingLeft && this.draggingSegmentId === segment.id ? this.getLeftHandleDragOffset() : 0)
    })
    .gesture(
      PanGesture({ direction: PanDirection.Horizontal })
        .onActionStart(() => {
          this.draggingSegmentId = segment.id
          this.dragLeftBaseSec = segment.startSec
          this.dragLeftSec = segment.startSec
          this.isDraggingLeft = true
        })
        .onActionUpdate((event: GestureEvent) => {
          if (!this.isDraggingLeft || this.draggingSegmentId !== segment.id) {
            return
          }
          if (this.trackWidth <= 0 || this.totalDurationSec <= 0) {
            return
          }
          const deltaSec = (event.offsetX / this.trackWidth) * this.totalDurationSec
          const targetSec = this.dragLeftBaseSec + deltaSec
          this.dragLeftSec = this.clampStartSec(segment, targetSec)
        })
        .onActionEnd(() => {
          this.isDraggingLeft = false
          const finalSec = this.dragLeftSec
          if (this.onAdjustBoundary) {
            this.onAdjustBoundary(segment.id, 'start', finalSec)
          }
        })
        .onActionCancel(() => {
          this.isDraggingLeft = false
        })
    )
  }

  @Builder
  rightHandle(segment: Segment) {
    Stack({ alignContent: Alignment.Center }) {
      this.handleBar()
      if (this.isDraggingRight && this.draggingSegmentId === segment.id) {
        this.bubble(this.formatTime(this.dragRightSec))
      }
    }
    .width(16)
    .height(44)
    .offset({
      x: 9 + (this.isDraggingRight && this.draggingSegmentId === segment.id ? this.getRightHandleDragOffset() : 0)
    })
    .gesture(
      PanGesture({ direction: PanDirection.Horizontal })
        .onActionStart(() => {
          this.draggingSegmentId = segment.id
          this.dragRightBaseSec = segment.endSec
          this.dragRightSec = segment.endSec
          this.isDraggingRight = true
        })
        .onActionUpdate((event: GestureEvent) => {
          if (!this.isDraggingRight || this.draggingSegmentId !== segment.id) {
            return
          }
          if (this.trackWidth <= 0 || this.totalDurationSec <= 0) {
            return
          }
          const deltaSec = (event.offsetX / this.trackWidth) * this.totalDurationSec
          const targetSec = this.dragRightBaseSec + deltaSec
          this.dragRightSec = this.clampEndSec(segment, targetSec)
        })
        .onActionEnd(() => {
          this.isDraggingRight = false
          const finalSec = this.dragRightSec
          if (this.onAdjustBoundary) {
            this.onAdjustBoundary(segment.id, 'end', finalSec)
          }
        })
        .onActionCancel(() => {
          this.isDraggingRight = false
        })
    )
  }

  @Builder
  handles(segment: Segment) {
    Row() {
      this.leftHandle(segment)
      Blank()
      this.rightHandle(segment)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  segmentBlock(segment: Segment, weight: number) {
    Stack({ alignContent: Alignment.Center }) {
      Text(this.isRawFull ? '全片' : `片段 ${segment.id + 1}`)
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
        this.handles(segment)
      }
    }
    .layoutWeight(weight)
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
      ForEach(this.buildTimelineItems(), (item: TrackTimelineItem) => {
        if (item.isGap) {
          Row()
            .layoutWeight(item.durationSec)
            .height('100%')
        } else {
          this.segmentBlock(item.segment, item.durationSec)
        }
      }, (item: TrackTimelineItem) => item.key)
    }
    .width('100%')
    .height(52)
    .padding(3)
    .borderRadius(9)
    .backgroundColor($r('app.color.track_bg'))
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.trackWidth = Number(newValue.width)
    })
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
        .height(3)
        .borderRadius(1.5)
        .backgroundColor($r('app.color.overlay_track'))
      // 已播部分：整条按播放进度填琥珀。以前只有一根 30% 白的细轨加一个白点，
      // 压在高亮画面上几乎看不见，"进度条"读起来就只剩一个圆钮。
      Row()
        .width(`${this.percent()}%`)
        .height(3)
        .borderRadius(1.5)
        .backgroundColor($r('app.color.amber'))
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
        AppIcon({ name: AppIconName.Scissors, iconSize: 18, iconColor: $r('app.color.card_bg') })
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
    }
    .width('100%')
    .height(54)
    .padding({ left: 12, right: 12, bottom: 8 })
    .justifyContent(FlexAlign.End)
    .linearGradient({
      angle: 180,
      colors: [[$r('app.color.overlay_veil'), 0.0], [$r('app.color.overlay_fade'), 1.0]]
    })
  }
}
