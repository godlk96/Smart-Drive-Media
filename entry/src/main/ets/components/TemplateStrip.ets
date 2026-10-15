import { TemplateCardModel, TimelineTrackModel } from '../model/AppState'
import { resolveTemplateDefinition } from '../model/Models'
import { getCameraZhNameById, normalizeCameraNameById } from '../constants/AppConstants'
import { TemplateGlyph } from './AppIcon'

/**
 * 模板行（spec §5.8 / §6.7）。
 *
 * 尺寸不再写死成一排同宽的卡：
 *   - 高度恒定 `THUMB_HEIGHT`，五张卡一样高，行是齐的；
 *   - 宽度按版式比例算，封顶 `MAX_THUMB_WIDTH`。
 * 于是槽位**横向永远铺满卡片**（左右不留白），比例不够高时上下留白 ——
 * 32:9 的「左右盲区」在 118×70 的卡里是 118×33 的一条，上下各留 18.5。
 *
 * 卡片下面那行模板名（防追尾双录 / 避险防加塞 …）已经删掉：一张卡就是一个版式图，
 * 机位靠槽位里的字和槽位底色区分，不再靠名字。
 *
 * 缺机位的模板整卡 40% 不透明且不可点，点击只上报拒绝文案（spec §5.8 保留原有 toast）。
 * 判定与文案复用 `resolveTemplateDefinition` + 机位归一化，与 `EditorViewModel` 同源，
 * 因此这里不依赖 viewmodel（组件不反向依赖 VM）。
 */
const THUMB_HEIGHT: number = 70
const MAX_THUMB_WIDTH: number = 118
const CARD_GAP: number = 12

@Component
export struct TemplateStrip {
  @Prop cards: Array<TemplateCardModel> = []
  @Prop timeline: Array<TimelineTrackModel> = []
  @Prop activeTemplateId: string = ''
  onSelectTemplate?: (id: string) => void
  onRejected?: (message: string) => void

  /**
   * 卡片宽度：先按高度 70 求出这个版式自然该有多宽，超上限再压回来。
   * 宽画幅（T3/T4 的 3840×1080）自然宽 249，会被压到 118 —— 这正是"最大宽度限制"。
   */
  private thumbWidth(templateId: string): number {
    const definition = resolveTemplateDefinition(templateId)
    const natural: number = THUMB_HEIGHT * (definition.canvasWidth / definition.canvasHeight)
    return Math.min(MAX_THUMB_WIDTH, Math.round(natural))
  }

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

  /**
   * 卡片描边宽度：选中 3，未选中 2（原来是 2 / 1）。
   * 用户反馈"边框可以再粗一点"—— 70 高的卡上 1px 描边几乎看不出是个框。
   */
  private cardBorder(card: TemplateCardModel): number {
    return card.id === this.activeTemplateId ? 3 : 2
  }

  /**
   * 版式图相对卡片每边内缩的距离。
   *
   * 这个数要同时躲开两样东西，取两者里的大者：
   *   1. **卡片描边**（最粗 3）—— ArkUI 的 border 画在组件内侧，
   *      版式图只要压到最外圈就被盖住；
   *   2. **圆角切角** —— 卡片圆角 10，圆弧把四个角上那块方形区域切掉了。
   *      版式图的角点在 (d, d)，要落进半径 r 的圆角矩形里需要
   *      d ≥ r(1 − 1/√2) ≈ 0.2929r，r=10 时约 2.93。
   *      槽位自己还有 2px 圆角，弧心在 (d+2, d+2)，最靠近卡片角的弧点是
   *      (d+0.59, d+0.59)，按这个点算才准 —— 结果同样是 2.93。
   *
   * 取 4 两条都满足还留了余量。T1（62×70 的竖版）最吃紧：它的版式图几乎铺满整卡，
   * 就是用户看到的"左上/右上/左下/右下四个角被吃掉"。
   */
  private glyphInset(): number {
    return 4
  }

  @Builder
  card(card: TemplateCardModel) {
    Stack({ alignContent: Alignment.Center }) {
      // 传进去的框比卡片每边小 glyphInset()（见上面的注释）；
      // TemplateGlyph 内部按 canvas 比例等比缩放，自然得出"左右铺满、上下留白"。
      TemplateGlyph({
        templateId: card.id,
        boxWidth: this.thumbWidth(card.id) - this.glyphInset() * 2,
        boxHeight: THUMB_HEIGHT - this.glyphInset() * 2
      })
    }
    .width(this.thumbWidth(card.id))
    .height(THUMB_HEIGHT)
    // 12 → 10：圆角小一点，四个角切掉的区域跟着小，版式图就能多留一点。
    .borderRadius(10)
    .borderWidth(this.cardBorder(card))
    .borderColor(card.id === this.activeTemplateId ? $r('app.color.amber') : $r('app.color.ed_line'))
    .backgroundColor($r('app.color.ed_thumb_bg'))
    // 版式图现在内缩了 4，本来就够不着圆角，这层裁切是双保险：
    // 万一以后有人把 glyphInset 调小，槽位的方角也不会漏到圆角外面。
    .clip(true)
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
      .alignItems(VerticalAlign.Top)
      .padding({ left: 14, right: 14 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .padding({ top: 10, bottom: 14 })
  }
}
