import { TimelineCase, expectNumber, expectString, expectTrue, firstError } from './TestSupport'
import {
  MAX_PREVIEW_SLOTS,
  SlotGeometry,
  buildSlotGeometry,
  resolveClockCamera,
  slotIndexOfCamera,
  templateAspectRatio,
  templateCameras,
  templateUsesCamera
} from '../../../main/ets/media/PreviewLayout'
import { TemplateDefinition, listTemplateDefinitions } from '../../../main/ets/model/Models'

/**
 * 预览布局纯函数的用例本体（不依赖 hypium）。
 *
 * 这些断言守卫的是"预览几何与导出几何同源"这件事：
 * 旧代码里 EditorPreviewArea.resolveLayout() 与 Models.TEMPLATE_DEFINITION_MAP[].previewSlots
 * 是两份会漂移的副本，T4 已经漂了。现在只有一份，这里把它的形状钉死，
 * 任何一次"顺手改一下预览布局"都会让测试红，而不是等到导出的成片里才发现。
 */

function makeCase(name: string, run: () => string): TimelineCase {
  const testCase = new TimelineCase()
  testCase.name = name
  testCase.run = run
  return testCase
}

export function previewLayoutCases(): Array<TimelineCase> {
  const cases: Array<TimelineCase> = []

  cases.push(makeCase('buildSlotGeometry: T1 上下两格（Front/Back 各占一半高度）', (): string => {
    const slots: Array<SlotGeometry> = buildSlotGeometry('T1')
    if (slots.length !== 2) {
      return `槽位数: 期望 2，实际 ${slots.length}`
    }
    return firstError([
      expectString(slots[0].slotId, 'top', 'slot[0].slotId'),
      expectString(slots[0].camera, 'Front', 'slot[0].camera'),
      expectNumber(slots[0].y, 0, 'slot[0].y'),
      expectNumber(slots[0].height, 0.5, 'slot[0].height'),
      expectString(slots[1].camera, 'Back', 'slot[1].camera'),
      expectNumber(slots[1].y, 0.5, 'slot[1].y'),
      expectNumber(slots[1].height, 0.5, 'slot[1].height')
    ])
  }))

  cases.push(makeCase('buildSlotGeometry: T2 倒品字（Front 占上 2/3，左右各占下 1/3）', (): string => {
    const slots: Array<SlotGeometry> = buildSlotGeometry('T2')
    if (slots.length !== 3) {
      return `槽位数: 期望 3，实际 ${slots.length}`
    }
    return firstError([
      expectString(slots[0].camera, 'Front', 'slot[0].camera'),
      expectNumber(slots[0].width, 1, 'slot[0].width'),
      expectNumber(slots[0].height, 0.6667, 'slot[0].height'),
      expectString(slots[1].camera, 'Left', 'slot[1].camera'),
      expectNumber(slots[1].x, 0, 'slot[1].x'),
      expectNumber(slots[1].y, 0.6667, 'slot[1].y'),
      expectString(slots[2].camera, 'Right', 'slot[2].camera'),
      expectNumber(slots[2].x, 0.5, 'slot[2].x')
    ])
  }))

  cases.push(makeCase('buildSlotGeometry: T3 左右分屏（Left/Right 各占一半宽度）', (): string => {
    const slots: Array<SlotGeometry> = buildSlotGeometry('T3')
    if (slots.length !== 2) {
      return `槽位数: 期望 2，实际 ${slots.length}`
    }
    return firstError([
      expectString(slots[0].camera, 'Left', 'slot[0].camera'),
      expectNumber(slots[0].width, 0.5, 'slot[0].width'),
      expectNumber(slots[0].height, 1, 'slot[0].height'),
      expectString(slots[1].camera, 'Right', 'slot[1].camera'),
      expectNumber(slots[1].x, 0.5, 'slot[1].x'),
      expectNumber(slots[1].width, 0.5, 'slot[1].width')
    ])
  }))

  cases.push(makeCase('buildSlotGeometry: T4 横向三分屏与原生 crop 一致（0.25/0.5/0.25，左右 zoomX=2）', (): string => {
    const slots: Array<SlotGeometry> = buildSlotGeometry('T4')
    if (slots.length !== 3) {
      return `槽位数: 期望 3，实际 ${slots.length}`
    }
    return firstError([
      // 原生 export_engine.cpp:264-270 把 side/back 各 crop 成 960 宽、front 保持 1920 宽，
      // hstack 之后就是 960/1920/960 = 0.25/0.5/0.25。旧预览写的是 0.3333/0.3334/0.3333，是错的。
      expectString(slots[0].camera, 'LeftFront', 'slot[0].camera'),
      expectNumber(slots[0].width, 0.25, 'slot[0].width'),
      expectNumber(slots[0].zoomX, 2, 'slot[0].zoomX（crop 出来的窄条要横向放大）'),
      expectString(slots[1].camera, 'Front', 'slot[1].camera'),
      expectNumber(slots[1].x, 0.25, 'slot[1].x'),
      expectNumber(slots[1].width, 0.5, 'slot[1].width'),
      expectNumber(slots[1].zoomX, 1, 'slot[1].zoomX'),
      expectString(slots[2].camera, 'RightFront', 'slot[2].camera'),
      expectNumber(slots[2].x, 0.75, 'slot[2].x'),
      expectNumber(slots[2].width, 0.25, 'slot[2].width'),
      expectNumber(slots[2].zoomX, 2, 'slot[2].zoomX')
    ])
  }))

  cases.push(makeCase('buildSlotGeometry: T5 单前视满屏', (): string => {
    const slots: Array<SlotGeometry> = buildSlotGeometry('T5')
    if (slots.length !== 1) {
      return `槽位数: 期望 1，实际 ${slots.length}`
    }
    return firstError([
      expectString(slots[0].camera, 'Front', 'slot[0].camera'),
      expectNumber(slots[0].width, 1, 'slot[0].width'),
      expectNumber(slots[0].height, 1, 'slot[0].height'),
      expectNumber(slots[0].zoomX, 1, 'slot[0].zoomX')
    ])
  }))

  cases.push(makeCase('buildSlotGeometry: 所有模板的槽位都在 [0,1] 内且不越界', (): string => {
    const definitions: Array<TemplateDefinition> = listTemplateDefinitions()
    const problems: Array<string> = []
    for (let i = 0; i < definitions.length; i++) {
      const slots: Array<SlotGeometry> = buildSlotGeometry(definitions[i].templateId)
      for (let j = 0; j < slots.length; j++) {
        const slot = slots[j]
        const outOfRange =
          slot.x < 0 || slot.y < 0 || slot.width <= 0 || slot.height <= 0 ||
          slot.x + slot.width > 1.0001 || slot.y + slot.height > 1.0001
        if (outOfRange) {
          problems.push(`${definitions[i].templateId}.${slot.slotId}=(${slot.x},${slot.y},${slot.width},${slot.height})`)
        }
      }
    }
    return firstError([expectTrue(problems.length === 0, `越界槽位：${problems.join(' ')}`)])
  }))

  cases.push(makeCase('buildSlotGeometry: 每个模板的槽位面积之和铺满整块画布（=1）', (): string => {
    const definitions: Array<TemplateDefinition> = listTemplateDefinitions()
    const problems: Array<string> = []
    for (let i = 0; i < definitions.length; i++) {
      const slots: Array<SlotGeometry> = buildSlotGeometry(definitions[i].templateId)
      let area = 0
      for (let j = 0; j < slots.length; j++) {
        area += slots[j].width * slots[j].height
      }
      if (Math.abs(area - 1) > 0.001) {
        problems.push(`${definitions[i].templateId}: 面积和 ${area}`)
      }
    }
    return firstError([expectTrue(problems.length === 0, `未铺满画布：${problems.join(' ')}`)])
  }))

  cases.push(makeCase('buildSlotGeometry: 槽位数不超过 MAX_PREVIEW_SLOTS（常驻 Surface 数量上限）', (): string => {
    const definitions: Array<TemplateDefinition> = listTemplateDefinitions()
    const problems: Array<string> = []
    for (let i = 0; i < definitions.length; i++) {
      const slots: Array<SlotGeometry> = buildSlotGeometry(definitions[i].templateId)
      if (slots.length > MAX_PREVIEW_SLOTS) {
        problems.push(`${definitions[i].templateId}: ${slots.length} > ${MAX_PREVIEW_SLOTS}`)
      }
    }
    return firstError([expectTrue(problems.length === 0, problems.join(' '))])
  }))

  cases.push(makeCase('buildSlotGeometry: 未知模板 id 回退到默认模板', (): string => {
    const fallback: Array<SlotGeometry> = buildSlotGeometry('NOT_A_TEMPLATE')
    const defaultSlots: Array<SlotGeometry> = buildSlotGeometry('T2')
    return firstError([
      expectNumber(fallback.length, defaultSlots.length, '回退后的槽位数'),
      expectString(fallback[0].slotId, defaultSlots[0].slotId, '回退后的首个 slotId'),
      expectString(fallback[0].camera, defaultSlots[0].camera, '回退后的首个机位')
    ])
  }))

  cases.push(makeCase('templateAspectRatio: 预览容器比例 == 导出画布比例', (): string => {
    const definitions: Array<TemplateDefinition> = listTemplateDefinitions()
    const problems: Array<string> = []
    for (let i = 0; i < definitions.length; i++) {
      const definition = definitions[i]
      const expected = definition.canvasWidth / definition.canvasHeight
      const actual = templateAspectRatio(definition.templateId)
      if (Math.abs(actual - expected) > 1e-9) {
        problems.push(`${definition.templateId}: 期望 ${expected}，实际 ${actual}`)
      }
    }
    const t4 = templateAspectRatio('T4')
    const t5 = templateAspectRatio('T5')
    return firstError([
      expectTrue(problems.length === 0, problems.join(' ')),
      expectTrue(Math.abs(t5 - 16 / 9) < 1e-9, `T5 应为 16:9，实际 ${t5}`),
      // T4 是 3840x1080 的超宽画布；如果这里等于 16:9，说明画布字段没接上。
      expectTrue(Math.abs(t4 - t5) > 1, `T4(${t4}) 不应等于 T5(${t5})`)
    ])
  }))

  cases.push(makeCase('templateCameras / templateUsesCamera: T4 用到 LeftFront/Front/RightFront', (): string => {
    const cameras: Array<string> = templateCameras('T4')
    if (cameras.length !== 3) {
      return `机位数: 期望 3，实际 ${cameras.length}`
    }
    return firstError([
      expectString(cameras[0], 'LeftFront', 'cameras[0]'),
      expectString(cameras[1], 'Front', 'cameras[1]'),
      expectString(cameras[2], 'RightFront', 'cameras[2]'),
      expectTrue(templateUsesCamera('T4', 'Front'), 'T4 应使用 Front'),
      expectTrue(!templateUsesCamera('T3', 'Front'), 'T3 不应使用 Front')
    ])
  }))

  cases.push(makeCase('slotIndexOfCamera: T4 的 Front 在中间槽位，T3 的 Back 不存在', (): string => {
    return firstError([
      expectNumber(slotIndexOfCamera('T4', 'Front'), 1, 'T4.Front 槽位下标'),
      expectNumber(slotIndexOfCamera('T4', 'LeftFront'), 0, 'T4.LeftFront 槽位下标'),
      expectNumber(slotIndexOfCamera('T3', 'Back'), -1, 'T3 没有 Back 槽位')
    ])
  }))

  cases.push(makeCase('resolveClockCamera: 有 Front 就用 Front，否则用声明顺序第一个', (): string => {
    return firstError([
      expectString(resolveClockCamera('T1'), 'Front', 'T1'),
      expectString(resolveClockCamera('T2'), 'Front', 'T2'),
      expectString(resolveClockCamera('T5'), 'Front', 'T5'),
      // T3 只有 Left/Right，没有 Front，只能退化为声明顺序第一个
      expectString(resolveClockCamera('T3'), 'Left', 'T3')
    ])
  }))

  return cases
}
