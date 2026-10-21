import { TemplateCardModel, TimelineTrackModel } from '../model/AppState'
import { resolveTemplateDefinition } from '../model/Models'
import { getCameraZhNameById, normalizeCameraNameById } from '../constants/AppConstants'
import { TemplateGlyph } from './AppIcon'

/**
 * 模板行（spec §5.8 / §6.7）。
 *
 * 宽度按版式比例算，但**上下都设了限**：
 *   - 高度恒定 `THUMB_HEIGHT`，几张卡一样高，行是齐的；
 *   - 宽度 = 高度 × 画布比例，夹在 [MIN_THUMB_WIDTH, MAX_THUMB_WIDTH] 之间。
 *
 * 为什么不干脆完全等宽：这些卡片承载的是**几何形状本身**，形状就是信息，
 * 全等宽会把 32:9 的「左右盲区」压成一条细带、格子里「左后/右后」的字也跟着变小。
 * 但也正因为如此，早先"只封顶不封底"的做法会让一排卡差到两倍（118 / 62 / 83 / 118），
 * 行读起来是参差的。抬一个下限之后参差从 56 收到 30，肉眼基本齐，
 * 同时每张版式图仍然按真实比例、仍然尽量大。
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
/**
 * 卡片最小宽度。
 *
 * 不设下限时，8:9 的「双录」只有 62 宽、16:9 的「四机位」有 118 宽，一排差近两倍。
 * 抬到 88 之后：双录/三机位落在 88，其余仍在 118，参差收敛到 30 —— 排是齐的，
 * 版式图也还是按真实比例画的。
 */
const MIN_THUMB_WIDTH: number = 88
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
    return Math.max(MIN_THUMB_WIDTH, Math.min(MAX_THUMB_WIDTH, Math.round(natural)))
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
   * 卡片描边宽度：选中 2，未选中 1。
   *
   * 用户早先反馈"边框可以再粗一点"时，卡里是六种暖灰微色差的槽位 ——
   * 整张卡几乎没有对比度，只能靠描边撑出形状。现在槽位是线框示意图、
   * 选中那张整块填琥珀，选中与否已经由**填充**说清楚了，
   * 描边退回去当边框用就行，不必再靠 3px 去喊。
   */
  private cardBorder(card: TemplateCardModel): number {
    return card.id === this.activeTemplateId ? 2 : 1
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
        boxHeight: THUMB_HEIGHT - this.glyphInset() * 2,
        active: card.id === this.activeTemplateId
      })
    }
    .width(this.thumbWidth(card.id))
    .height(THUMB_HEIGHT)
    // 12 → 10：圆角小一点，四个角切掉的区域跟着小，版式图就能多留一点。
    .borderRadius(10)
    .borderWidth(this.cardBorder(card))
    // 选中 = 墨色描边（和格子里墨块同一种材料），不再用琥珀
    .borderColor(card.id === this.activeTemplateId ? $r('app.color.text_primary') : $r('app.color.thumb_border'))
    // 卡面必须是**白纸**，不能是页面的暖米色。
    //
    // 原来卡面用 ed_thumb_bg(#F2EEE5)，和页面 ed_bg(#F3F1EC) 只差 1.03:1 ——
    // 四张卡几乎完全融进背景，整排看起来是"几个飘着的框"。白卡落在暖米色页面上
    // 是 1.13:1，再配一条 1.31:1 的描边，卡才有实体。
    // 选中卡保留极淡琥珀，除了整块填实之外再托起一点。
    .backgroundColor($r('app.color.card_bg'))
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
