import { WorkEntry } from '../service/WorkStore'
import { formatExportTime, formatRecordSlotCount } from '../model/WorkMeta'
import { AppIcon, AppIconName } from './AppIcon'

/**
 * 「我的剪辑」里的一张作品卡：大封面 + 两行元信息（导出时间 / 机位数）。
 *
 * 纯展示组件，不做任何业务判断 —— 一件作品能不能重剪、封面用哪张都由父组件算好
 * 后通过 `entry` / `canReedit` / `fallbackCoverUri` 传进来。这样列表可以整页替换数据而不影响这里。
 *
 * 卡片上的分工（spec 4.12）：**点卡片任意位置 = 重新剪辑，点右下角 ▶ = 看成片**。
 * 降级卡片（有视频、无 sidecar）没有可还原的剪辑参数，`canReedit` 为假：
 * 重剪入口置灰、点卡片不再进编辑器，但封面、导出时间、▶ 与删除都照常。
 */
@Component
export struct WorkCard {
  @Prop entry: WorkEntry = new WorkEntry()
  @Prop selected: boolean = false
  @Prop selectionMode: boolean = false
  /** true = sidecar 可读、能重新剪辑；false = 降级卡片，重剪入口置灰 */
  @Prop canReedit: boolean = true
  /** 该作品封面 `<id>.jpg` 的绝对路径；空串时回落到 fallbackCoverUri */
  @Prop fallbackCoverUri: string = ''
  onOpen?: () => void
  onPlay?: () => void
  onToggleSelect?: () => void
  /** 「保存到相册」：把成片显式存一份到系统相册（App 之后不管理那份副本） */
  onSaveToAlbum?: () => void

  private formatCoverUri(uri: string): string {
    if (uri.startsWith('file://') || uri.startsWith('http://') || uri.startsWith('https://')) {
      return uri
    }
    return `file://${uri}`
  }

  private effectiveCoverUri(): string {
    if (this.entry.coverPath.length > 0) {
      return this.formatCoverUri(this.entry.coverPath)
    }
    if (this.fallbackCoverUri.length > 0) {
      return this.formatCoverUri(this.fallbackCoverUri)
    }
    return ''
  }

  /** 「4 机位」；无 sidecar 或模板取不到时返回空串，由 build() 决定整行不画。 */
  private slotText(): string {
    if (this.entry.meta) {
      return formatRecordSlotCount(this.entry.meta.templateId)
    }
    return ''
  }

  /** 导出时间：有 sidecar 用 exportedAt，无则退回文件名时间戳（= sortKey）。 */
  private exportTimeText(): string {
    return formatExportTime(this.entry.sortKey)
  }

  private shadowOptions(): ShadowOptions {
    if (this.selected) {
      return { radius: 14, color: $r('app.color.shadow_amber'), offsetX: 0, offsetY: 4 }
    }
    return { radius: 8, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 2 }
  }

  @Builder
  coverBlock() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      if (this.effectiveCoverUri().length > 0) {
        Image(this.effectiveCoverUri())
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .alt($r('app.media.app_icon'))
      } else {
        Text('无封面')
          .fontSize(12)
          .fontColor($r('app.color.overlay_text'))
      }

      if (!this.canReedit) {
        // 有视频、无元数据：封面照常画，只在左下角标出「重剪不可用」，不盖住封面。
        // 用满尺寸 Column 承担对齐（Stack 的 alignContent 只作用于子组件本身，
        // 元素的 .align() 管的是自身内容对齐，不能用它把角标挪到左下）。
        Column() {
          Text('无法重新剪辑')
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor($r('app.color.ed_surface'))
            .border({ width: 1, color: $r('app.color.ed_line') })
            .borderRadius(5)
            .margin({ left: 8, bottom: 8 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .alignItems(HorizontalAlign.Start)
        .hitTestBehavior(HitTestMode.None)
      }

      this.playButton()
    }
    .width('100%')
    .aspectRatio(16 / 9)
    .borderRadius(9)
    .clip(true)
    .backgroundColor($r('app.color.stage_bg'))
    .border({ width: 1, color: $r('app.color.stage_divider') })
  }

  @Builder
  playButton() {
    Stack({ alignContent: Alignment.Center }) {
      AppIcon({
        name: AppIconName.Play,
        iconSize: 13,
        iconColor: $r('app.color.ink')
      })
    }
    .width(30)
    .height(30)
    .borderRadius(15)
    .backgroundColor($r('app.color.card_bg'))
    .opacity(0.92)
    .margin({ right: 8, bottom: 8 })
    .onClick(() => {
      if (this.onPlay) {
        this.onPlay()
      }
    })
  }

  @Builder
  selectBadge() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.selected) {
        AppIcon({ name: AppIconName.Check, iconSize: 12, iconColor: $r('app.color.card_bg') })
      }
    }
    .width(22)
    .height(22)
    .borderRadius(11)
    .backgroundColor(this.selected ? $r('app.color.amber') : $r('app.color.card_bg'))
    .border({ width: 1.5, color: this.selected ? $r('app.color.amber') : $r('app.color.ed_line') })
    .position({ x: '88%', y: '5%' })
    .onClick(() => {
      if (this.onToggleSelect) {
        this.onToggleSelect()
      }
    })
  }

  /**
   * 「保存到相册」小按钮。放在元信息下方，而不是封面角上：封面右下角已被 ▶ 占用、
   * 卡片主体点击是重新剪辑，这里独立成一个 pill，既不压 ▶ 也不误触重剪。
   * 降级卡片（`canReedit` 为假）同样可用 —— 只能看/存/删的作品也要能存。
   */
  @Builder
  saveToAlbumButton() {
    Text('保存到相册')
      .fontSize(12)
      .fontColor($r('app.color.text_secondary'))
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      .backgroundColor($r('app.color.ed_surface'))
      .border({ width: 1, color: $r('app.color.ed_line') })
      .borderRadius(7)
      .margin({ top: 6 })
      .onClick(() => {
        if (this.onSaveToAlbum) {
          this.onSaveToAlbum()
        }
      })
  }

  build() {
    Column({ space: 0 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        this.coverBlock()
        if (this.selectionMode) {
          this.selectBadge()
        }
      }
      .width('100%')

      Column({ space: 3 }) {
        Text(this.exportTimeText())
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.slotText().length > 0) {
          Text(this.slotText())
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
        this.saveToAlbumButton()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 10, right: 10, top: 10, bottom: 12 })
    }
    .width('100%')
    .padding(2.5)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(12)
    .border({
      width: this.selected ? 1.5 : 1,
      color: this.selected ? $r('app.color.amber') : $r('app.color.ed_line')
    })
    .shadow(this.shadowOptions())
    .onClick(() => {
      // 降级卡片没有可还原的参数，点卡片不进编辑器 —— 只能看/存/删。
      if (!this.canReedit) {
        return
      }
      if (this.onOpen) {
        this.onOpen()
      }
    })
  }
}
