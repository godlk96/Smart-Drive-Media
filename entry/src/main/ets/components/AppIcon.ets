import { TemplateDefinition, TemplatePreviewSlot, TemplateSlotBinding, resolveTemplateDefinition } from '../model/Models'
import { getCameraZhNameById, normalizeCameraNameById } from '../constants/AppConstants'

/**
 * 全 App 的矢量图标集。
 *
 * 为什么不用 emoji / 文本字符：`←` `▶` `✂` `✕` 的粗细、基线、左右留白都由系统字体决定，
 * 彼此不成套；emoji（📹👁️⬅️➡️🎬）更是连颜色都跟不了主题。这里统一成
 * **24×24 viewBox + 1.9 描边 + 圆头圆角 + currentColor**，靠 `Shape.viewPort` 缩放到任意尺寸，
 * 所以同一份路径在 16 / 20 / 28 上都保持一致的视觉重量。
 *
 * 零新增资源文件：全部是代码里的路径，跟 SegmentParamRow 原来的手绘喇叭是同一套做法。
 */
export enum AppIconName {
  Back = 'back',
  Play = 'play',
  Pause = 'pause',
  Scissors = 'scissors',
  Close = 'close',
  Speaker = 'speaker',
  Muted = 'muted',
  Check = 'check'
}

/** 所有图标都画在这个坐标系里，由 Shape.viewPort 缩放到实际尺寸 */
const VIEW_BOX: number = 24
const DEFAULT_STROKE: number = 1.9

@Component
export struct AppIcon {
  @Prop name: AppIconName = AppIconName.Back
  /** 不能叫 size —— 那是 CustomComponent 基类上的通用属性，重名会直接编译失败 */
  @Prop iconSize: number = 24
  @Prop iconColor: Resource = $r('app.color.text_secondary')
  @Prop strokeWidth: number = DEFAULT_STROKE

  /** play 与 check 形状太简单，描边会显脏，直接填充 */
  private isFilled(): boolean {
    return this.name === AppIconName.Play || this.name === AppIconName.Check
  }

  /** 将逻辑描边换算为 Shape(24px) 局部坐标系内的物理描边 */
  private stroke(val?: number): number {
    const raw = val !== undefined ? val : this.strokeWidth
    const converted = this.getUIContext().px2vp(raw)
    return converted > 0 ? converted : raw
  }

  /**
   * 将 24px 局部坐标系放大到 iconSize vp 所对应的设备物理像素。
   *
   * 根因说明：ArkUI 的 Path.commands 严格按物理像素 (px) 解释数值，
   * 整个矢量图绘制在 24px × 24px 画布上。在 Retina 屏（如 Mate 60 / Pura 70，
   * 像素密度比 D = vp2px(1) ≈ 3.0）上，若直接使用 24vp 容器或 viewPort({ width: 24, height: 24 })，
   * 系统将 24 理解为 24vp = 72px，导致 24px 的路径仅占画布的 1/3，视觉上极小且贴在左上角。
   *
   * 正确做法：
   * 1. Shape 显式声明为 '24px' × '24px'，使路径 (0..24px) 撑满 Shape 边界。
   * 2. scale 缩放比例设为 vp2px(iconSize) / 24，将 24px 放大至 iconSize vp 对应的实际物理像素。
   * 3. 外层包裹居中的 Stack(iconSize, iconSize)，保证在任何 DPI 屏幕上矢量图标既完全充满 iconSize，又严格居中。
   */
  private scaleFactor(): number {
    const targetPx = this.getUIContext().vp2px(this.iconSize)
    if (!targetPx || targetPx <= 0) {
      return 1
    }
    return targetPx / VIEW_BOX
  }

  @Builder
  glyph() {
    if (this.name === AppIconName.Back) {
      Path()
        .commands('M14.5 5 L7.5 12 L14.5 19')
        .stroke(this.iconColor)
        .strokeWidth(this.stroke())
        .strokeLineCap(LineCapStyle.Round)
        .strokeLineJoin(LineJoinStyle.Round)
        .fill(Color.Transparent)
    } else if (this.name === AppIconName.Play) {
      Path()
        .commands('M8.5 5.2 L18.6 12 L8.5 18.8 Z')
        .fill(this.iconColor)
        .stroke(Color.Transparent)
        .strokeWidth(0)
    } else if (this.name === AppIconName.Pause) {
      Path()
        .commands('M9.2 5.5 L9.2 18.5')
        .stroke(this.iconColor)
        .strokeWidth(this.stroke(2.4))
        .strokeLineCap(LineCapStyle.Round)
        .fill(Color.Transparent)
      Path()
        .commands('M14.8 5.5 L14.8 18.5')
        .stroke(this.iconColor)
        .strokeWidth(this.stroke(2.4))
        .strokeLineCap(LineCapStyle.Round)
        .fill(Color.Transparent)
    } else if (this.name === AppIconName.Scissors) {
      // 两个手柄（下）+ 两片交叉的刀刃（上）
      Path()
        .commands('M6.8 14.9 a2.35 2.35 0 1 0 0.01 0')
        .stroke(this.iconColor)
        .strokeWidth(this.stroke())
        .fill(Color.Transparent)
      Path()
        .commands('M17.2 14.9 a2.35 2.35 0 1 0 0.01 0')
        .stroke(this.iconColor)
        .strokeWidth(this.stroke())
        .fill(Color.Transparent)
      Path()
        .commands('M8.6 15.6 L17.4 5.4')
        .stroke(this.iconColor)
        .strokeWidth(this.stroke())
        .strokeLineCap(LineCapStyle.Round)
        .fill(Color.Transparent)
      Path()
        .commands('M15.4 15.6 L6.6 5.4')
        .stroke(this.iconColor)
        .strokeWidth(this.stroke())
        .strokeLineCap(LineCapStyle.Round)
        .fill(Color.Transparent)
    } else if (this.name === AppIconName.Close) {
      Path()
        .commands('M6.5 6.5 L17.5 17.5')
        .stroke(this.iconColor)
        .strokeWidth(this.stroke())
        .strokeLineCap(LineCapStyle.Round)
        .fill(Color.Transparent)
      Path()
        .commands('M17.5 6.5 L6.5 17.5')
        .stroke(this.iconColor)
        .strokeWidth(this.stroke())
        .strokeLineCap(LineCapStyle.Round)
        .fill(Color.Transparent)
    } else if (this.name === AppIconName.Speaker || this.name === AppIconName.Muted) {
      Path()
        .commands('M3.6 9.4 L3.6 14.6 L7.6 14.6 L12.2 18.6 L12.2 5.4 L7.6 9.4 Z')
        .fill(this.iconColor)
        .stroke(Color.Transparent)
        .strokeWidth(0)
      if (this.name === AppIconName.Muted) {
        Path()
          .commands('M15 9.5 L20 14.5')
          .stroke(this.iconColor)
          .strokeWidth(this.stroke())
          .strokeLineCap(LineCapStyle.Round)
          .fill(Color.Transparent)
        Path()
          .commands('M20 9.5 L15 14.5')
          .stroke(this.iconColor)
          .strokeWidth(this.stroke())
          .strokeLineCap(LineCapStyle.Round)
          .fill(Color.Transparent)
      } else {
        Path()
          .commands('M15.2 9.2 A4.4 4.4 0 0 1 15.2 14.8')
          .stroke(this.iconColor)
          .strokeWidth(this.stroke())
          .strokeLineCap(LineCapStyle.Round)
          .fill(Color.Transparent)
        Path()
          .commands('M18 6.6 A8 8 0 0 1 18 17.4')
          .stroke(this.iconColor)
          .strokeWidth(this.stroke())
          .strokeLineCap(LineCapStyle.Round)
          .fill(Color.Transparent)
      }
    } else if (this.name === AppIconName.Check) {
      Path()
        .commands('M5.2 12.6 L10 17.4 L18.8 6.8')
        .stroke(this.iconColor)
        .strokeWidth(this.stroke(2.6))
        .strokeLineCap(LineCapStyle.Round)
        .strokeLineJoin(LineJoinStyle.Round)
        .fill(Color.Transparent)
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Shape() {
        this.glyph()
      }
      .width('24px')
      .height('24px')
      .scale({
        x: this.scaleFactor(),
        y: this.scaleFactor(),
        centerX: '12px',
        centerY: '12px'
      })
    }
    .width(this.iconSize)
    .height(this.iconSize)
  }
}

/**
 * 模板缩略图：**不画画面，画版式**。
 *
 * emoji（📹👁️⬅️➡️🎬）表达的是"内容"，但用户选模板时真正要判断的是
 * 「这一屏会切成几格、谁大谁小」。所以这里直接按 Models.ets 的 `previewSlots`
 * 逐槽画方块 —— 缩略图与进画面后看到的分屏必然一致，改比例时图标自动跟着对。
 */
@Component
export struct TemplateGlyph {
  @Prop templateId: string = ''
  @Prop boxWidth: number = 72
  @Prop boxHeight: number = 46
  /** 选中态：整块版式图由暖黑翻成琥珀，与卡片的琥珀描边同色 */
  @Prop active: boolean = false

  private definition(): TemplateDefinition {
    return resolveTemplateDefinition(this.templateId)
  }

  /** 等比缩放，长边顶满盒子 —— 与 EditorPreviewArea 内部那层约束同一套算法 */
  private fittedWidth(): number {
    const def = this.definition()
    const canvasRatio = def.canvasWidth / def.canvasHeight
    const boxRatio = this.boxWidth / this.boxHeight
    if (canvasRatio >= boxRatio) {
      return this.boxWidth
    }
    return this.boxHeight * canvasRatio
  }

  private fittedHeight(): number {
    const def = this.definition()
    const canvasRatio = def.canvasWidth / def.canvasHeight
    const boxRatio = this.boxWidth / this.boxHeight
    if (canvasRatio >= boxRatio) {
      return this.boxWidth / canvasRatio
    }
    return this.boxHeight
  }

  private toPercent(value: number): string {
    const percent = Math.max(0, Math.min(100, value * 100))
    return `${percent}%`
  }

  /** 槽位 → 机位：直接读模板自己的 slotBindings，与 PreviewLayout 同源，不另维护映射表。 */
  private cameraOfSlot(slotId: string): string {
    const bindings: Array<TemplateSlotBinding> = this.definition().slotBindings
    const hit = bindings.find((item: TemplateSlotBinding) => item.slotId === slotId)
    return hit === undefined ? '' : String(hit.camera)
  }

  /**
   * 槽位底色 / 描边 / 字色。
   *
   * 三个版本走过：最早六个机位六种暖灰微色差（70vp 高的缩略图上根本分不出来，
   * 四张版式长得一样）；改成 ink 实心块（对比度太硬，四张卡像四块黑板）；
   * 再改成 stage_slot 暖灰（还是"一排在比谁更黑"）。
   *
   * 现在反过来做：**未选中只画线框**（白底 + 细描边 + 深字），选中的填实琥珀。
   * 于是整排缩略图平时是一组安静的示意图，只有被选中的那一张是实心的，
   * 不用靠描边粗细去比。版式仍然靠几何区分：一格 / 上下两格 / 上一下二 / 四宫格。
   */
  private slotColor(): Resource {
    return this.active ? $r('app.color.amber') : $r('app.color.card_bg')
  }

  private slotBorderColor(): Resource {
    // 未选中用 glyph_stroke（#8A867D，落在卡面上 3.05:1）而不是更浅的 segment_border：
    // 后者只有 1.13:1，线几乎融进卡面，四张缩略图看上去就是三个空框。
    // 界面里的图形按 WCAG 要 3:1 才读得出来。
    return this.active ? $r('app.color.amber') : $r('app.color.glyph_stroke')
  }

  private slotLabelColor(): Resource {
    return this.active ? $r('app.color.card_bg') : $r('app.color.text_secondary')
  }

  /** 槽位窄到 40vp 以下降一档字号，否则「左前」会顶到格子边。 */
  private labelSize(slotWidthRatio: number): number {
    return this.fittedWidth() * slotWidthRatio >= 40 ? 9.5 : 8.5
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Stack({ alignContent: Alignment.TopStart }) {
        ForEach(this.definition().previewSlots, (slot: TemplatePreviewSlot) => {
          Column() {
            Text(getCameraZhNameById(normalizeCameraNameById(this.cameraOfSlot(slot.slotId))))
              .fontSize(this.labelSize(slot.width))
              .fontWeight(FontWeight.Medium)
              .fontColor(this.slotLabelColor())
              .maxLines(1)
          }
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .width(this.toPercent(slot.width))
          .height(this.toPercent(slot.height))
          .position({ x: this.toPercent(slot.x), y: this.toPercent(slot.y) })
          .backgroundColor(this.slotColor())
          .borderRadius(2)
          // 1px 描边：未选中时它是格子的全部 —— 线框示意图就靠这层线读出版式。
          .border({ width: 1, color: this.slotBorderColor() })
        }, (slot: TemplatePreviewSlot) => slot.slotId)
      }
      .width(this.fittedWidth())
      .height(this.fittedHeight())
      .borderRadius(2)
    }
    .width(this.boxWidth)
    .height(this.boxHeight)
  }
}
