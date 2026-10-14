import { Segment, formatSegmentDuration } from '../model/SegmentModel'
import { AppIcon, AppIconName } from './AppIcon'

/**
 * 参数行：`片段 N` · 时长 · 倍速胶囊 · 声音微胶囊 · 剪辑微胶囊 · 关闭微胶囊(✕)。
 *
 * 方案 B 语义微胶囊设计：
 * - 倍速：琥珀金胶囊（$r('app.color.amber_soft') 底 + $r('app.color.chip_amber_border') 边框 + $r('app.color.amber') 字）。
 * - 声音：开启时鼠尾草淡绿微胶囊（$r('app.color.chip_sage_bg') + $r('app.color.chip_sage_border') + $r('app.color.chip_sage_fg')），
 *   静音时中性灰微胶囊。
 * - 剪辑：剪辑按钮移动到声音按钮右侧！可用时琥珀金微胶囊，不可用（满3段）时灰调。
 * - ✕：关闭/停用微胶囊。可操作时柔和淡粉微胶囊，不可操作时浅灰。
 */
@Component
export struct SegmentParamRow {
  @Prop segment: Segment = new Segment()
  @Prop canToggle: boolean = true
  @Prop canScissors: boolean = false
  onCycleSpeed?: () => void
  onToggleMute?: () => void
  onScissors?: () => void
  onToggleEnabled?: () => void

  @Builder
  speedChip() {
    Text(this.segment.speedLabel.replace('X', 'x'))
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.amber'))
      .textAlign(TextAlign.Center)
      .height(26)
      .padding({ left: 8, right: 8 })
      .borderRadius(6)
      .borderWidth(1)
      .borderColor($r('app.color.chip_amber_border'))
      .backgroundColor($r('app.color.amber_soft'))
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
        iconSize: 16,
        iconColor: this.segment.muted ? $r('app.color.chip_neutral_fg') : $r('app.color.chip_sage_fg')
      })
    }
    .width(26)
    .height(26)
    .borderRadius(6)
    .borderWidth(1)
    .borderColor(this.segment.muted ? $r('app.color.chip_neutral_border') : $r('app.color.chip_sage_border'))
    .backgroundColor(this.segment.muted ? $r('app.color.chip_neutral_bg') : $r('app.color.chip_sage_bg'))
    .margin({ left: 6 })
    .onClick(() => {
      if (this.onToggleMute) {
        this.onToggleMute()
      }
    })
  }

  @Builder
  scissorsButton() {
    Stack({ alignContent: Alignment.Center }) {
      AppIcon({
        name: AppIconName.Scissors,
        iconSize: 15,
        iconColor: this.canScissors ? $r('app.color.amber') : $r('app.color.chip_disabled_fg')
      })
    }
    .width(26)
    .height(26)
    .borderRadius(6)
    .borderWidth(1)
    .borderColor(this.canScissors ? $r('app.color.chip_amber_border') : $r('app.color.chip_disabled_border'))
    .backgroundColor(this.canScissors ? $r('app.color.amber_soft') : $r('app.color.chip_disabled_bg'))
    .opacity(this.canScissors ? 1 : 0.4)
    .margin({ left: 6 })
    .onClick(() => {
      if (this.onScissors) {
        this.onScissors()
      }
    })
  }

  @Builder
  closeButton() {
    Stack({ alignContent: Alignment.Center }) {
      AppIcon({
        name: AppIconName.Close,
        iconSize: 14,
        iconColor: this.canToggle ? $r('app.color.chip_rose_fg') : $r('app.color.chip_disabled_fg')
      })
    }
    .width(26)
    .height(26)
    .borderRadius(6)
    .borderWidth(1)
    .borderColor(this.canToggle ? $r('app.color.chip_rose_border') : $r('app.color.chip_disabled_border'))
    .backgroundColor(this.canToggle ? $r('app.color.chip_rose_bg') : $r('app.color.chip_disabled_bg'))
    .opacity(this.canToggle ? 1 : 0.35)
    .margin({ left: 6 })
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
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ left: 8 })
      Blank()
      if (this.segment.enabled) {
        this.speedChip()
        this.soundIcon()
        this.scissorsButton()
      }
      this.closeButton()
    }
    .width('100%')
    .height(40)
    .alignItems(VerticalAlign.Center)
  }
}
