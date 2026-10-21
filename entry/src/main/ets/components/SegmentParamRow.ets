import { Segment, formatSegmentDuration, segmentDisplayName } from '../model/SegmentModel'
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

  // 下面四个控件原来各是一个 34×34、圆角 10 的"胶囊"：倍速=琥珀底、声音=鼠尾草绿底、
  // 剪刀=琥珀底、关闭=玫瑰红底，每个都带 1px 同色描边。四种颜色编码四个动作，
  // 用户记不住，读起来只剩装饰；一屏里还多出四个盒子。
  //
  // 现在全部拆成裸图标：颜色只表达**能不能用**（可用=近黑，不可用=浅灰），
  // 表达"这是什么"交给图标形状本身。热区从 34 放到 40，没有盒子之后放大是免费的。

  @Builder
  speedChip() {
    Text(this.segment.speedLabel.replace('X', 'x'))
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_primary'))
      .textAlign(TextAlign.Center)
      .height(40)
      .padding({ left: 6, right: 6 })
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
        iconColor: this.segment.muted ? $r('app.color.text_disabled') : $r('app.color.text_primary')
      })
    }
    .width(40)
    .height(40)
    // 拆掉盒子之后热区之间没有视觉分界，补 10 的间距，免得剪一刀剪到隔壁的 ✕
    .margin({ left: 10 })
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
        iconColor: this.canScissors ? $r('app.color.text_primary') : $r('app.color.text_disabled')
      })
    }
    .width(40)
    .height(40)
    .margin({ left: 10 })
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
        iconColor: this.canToggle ? $r('app.color.text_tertiary') : $r('app.color.text_disabled')
      })
    }
    .width(40)
    .height(40)
    .margin({ left: 10 })
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
    // 40 → 44 → 50：胶囊从 26 一路放大到 34，行高跟着走，上下各留 8vp。
    // 这一步是"所有按钮再大一点点"里的一条 —— 胶囊不能只自己变大，
    // 不然 34 的胶囊塞在 44 的行里上下只剩 5vp，比放大前还挤。
    .height(50)
    .alignItems(VerticalAlign.Center)
  }
}
