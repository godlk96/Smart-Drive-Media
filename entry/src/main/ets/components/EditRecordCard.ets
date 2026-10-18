import { EditRecord, formatExportTime, formatRecordSummary } from '../model/EditRecord'
import { getTemplateUiNameById } from '../constants/AppConstants'
import { AppIcon, AppIconName } from './AppIcon'

/**
 * 「我的剪辑」里的一张作品卡：大封面 + 三行元信息 + 重新剪辑胶囊。
 *
 * 纯展示组件，不做任何业务判断 —— 记录能不能打开、成片还在不在都由父组件算好
 * 后通过 `orphan` / `coverPath` 传进来。这样列表可以整页替换数据而不影响这里。
 *
 * 卡片上的分工（spec 4.12）：**点卡片主体 = 重新剪辑，点右下角 ▶ = 看成片**。
 * ▶ 是「跳系统相册播放」，所以成片被删（`orphan`）时就置灰并吞掉点击 ——
 * 让用户点一个注定失败的东西比不给他点更糟。
 */
@Component
export struct EditRecordCard {
  @Prop record: EditRecord = new EditRecord()
  @Prop selected: boolean = false
  @Prop selectionMode: boolean = false
  /** true = 相册里那份成片已被删除，降级显示 */
  @Prop orphan: boolean = false
  /** 父组件异步取到的成片首帧；空串时回落到 fallbackCoverUri */
  @Prop coverPath: string = ''
  /** 该行程在行程库里的封面，保证卡片永远有东西可画 */
  @Prop fallbackCoverUri: string = ''
  onOpen?: () => void
  onPlay?: () => void
  onToggleSelect?: () => void

  private formatCoverUri(uri: string): string {
    if (uri.startsWith('file://') || uri.startsWith('http://') || uri.startsWith('https://')) {
      return uri
    }
    return `file://${uri}`
  }

  private effectiveCoverUri(): string {
    if (this.coverPath.length > 0) {
      return this.formatCoverUri(this.coverPath)
    }
    if (this.fallbackCoverUri.length > 0) {
      return this.formatCoverUri(this.fallbackCoverUri)
    }
    return ''
  }

  /** 「10月1日 周三 · 单视角」；模板名取不到时只显示日期，不留悬空的「·」。 */
  private titleText(): string {
    const templateName = getTemplateUiNameById(this.record.templateId)
    if (templateName.length === 0) {
      return this.record.tripTitle
    }
    if (this.record.tripTitle.length === 0) {
      return templateName
    }
    return `${this.record.tripTitle} · ${templateName}`
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

      if (this.orphan) {
        // 成片没了：压一层暗罩并说明原因，卡片本身仍然可点（还能重新剪辑）。
        Column({ space: 4 }) {
          Text('相册里的视频已被删除')
            .fontSize(12)
            .fontColor($r('app.color.overlay_text'))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.overlay_veil'))
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
        iconColor: this.orphan ? $r('app.color.text_disabled') : $r('app.color.ink')
      })
    }
    .width(30)
    .height(30)
    .borderRadius(15)
    .backgroundColor($r('app.color.card_bg'))
    .opacity(this.orphan ? 0.45 : 0.92)
    .margin({ right: 8, bottom: 8 })
    .onClick(() => {
      if (this.orphan) {
        return
      }
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

  @Builder
  reEditChip() {
    Text('重新剪辑')
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.amber'))
      .textAlign(TextAlign.Center)
      .height(29)
      .padding({ left: 14, right: 14 })
      .borderRadius(15)
      .borderWidth(1)
      .borderColor($r('app.color.chip_amber_border'))
      .backgroundColor($r('app.color.amber_soft'))
      .onClick(() => {
        if (this.onOpen) {
          this.onOpen()
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
        Text(this.titleText())
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(formatRecordSummary(this.record.segmentCount, this.record.durationMs))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        Text(formatExportTime(this.record.exportedAt))
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 10, right: 10, top: 10 })

      Row({ space: 0 }) {
        this.reEditChip()
        Blank()
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 8, bottom: 12 })
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
      if (this.onOpen) {
        this.onOpen()
      }
    })
  }
}
