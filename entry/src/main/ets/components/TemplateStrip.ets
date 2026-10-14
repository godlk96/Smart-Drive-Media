import { TemplateCardModel, TimelineTrackModel } from '../model/AppState'
import { resolveTemplateDefinition } from '../model/Models'
import { getCameraZhNameById, getTemplateUiNameById, normalizeCameraNameById } from '../constants/AppConstants'
import { TemplateGlyph } from './AppIcon'

/**
 * 模板行（spec §5.8 / §6.7）：横向滚动、卡宽 104、缩略图 104×60、标签 11.5。
 *
 * 尺寸从 72×46 放大到 104×60：原来的缩略图小到读不出分屏版式，整排看着像黑砖。
 * 放大后一排放不下（440vp 屏宽约露出 3.7 张），横向滚动本来就是 spec 里的行为。
 *
 * 缺机位的模板整卡 40% 不透明且不可点，点击只上报拒绝文案（spec §5.8 保留原有 toast）。
 * 判定与文案复用 `resolveTemplateDefinition` + 机位归一化，与 `EditorViewModel` 同源，
 * 因此这里不依赖 viewmodel（组件不反向依赖 VM）。
 */
const CARD_WIDTH: number = 104
const THUMB_WIDTH: number = 104
const THUMB_HEIGHT: number = 60
const GLYPH_WIDTH: number = 96
const GLYPH_HEIGHT: number = 54
const CARD_GAP: number = 12

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
        TemplateGlyph({ templateId: card.id, boxWidth: GLYPH_WIDTH, boxHeight: GLYPH_HEIGHT })
      }
      .width(THUMB_WIDTH)
      .height(THUMB_HEIGHT)
      .borderRadius(9)
      .borderWidth(card.id === this.activeTemplateId ? 1.5 : 1)
      .borderColor(card.id === this.activeTemplateId ? $r('app.color.amber') : $r('app.color.segment_border'))
      .backgroundColor(card.id === this.activeTemplateId ? $r('app.color.amber_soft') : $r('app.color.chip_bg'))

      Text(this.labelText(card))
        .fontSize(11.5)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width(CARD_WIDTH)
        .margin({ top: 7 })
        .fontColor(card.id === this.activeTemplateId ? $r('app.color.amber_deep') : $r('app.color.text_tertiary'))
        .fontWeight(card.id === this.activeTemplateId ? 600 : 400)
    }
    .width(CARD_WIDTH)
    .opacity(this.missingViews(card).length > 0 ? 0.4 : 1)
    .onClick(() => {
      this.handleTap(card)
    })
  }

  build() {
    Scroll() {
      Row({ space: CARD_GAP }) {
        ForEach(this.cards, (card: TemplateCardModel) => {
          this.card(card)
        }, (card: TemplateCardModel) => `${card.id}-${card.id === this.activeTemplateId}-${this.missingViews(card).length > 0}`)
      }
      .padding({ left: 14, right: 14 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .padding({ top: 8, bottom: 14 })
  }
}
