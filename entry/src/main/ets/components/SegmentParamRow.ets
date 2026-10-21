import { Segment, formatSegmentDuration, segmentDisplayName } from '../model/SegmentModel'
import { AppIcon, AppIconName } from './AppIcon'

/** 一项操作的宽度：图标 20 居中、标签 11px 在下方。 */
const ITEM_WIDTH: number = 60
const ITEM_HEIGHT: number = 56
/** 图标占位高度。四个动作共用，保证标签落在同一条基线上（速度是文字，也按这个高度占位）。 */
const ICON_SLOT_HEIGHT: number = 22

/**
 * 参数行：`第一段` / `全片` / `空白区间` 三态，右侧是一组带文字标签的操作。
 *
 * 为什么每个操作下面要带字：
 * - 移动端规范里，**独立图标只留给标准导航**（返回箭头那种）；剪刀、喇叭、✕ 单独摆着时
 *   用户要猜「这一刀是剪什么」。
 * - 拆掉原来的彩色胶囊之后，四个动作只剩形状区分，一排放着更像一排零件。
 *   补一个 11px 的标签，动作本身就不用解释了。
 * 图标统一 20、同一套描边；标签用次级灰，不抢图标。
 *
 * 三个态：
 * - 空白区间 (`isGap`)：只留「剪辑」。
 * - 全片 (`isRawFull`)：速度 / 声音 / 剪辑，没有「删除」—— 整片没有"删掉"这个动作。
 * - 片段编辑态：四项齐全；不可用时整项（图标+文字）一起变浅灰，不是只有图标变灰。
 */
@Component
export struct SegmentParamRow {
  @Prop segment: Segment = new Segment()
  @Prop ordinal: number = 1
  @Prop canToggle: boolean = true
  @Prop canScissors: boolean = false
  @Prop isRawFull: boolean = false
  @Prop isGap: boolean = false
  onCycleSpeed?: () => void
  onToggleMute?: () => void
  onScissors?: () => void
  onToggleEnabled?: () => void
  onDeleteSegment?: () => void

  @Builder
  actionLabel(text: string, enabled: boolean) {
    Text(text)
      .fontSize(11)
      .fontColor(enabled ? $r('app.color.text_secondary') : $r('app.color.text_disabled'))
      .maxLines(1)
  }

  @Builder
  speedChip() {
    Column({ space: 2 }) {
      // 速度这一项没有图标：当前倍速本身就是它最准确的"图标"。
      Text(this.segment.speedLabel.replace('X', 'x'))
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .height(ICON_SLOT_HEIGHT)
        .textAlign(TextAlign.Center)
      this.actionLabel('速度', true)
    }
    .width(ITEM_WIDTH)
    .height(ITEM_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .stateStyles({
      normal: { .opacity(1) },
      pressed: { .opacity(0.45) }
    })
    .onClick(() => {
      if (this.onCycleSpeed) {
        this.onCycleSpeed()
      }
    })
  }

  @Builder
  soundIcon() {
    Column({ space: 2 }) {
      Stack({ alignContent: Alignment.Center }) {
        AppIcon({
          name: this.segment.muted ? AppIconName.Muted : AppIconName.Speaker,
          iconSize: 20,
          iconColor: this.segment.muted ? $r('app.color.text_disabled') : $r('app.color.text_primary')
        })
      }
      .height(ICON_SLOT_HEIGHT)
      // 标签同时当状态：静音时写"静音"，一眼看得出开关的位置。
      this.actionLabel(this.segment.muted ? '静音' : '声音', !this.segment.muted)
    }
    .width(ITEM_WIDTH)
    .height(ITEM_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .stateStyles({
      normal: { .opacity(1) },
      pressed: { .opacity(0.45) }
    })
    .onClick(() => {
      if (this.onToggleMute) {
        this.onToggleMute()
      }
    })
  }

  @Builder
  scissorsButton() {
    Column({ space: 2 }) {
      Stack({ alignContent: Alignment.Center }) {
        AppIcon({
          name: AppIconName.Scissors,
          iconSize: 20,
          iconColor: this.canScissors ? $r('app.color.text_primary') : $r('app.color.text_disabled')
        })
      }
      .height(ICON_SLOT_HEIGHT)
      this.actionLabel('剪辑', this.canScissors)
    }
    .width(ITEM_WIDTH)
    .height(ITEM_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .stateStyles({
      normal: { .opacity(1) },
      pressed: { .opacity(0.45) }
    })
    .onClick(() => {
      if (this.onScissors) {
        this.onScissors()
      }
    })
  }

  @Builder
  closeButton() {
    Column({ space: 2 }) {
      Stack({ alignContent: Alignment.Center }) {
        AppIcon({
          name: AppIconName.Close,
          iconSize: 20,
          iconColor: this.canToggle ? $r('app.color.text_tertiary') : $r('app.color.text_disabled')
        })
      }
      .height(ICON_SLOT_HEIGHT)
      this.actionLabel('删除', this.canToggle)
    }
    .width(ITEM_WIDTH)
    .height(ITEM_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .stateStyles({
      normal: { .opacity(1) },
      pressed: { .opacity(0.45) }
    })
    .onClick(() => {
      if (this.canToggle) {
        if (this.onDeleteSegment) {
          this.onDeleteSegment()
        } else if (this.onToggleEnabled) {
          this.onToggleEnabled()
        }
      }
    })
  }

  build() {
    Row() {
      if (this.isGap) {
        Text('空白区间')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
        Blank()
        this.scissorsButton()
      } else if (this.isRawFull) {
        Text('全片')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
        Text(formatSegmentDuration(this.segment))
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 8 })
        Blank()
        this.speedChip()
        this.soundIcon()
        this.scissorsButton()
      } else {
        Text(segmentDisplayName(this.ordinal))
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
        Text(formatSegmentDuration(this.segment))
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 8 })
        Blank()
        this.speedChip()
        this.soundIcon()
        this.scissorsButton()
        this.closeButton()
      }
    }
    .width('100%')
    // 行高跟着这一组操作走：图标 22 + 间距 2 + 标签 15 ≈ 39，上下各留 8，合计 56。
    .height(ITEM_HEIGHT)
    .alignItems(VerticalAlign.Center)
  }
}
