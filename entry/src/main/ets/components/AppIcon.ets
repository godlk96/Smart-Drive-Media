import { TemplateDefinition, TemplatePreviewSlot, resolveTemplateDefinition } from '../model/Models'

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

  @Builder
  glyph() {
    if (this.name === AppIconName.Back) {
      Path()
        .commands('M14.5 5 L7.5 12 L14.5 19')
        .stroke(this.iconColor)
        .strokeWidth(this.strokeWidth)
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
        .strokeWidth(2.4)
        .strokeLineCap(LineCapStyle.Round)
        .fill(Color.Transparent)
      Path()
        .commands('M14.8 5.5 L14.8 18.5')
        .stroke(this.iconColor)
        .strokeWidth(2.4)
        .strokeLineCap(LineCapStyle.Round)
        .fill(Color.Transparent)
    } else if (this.name === AppIconName.Scissors) {
      // 两个手柄（下）+ 两片交叉的刀刃（上）
      Path()
        .commands('M6.8 14.9 a2.35 2.35 0 1 0 0.01 0')
        .stroke(this.iconColor)
        .strokeWidth(this.strokeWidth)
        .fill(Color.Transparent)
      Path()
        .commands('M17.2 14.9 a2.35 2.35 0 1 0 0.01 0')
        .stroke(this.iconColor)
        .strokeWidth(this.strokeWidth)
        .fill(Color.Transparent)
      Path()
        .commands('M8.6 15.6 L17.4 5.4')
        .stroke(this.iconColor)
        .strokeWidth(this.strokeWidth)
        .strokeLineCap(LineCapStyle.Round)
        .fill(Color.Transparent)
      Path()
        .commands('M15.4 15.6 L6.6 5.4')
        .stroke(this.iconColor)
        .strokeWidth(this.strokeWidth)
        .strokeLineCap(LineCapStyle.Round)
        .fill(Color.Transparent)
    } else if (this.name === AppIconName.Close) {
      Path()
        .commands('M6.5 6.5 L17.5 17.5')
        .stroke(this.iconColor)
        .strokeWidth(this.strokeWidth)
        .strokeLineCap(LineCapStyle.Round)
        .fill(Color.Transparent)
      Path()
        .commands('M17.5 6.5 L6.5 17.5')
        .stroke(this.iconColor)
        .strokeWidth(this.strokeWidth)
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
          .strokeWidth(this.strokeWidth)
          .strokeLineCap(LineCapStyle.Round)
          .fill(Color.Transparent)
        Path()
          .commands('M20 9.5 L15 14.5')
          .stroke(this.iconColor)
          .strokeWidth(this.strokeWidth)
          .strokeLineCap(LineCapStyle.Round)
          .fill(Color.Transparent)
      } else {
        Path()
          .commands('M15.2 9.2 A4.4 4.4 0 0 1 15.2 14.8')
          .stroke(this.iconColor)
          .strokeWidth(this.strokeWidth)
          .strokeLineCap(LineCapStyle.Round)
          .fill(Color.Transparent)
        Path()
          .commands('M18 6.6 A8 8 0 0 1 18 17.4')
          .stroke(this.iconColor)
          .strokeWidth(this.strokeWidth)
          .strokeLineCap(LineCapStyle.Round)
          .fill(Color.Transparent)
      }
    } else if (this.name === AppIconName.Check) {
      Path()
        .commands('M5.2 12.6 L10 17.4 L18.8 6.8')
        .stroke(this.iconColor)
        .strokeWidth(2.6)
        .strokeLineCap(LineCapStyle.Round)
        .strokeLineJoin(LineJoinStyle.Round)
        .fill(Color.Transparent)
    }
  }

  build() {
    // 刻意不用 Shape.viewPort 做缩放：真机上它把路径画成约一半大小、并且贴在外框左上角，
    // 观感就是「图标又小又不居中」（截图实测返回箭头 12×20 设备px，期望 22×40）。
    // 改成在 24vp 的真实坐标系里画（盒子也设成 24，任何自动适配的缩放系数都是 1），
    // 再以 Stack 中心为原点整体缩放到 iconSize —— 尺寸和居中都由这里保证。
    Stack({ alignContent: Alignment.Center }) {
      Shape() {
        this.glyph()
      }
      .width(VIEW_BOX)
      .height(VIEW_BOX)
      .scale({ x: this.iconSize / VIEW_BOX, y: this.iconSize / VIEW_BOX })
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

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Stack({ alignContent: Alignment.TopStart }) {
        ForEach(this.definition().previewSlots, (slot: TemplatePreviewSlot) => {
          Column()
            .width(this.toPercent(slot.width))
            .height(this.toPercent(slot.height))
            .position({ x: this.toPercent(slot.x), y: this.toPercent(slot.y) })
            // 原来用 stage_divider(#1E1B17) 画槽位，跟底色 stage_bg(#14120F) 每通道只差 10，
            // 在 104×60 的缩略图里等于看不见 —— 一排模板全是同一块黑砖。
            // 换成明显更亮的暖灰，让「切几格、谁大谁小」一眼能读出来。
            .backgroundColor($r('app.color.stage_slot'))
            .borderRadius(2)
            .border({ width: 0.5, color: $r('app.color.stage_bg') })
        }, (slot: TemplatePreviewSlot) => slot.slotId)
      }
      .width(this.fittedWidth())
      .height(this.fittedHeight())
      .backgroundColor($r('app.color.stage_bg'))
      .borderRadius(2)
    }
    .width(this.boxWidth)
    .height(this.boxHeight)
  }
}
