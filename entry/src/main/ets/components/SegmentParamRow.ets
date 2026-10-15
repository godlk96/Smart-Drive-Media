import { Segment, formatSegmentDuration } from '../model/SegmentModel'
import { AppIcon, AppIconName } from './AppIcon'

/**
 * 参数行：`片段 N` / `全片` / `空白区间` 三态支持。
 *
 * 方案 B 语义微胶囊设计：
 * - 空白区间态 (`isGap`):
 *   显示 `空白区间`，仅保留剪刀按钮，隐藏倍速、声音、删除。
 * - 全片态 (`isRawFull`):
 *   显示 `全片` · 时长 · 倍速微胶囊 · 声音微胶囊 · 剪辑微胶囊；隐藏删除【✕】按钮。
 * - 片段编辑态 (默认):
 *   显示 `片段 N` · 时长 · 倍速微胶囊 · 声音微胶囊 · 剪辑微胶囊 · 关闭微胶囊(✕)。
 *
 * `N` 由 `ordinal` 传入，取值来自 `SegmentModel.segmentOrdinal()`（按起点升序现数）。
 * 曾经这里写 `segment.id + 1`：物理删除会留下 id 空洞，删掉中间段后两块会显示成
 * 「片段 1 / 片段 3」，与轨道上只有两块对不上。
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
  speedChip() {
    Text(this.segment.speedLabel.replace('X', 'x'))
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.amber'))
      .textAlign(TextAlign.Center)
      .height(34)
      .padding({ left: 12, right: 12 })
      .borderRadius(10)
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
        iconSize: 20,
        iconColor: this.segment.muted ? $r('app.color.chip_neutral_fg') : $r('app.color.chip_sage_fg')
      })
    }
    .width(34)
    .height(34)
    .borderRadius(10)
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
        iconSize: 19,
        iconColor: this.canScissors ? $r('app.color.amber') : $r('app.color.chip_disabled_fg')
      })
    }
    .width(34)
    .height(34)
    .borderRadius(10)
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
        iconSize: 18,
        iconColor: this.canToggle ? $r('app.color.chip_rose_fg') : $r('app.color.chip_disabled_fg')
      })
    }
    .width(34)
    .height(34)
    .borderRadius(10)
    .borderWidth(1)
    .borderColor(this.canToggle ? $r('app.color.chip_rose_border') : $r('app.color.chip_disabled_border'))
    .backgroundColor(this.canToggle ? $r('app.color.chip_rose_bg') : $r('app.color.chip_disabled_bg'))
    .opacity(this.canToggle ? 1 : 0.35)
    .margin({ left: 6 })
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
          .fontSize(13)
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
        Text('片段 ' + this.ordinal)
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
    // 40 → 44 → 50：胶囊从 26 一路放大到 34，行高跟着走，上下各留 8vp。
    // 这一步是"所有按钮再大一点点"里的一条 —— 胶囊不能只自己变大，
    // 不然 34 的胶囊塞在 44 的行里上下只剩 5vp，比放大前还挤。
    .height(50)
    .alignItems(VerticalAlign.Center)
  }
}
