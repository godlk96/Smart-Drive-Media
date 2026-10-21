import { WorkEntry } from '../service/WorkStore'
import { formatExportTime, templateSlotCount } from '../model/WorkMeta'
import { CameraPosition, resolveTemplateDefinition } from '../model/Models'
import { getCameraZhNameById, normalizeCameraNameById } from '../constants/AppConstants'
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

  /**
   * 机位列表：「前 / 后 / 左后 / 右后」。
   *
   * 原来这里是一句「4 机位」。用户得先知道 4 机位是哪四个，才知道这条作品拍全了
   * 没有；不同模板之间也比不了（双录的 2 机位和左右盲区的 2 机位完全不是一回事）。
   * 直接列机位名，一眼看得出差别。
   *
   * 模板还认得才列名字：`templateSlotCount` 对未知模板返回 0，用它当判据 ——
   * 不能直接看 `resolveTemplateDefinition` 的返回值，它对未知值会兜底成 T1，
   * 于是老作品会被显示成「前」。
   */
  private cameraText(): string {
    if (!this.entry.meta) {
      return ''
    }
    const templateId: string = this.entry.meta.templateId
    if (templateSlotCount(templateId) <= 0) {
      return ''
    }
    const names: Array<string> = resolveTemplateDefinition(templateId).requiredCameras
      .map((camera: CameraPosition) => getCameraZhNameById(normalizeCameraNameById(String(camera))))
    return names.join(' / ')
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
          // 不要 .alt()：这里原来挂的是 app_icon，于是每次封面重新加载（切 tab、
          // 进出多选）都会先画一帧 App 图标，看起来就是"闪了一下 App 图标"。
          // 封面没加载出来时露出下面 Stack 的 stage_bg 就够了 —— 深色底和视频区同色，
          // 是"画面还没到"，而不是"这里放了张 app 图标"。
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

      // 播放键不在这里了：见 playButton 的注释。封面现在是一个单一目标。
    }
    .width('100%')
    .aspectRatio(16 / 9)
    .borderRadius(9)
    .clip(true)
    .backgroundColor($r('app.color.stage_bg'))
    .border({ width: 1, color: $r('app.color.stage_divider') })
  }

  /**
   * 「播放」。和「保存到相册」同一套外观、同一份量。
   *
   * 这里原来是一个只有 ▶ 的图标片，和旁边的文字按钮并排 —— 两个动作两套语言，
   * 而孤零零的 ▶ 还得让用户猜是"看成片"还是"预览一下"。移动端规范里，
   * 独立图标只留给标准导航（返回箭头那种），其余控制要么配文字、要么就别用图标。
   */
  @Builder
  playButton() {
    Text('播放')
      .fontSize(12)
      .fontColor($r('app.color.text_primary'))
      .height(34)
      .padding({ left: 14, right: 14 })
      .borderRadius(10)
      .backgroundColor($r('app.color.track_bg'))
      .onClick(() => {
        if (this.onPlay) {
          this.onPlay()
        }
      })
  }

  /**
   * 「保存到相册」。和播放键同一组、同一套外观（实心暖灰片、无描边）。
   *
   * 它单独在元信息下面左对齐时读起来是个标签 —— 那个带描边的小圆角块在这个 App 里
   * 是角标（见 Index 的 tripRow 的「最近」）。现在和播放键并排放在卡片右下角，
   * 两个控件互为语境，读起来才是"这里能按"。
   */
  @Builder
  saveToAlbumButton() {
    Text('保存到相册')
      .fontSize(12)
      .fontColor($r('app.color.text_primary'))
      .height(34)
      .padding({ left: 12, right: 12 })
      .borderRadius(10)
      .backgroundColor($r('app.color.track_bg'))
      .onClick(() => {
        if (this.onSaveToAlbum) {
          this.onSaveToAlbum()
        }
      })
  }

  /**
   * 多选态的勾选圆点。
   *
   * 原来用 `.position({ x: '88%', y: '5%' })`：百分比按**父容器宽度**算，
   * 22 宽的圆点从 88% 起画，右边还空着一百多像素 —— 看着离角很远，
   * 而且卡片宽度一变就得重调。现在交给外层 Stack 的 alignContent 对角放
   * （见 build 里的 Alignment.TopEnd），圆点自己只留 6 的边距。
   */
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
    .margin({ top: 6, right: 6 })
    .onClick(() => {
      if (this.onToggleSelect) {
        this.onToggleSelect()
      }
    })
  }

  build() {
    Column({ space: 0 }) {
      // TopEnd：只有 22×22 的勾选圆点会受它影响（封面是 100% 宽，对齐到一个角
      // 跟对齐到另一个角没区别），于是圆点天然贴着右上角，卡片多宽都不用手算百分比。
      Stack({ alignContent: Alignment.TopEnd }) {
        this.coverBlock()
        if (this.selectionMode) {
          this.selectBadge()
        }
      }
      .width('100%')

      Row() {
        Column({ space: 3 }) {
          Text(this.exportTimeText())
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          if (this.cameraText().length > 0) {
            Text(this.cameraText())
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 两个动作并排放在卡片右下角，都不压在视频上。
        // 视频区因此重新变成一个单一目标（点封面 = 重新剪辑），
        // 不用再在"点画面"和"点画面里的钮"之间猜。
        Row({ space: 8 }) {
          this.playButton()
          this.saveToAlbumButton()
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
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
