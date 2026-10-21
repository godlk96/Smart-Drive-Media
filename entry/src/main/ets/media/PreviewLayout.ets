/**
 * 预览布局的纯函数层：模板 → 槽位几何。
 *
 * 这里刻意**不再保存第二套几何定义**。
 * 旧的 EditorPreviewArea.resolveLayout() 与 Models.TEMPLATE_DEFINITION_MAP[].previewSlots 是两份会漂移的副本，
 * T6 就已经漂了（预览 0.25/0.5/0.25，模型 0.3333/0.3334/0.3333），
 * 而原生导出（entry/src/main/cpp/export_engine.cpp:264-270）用的是 960/1920/960 = 0.25/0.5/0.25。
 * 现在唯一来源是 TEMPLATE_DEFINITION_MAP，本文件只负责把它翻译成可渲染的槽位。
 */

import {
  TemplateDefinition,
  TemplatePreviewSlot,
  TemplateSlotBinding,
  resolveTemplateDefinition,
  toLegacyCamera
} from '../model/Models'

/**
 * 常驻槽位数量上限。组件树里永远渲染这么多个 XComponent，模板只改属性，避免重建 Surface。
 *
 * 取 4 是因为 T4「四机位」是 2×2 四宫格。对 T2–T1 来说多出来的第 4 个槽位
 * `visible=false` 且 `bindSegments([])`，既不显示也不解码，代价与原来第 3 个槽位在
 * T2/T1 下闲置时完全一致。
 */
export const MAX_PREVIEW_SLOTS: number = 4

/** 一个渲染槽位的完整描述：几何 + 机位 + 可见性。 */
export class SlotGeometry {
  slotId: string = ''
  /** 旧式机位名（'Front' / 'Back' / 'Left' / 'Right' / 'LeftFront' / 'RightFront'），与 DvrMeta.camera 同一命名空间。 */
  camera: string = ''
  x: number = 0
  y: number = 0
  width: number = 1
  height: number = 1
  zoomX: number = 1
  visible: boolean = true
}

/** 槽位 → 机位：直接读模板自己的 slotBindings，不再维护一张平行的映射表。 */
export function cameraForSlot(definition: TemplateDefinition, slotId: string): string {
  for (let i = 0; i < definition.slotBindings.length; i++) {
    const binding: TemplateSlotBinding = definition.slotBindings[i]
    if (binding.slotId === slotId) {
      return toLegacyCamera(binding.camera)
    }
  }
  return ''
}

/** 模板 → 槽位几何数组（按 previewSlots 的声明顺序，最多 MAX_PREVIEW_SLOTS 个）。 */
export function buildSlotGeometry(templateId: string): Array<SlotGeometry> {
  const definition: TemplateDefinition = resolveTemplateDefinition(templateId)
  const out: Array<SlotGeometry> = []
  for (let i = 0; i < definition.previewSlots.length && out.length < MAX_PREVIEW_SLOTS; i++) {
    const slot: TemplatePreviewSlot = definition.previewSlots[i]
    const geometry = new SlotGeometry()
    geometry.slotId = slot.slotId
    geometry.camera = cameraForSlot(definition, slot.slotId)
    geometry.x = slot.x
    geometry.y = slot.y
    geometry.width = slot.width
    geometry.height = slot.height
    geometry.zoomX = slot.zoomX !== undefined && slot.zoomX > 0 ? slot.zoomX : 1
    geometry.visible = true
    out.push(geometry)
  }
  return out
}

/** 预览容器宽高比 = 导出画布宽高比。同一个来源，所以"预览所见 = 导出所得"由构造保证。 */
export function templateAspectRatio(templateId: string): number {
  const definition: TemplateDefinition = resolveTemplateDefinition(templateId)
  if (definition.canvasHeight <= 0) {
    return 16 / 9
  }
  return definition.canvasWidth / definition.canvasHeight
}

/** 模板需要的机位列表（去重、保持声明顺序）。用于判断某槽位切换后是否需要换媒体源。 */
export function templateCameras(templateId: string): Array<string> {
  const definition: TemplateDefinition = resolveTemplateDefinition(templateId)
  const out: Array<string> = []
  for (let i = 0; i < definition.slotBindings.length; i++) {
    const camera = toLegacyCamera(definition.slotBindings[i].camera)
    if (camera.length > 0 && out.indexOf(camera) < 0) {
      out.push(camera)
    }
  }
  return out
}

/** 该模板是否用到某个机位。 */
export function templateUsesCamera(templateId: string, camera: string): boolean {
  return templateCameras(templateId).indexOf(camera) >= 0
}

/** 某机位在该模板下的槽位下标；未使用返回 -1。 */
export function slotIndexOfCamera(templateId: string, camera: string): number {
  const geometry = buildSlotGeometry(templateId)
  for (let i = 0; i < geometry.length; i++) {
    if (geometry[i].camera === camera) {
      return i
    }
  }
  return -1
}

/** 机位在模板里是否作为「主时钟轨」（优先 Front，其次声明顺序第一个）。 */
export function resolveClockCamera(templateId: string): string {
  const cameras = templateCameras(templateId)
  if (cameras.indexOf('Front') >= 0) {
    return 'Front'
  }
  if (cameras.length > 0) {
    return cameras[0]
  }
  return 'Front'
}
