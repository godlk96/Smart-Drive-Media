import { describe, it, expect } from '@ohos/hypium'
import {
  CameraPosition,
  DEFAULT_TEMPLATE_ID,
  TemplateId,
  isTemplateId,
  listTemplateDefinitions,
  normalizeTemplateIdValue,
  resolveTemplateDefinition,
  toCameraPosition,
  toLegacyCamera
} from '../../../main/ets/model/Models'

export default function appStateModelTest(): void {
  describe('Models.templateDefinitions', () => {
    it('T1 必需机位为前+后（不含左右）', 0, () => {
      const t1 = resolveTemplateDefinition('T1')
      expect(t1.requiredCameras.length).assertEqual(2)
      expect(t1.requiredCameras[0]).assertEqual(CameraPosition.FRONT)
      expect(t1.requiredCameras[1]).assertEqual(CameraPosition.REAR)
    })

    it('T2 必需机位为前+左+右（不含后）', 0, () => {
      const t2 = resolveTemplateDefinition('T2')
      expect(t2.requiredCameras.length).assertEqual(3)
      expect(t2.requiredCameras[0]).assertEqual(CameraPosition.FRONT)
      expect(t2.requiredCameras[1]).assertEqual(CameraPosition.LEFT)
      expect(t2.requiredCameras[2]).assertEqual(CameraPosition.RIGHT)
    })

    it('T3 必需机位为左+右', 0, () => {
      const t3 = resolveTemplateDefinition('T3')
      expect(t3.requiredCameras.length).assertEqual(2)
      expect(t3.requiredCameras[0]).assertEqual(CameraPosition.LEFT)
      expect(t3.requiredCameras[1]).assertEqual(CameraPosition.RIGHT)
    })

    it('T4 存在且必需机位为左前+前+右前', 0, () => {
      const t4 = resolveTemplateDefinition('T4')
      expect(t4.templateId).assertEqual(TemplateId.T4)
      expect(t4.requiredCameras.length).assertEqual(3)
      expect(t4.requiredCameras[0]).assertEqual(CameraPosition.LEFT_FRONT)
      expect(t4.requiredCameras[1]).assertEqual(CameraPosition.FRONT)
      expect(t4.requiredCameras[2]).assertEqual(CameraPosition.RIGHT_FRONT)
    })

    it('T5 必需机位仅前视', 0, () => {
      const t5 = resolveTemplateDefinition('T5')
      expect(t5.requiredCameras.length).assertEqual(1)
      expect(t5.requiredCameras[0]).assertEqual(CameraPosition.FRONT)
    })

    it('共 6 套模板且默认模板为 T2', 0, () => {
      expect(listTemplateDefinitions().length).assertEqual(6)
      expect(DEFAULT_TEMPLATE_ID).assertEqual(TemplateId.T2)
    })

    it('T6 四机位：2×2 四格、四路必需机位、画布 3840×2160', 0, () => {
      const t6 = resolveTemplateDefinition('T6')
      expect(t6.canvasWidth).assertEqual(3840)
      expect(t6.canvasHeight).assertEqual(2160)
      expect(t6.slotBindings.length).assertEqual(4)
      expect(t6.previewSlots.length).assertEqual(4)
      expect(t6.requiredCameras.length).assertEqual(4)
      expect(t6.requiredCameras[0]).assertEqual(CameraPosition.FRONT)
      expect(t6.requiredCameras[1]).assertEqual(CameraPosition.REAR)
      expect(t6.requiredCameras[2]).assertEqual(CameraPosition.LEFT)
      expect(t6.requiredCameras[3]).assertEqual(CameraPosition.RIGHT)
      // 四机位是唯一需要第 4 路轨道的模板：原生契约与 ffmpegPolicy 必须同时为真。
      expect(t6.ffmpegPolicy.needSideTrack).assertTrue()
      expect(t6.ffmpegPolicy.needSide2Track).assertTrue()
    })

    it('非法模板 ID 归一化为默认模板', 0, () => {
      expect(normalizeTemplateIdValue('T99')).assertEqual(DEFAULT_TEMPLATE_ID)
      expect(normalizeTemplateIdValue('')).assertEqual(DEFAULT_TEMPLATE_ID)
      expect(isTemplateId('T3')).assertTrue()
      expect(isTemplateId('T99')).assertFalse()
    })

    it('机位命名双向转换保持一致（含 REAR <-> Back）', 0, () => {
      expect(toLegacyCamera(CameraPosition.FRONT)).assertEqual('Front')
      expect(toLegacyCamera(CameraPosition.REAR)).assertEqual('Back')
      expect(toLegacyCamera(CameraPosition.LEFT_FRONT)).assertEqual('LeftFront')
      expect(toCameraPosition('Back')).assertEqual(CameraPosition.REAR)
      expect(toCameraPosition('LeftFront')).assertEqual(CameraPosition.LEFT_FRONT)
      expect(toCameraPosition('Unknown')).assertEqual(CameraPosition.FRONT)
    })
  })
}
