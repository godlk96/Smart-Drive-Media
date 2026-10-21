import { TemplateCardModel, TimelineTrackModel } from '../model/AppState'
import { resolveTemplateDefinition } from '../model/Models'
import { getCameraZhNameById, normalizeCameraNameById } from '../constants/AppConstants'
import { TemplateGlyph } from './AppIcon'

/**
 * 模板行（spec §5.8 / §6.7）。
 *
 * ## 这一排只由**色块**构成
 *
 * 它前后有过四版：六种机位微色差（70vp 上分不出）、近黑实心块（太硬）、
 * 暖灰实心块、白纸线框（一层卡片边 + 一层格子描边 + 9px 字，三层矩形套在一起，
 * 看起来就是四个表格单元格）。
 *
 * 现在版式图**自己就是这一格的全部**：没有卡片面、没有描边、没有圆角，
 * 只有一组实心色块。未选中是暖沙色，选中的那一组换成正墨色 —— 同一种材料，
 * 不是另一套装饰。一排看过去是四个版式示意，不是四张表。
 *
 * 每一格的占位宽度固定 `SLOT_WIDTH`，版式图在里面按真实画布比例居中缩放：
 * 8:9 的双录竖着、32:9 的左右盲区横成一条，都是它本来的形状。
 *
 * 缺机位的模板整格 40% 不透明且不可点，点击只上报拒绝文案（spec §5.8 保留原有 toast）。
 * 判定与文案复用 `resolveTemplateDefinition` + 机位归一化，与 `EditorViewModel` 同源，
 * 因此这里不依赖 viewmodel（组件不反向依赖 VM）。
 */
const SLOT_WIDTH: number = 86
const THUMB_HEIGHT: number = 72
const CARD_GAP: number = 12

@Component
export struct TemplateStrip {
  @Prop cards: Array<TemplateCardModel> = []
  @Prop timeline: Array<TimelineTrackModel> = []
  @Prop activeTemplateId: string = ''
  onSelectTemplate?: (id: string) => void
  onRejected?: (message: string) => void

  /** 这版式缺哪些机位（中文名，顿号连接）；空串表示机位齐全。 */
  private missingViews(card: TemplateCardModel): string {
    const definition = resolveTemplateDefinition(card.id)
    const tracks = this.timeline.map((item: TimelineTrackModel) => normalizeCameraNameById(item.cameraPosition))
    const missing = definition.requiredCameras
      .filter((camera) => !tracks.some((item: string) => item === normalizeCameraNameById(String(camera))))
      .map((camera) => getCameraZhNameById(normalizeCameraNameById(String(camera))))
    return missing.join('、')
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
    Stack({ alignContent: Alignment.Center }) {
      TemplateGlyph({
        templateId: card.id,
        boxWidth: SLOT_WIDTH,
        boxHeight: THUMB_HEIGHT,
        active: card.id === this.activeTemplateId
      })
    }
    .width(SLOT_WIDTH)
    .height(THUMB_HEIGHT)
    .opacity(this.missingViews(card).length > 0 ? 0.4 : 1)
    .stateStyles({
      normal: { .opacity(this.missingViews(card).length > 0 ? 0.4 : 1) },
      pressed: { .opacity(0.6) }
    })
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
      .alignItems(VerticalAlign.Top)
      // 14 → 0：模版行原来缩在白卡里，白卡自己有 14 的内边距。白卡拆掉之后
      // 这条内边距会把整行推得比视频还窄，左右对不齐。现在交给页面统一的 10。
      .padding({ left: 0, right: 0 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .padding({ top: 10, bottom: 14 })
  }
}
