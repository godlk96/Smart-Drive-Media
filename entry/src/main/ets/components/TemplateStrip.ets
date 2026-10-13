import { TemplateCardModel, TimelineTrackModel } from '../model/AppState'
import { getTemplateIconById, getTemplateUiNameById, resolveTemplateDefinition } from '../model/Models'
import { getCameraZhNameById, normalizeCameraNameById } from '../constants/AppConstants'

/**
 * 模板行（spec §5.8 / §6.7）：横向滚动、卡宽 72、缩略图 72×46、标签 10。
 *
 * 缺机位的模板整卡 40% 不透明且不可点，点击只上报拒绝文案（spec §5.8 保留原有 toast）。
 * 判定与文案复用 `resolveTemplateDefinition` + 机位归一化，与 `EditorViewModel` 同源，
 * 因此这里不依赖 viewmodel（组件不反向依赖 VM）。
 */
@Component
export struct TemplateStrip {
  @Prop cards: Array<TemplateCardModel> = []
  @Prop timeline: Array<TimelineTrackModel> = []
  @Prop activeTemplateId: string = ''
  onSelectTemplate?: (id: string) => void
  onRejected?: (message: string) => void

  private missingViews(card: TemplateCardModel): string {
    const definition = resolveTemplateDefinition(card.id)
    const tracks = this.timeline.map((item: TimelineTrackModel) => normalizeCameraNameById(item.cameraPosition))
    const missing = definition.requiredCameras
      .filter((camera) => !tracks.some((item: string) => item === normalizeCameraNameById(String(camera))))
      .map((camera) => getCameraZhNameById(normalizeCameraNameById(String(camera))))
    return missing.join('、')
  }

  private iconText(card: TemplateCardModel): string {
    const icon = getTemplateIconById(card.id)
    return icon.length > 0 ? icon : '🎬'
  }

  private labelText(card: TemplateCardModel): string {
    const name = getTemplateUiNameById(card.id)
    return name.length > 0 ? name : card.title
  }

  private handleTap(card: TemplateCardModel): void {
    const missing = this.missingViews(card)
    if (missing.length > 0) {
      if (this.onRejected) {
        this.onRejected(`缺少${missing}视角，无法使用该模板`)
      }
      return
    }
    if (this.onSelectTemplate) {
      this.onSelectTemplate(card.id)
    }
  }

  @Builder
  card(card: TemplateCardModel) {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        Text(this.iconText(card))
          .fontSize(22)
      }
      .width(72)
      .height(46)
      .borderRadius(7)
      .borderWidth(card.id === this.activeTemplateId ? 1.5 : 1)
      .borderColor(card.id === this.activeTemplateId ? $r('app.color.amber') : $r('app.color.segment_border'))
      .backgroundColor(card.id === this.activeTemplateId ? $r('app.color.amber_soft') : $r('app.color.chip_bg'))

      Text(this.labelText(card))
        .fontSize(10)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width(72)
        .margin({ top: 6 })
        .fontColor(card.id === this.activeTemplateId ? $r('app.color.amber_deep') : $r('app.color.text_tertiary'))
        .fontWeight(card.id === this.activeTemplateId ? 600 : 400)
    }
    .width(72)
    .opacity(this.missingViews(card).length > 0 ? 0.4 : 1)
    .onClick(() => {
      this.handleTap(card)
    })
  }

  build() {
    Scroll() {
      Row({ space: 10 }) {
        ForEach(this.cards, (card: TemplateCardModel) => {
          this.card(card)
        }, (card: TemplateCardModel) => `${card.id}-${card.id === this.activeTemplateId}-${this.missingViews(card).length > 0}`)
      }
      .padding({ left: 16, right: 16 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .padding({ top: 16, bottom: 20 })
  }
}
