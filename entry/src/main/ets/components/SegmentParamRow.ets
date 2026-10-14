import { Segment, formatSegmentDuration } from '../model/SegmentModel'
import { AppIcon, AppIconName } from './AppIcon'

/**
 * 参数行（spec §5.6 / §6.5）：`片段 N` · 时长 · 倍速胶囊 · 声音图标 · ✕。
 *
 * - 默认值（1.0X 且原声）不做任何视觉强调（spec §5.6）。
 * - 灰段只留段名、时长与 ✕，倍速/声音隐藏（spec §5.4，§9.3 取「隐藏」）。
 * - 只剩一段时 ✕ 不再生效（spec §5.7）；`canToggle` 由 `canToggleSegment` 给出，
 *   目标是灰段时恒为真，所以灰段总能点回来（D13）。
 */
@Component
export struct SegmentParamRow {
  @Prop segment: Segment = new Segment()
  @Prop canToggle: boolean = true
  onCycleSpeed?: () => void
  onToggleMute?: () => void
  onToggleEnabled?: () => void

  @Builder
  speedChip() {
    Text(this.segment.speedLabel.replace('X', 'x'))
      .fontSize(12)
      .fontColor($r('app.color.text_secondary'))
      .textAlign(TextAlign.Center)
      .height(26)
      .padding({ left: 9, right: 9 })
      .borderRadius(7)
      .borderWidth(1)
      .borderColor($r('app.color.segment_border'))
      .backgroundColor($r('app.color.chip_bg'))
      .onClick(() => {
        if (this.onCycleSpeed) {
          this.onCycleSpeed()
        }
      })
  }

  @Builder
  soundIcon() {
    Stack({ alignContent: Alignment.Center }) {
      AppIcon({
        name: this.segment.muted ? AppIconName.Muted : AppIconName.Speaker,
        iconSize: 20,
        iconColor: $r('app.color.text_secondary')
      })
    }
    .width(32)
    .height(32)
    .margin({ left: 8 })
    .onClick(() => {
      if (this.onToggleMute) {
        this.onToggleMute()
      }
    })
  }

  @Builder
  closeButton() {
    Stack({ alignContent: Alignment.Center }) {
      AppIcon({ name: AppIconName.Close, iconSize: 18, iconColor: $r('app.color.text_disabled') })
    }
    .width(32)
    .height(32)
    .margin({ left: 8 })
    .opacity(this.canToggle ? 1 : 0.35)
    .onClick(() => {
      if (this.canToggle && this.onToggleEnabled) {
        this.onToggleEnabled()
      }
    })
  }

  build() {
    Row() {
      Text(`片段 ${this.segment.id + 1}`)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
      Text(formatSegmentDuration(this.segment))
        .fontSize(15)
        .fontWeight(600)
        .fontColor($r('app.color.text_primary'))
        .margin({ left: 8 })
      Blank()
      if (this.segment.enabled) {
        this.speedChip()
        this.soundIcon()
      }
      this.closeButton()
    }
    .width('100%')
    .height(40)
    .alignItems(VerticalAlign.Center)
  }
}
