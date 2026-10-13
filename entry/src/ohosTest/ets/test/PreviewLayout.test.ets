import { describe, it, expect } from '@ohos/hypium'
import { TimelineCase } from './TestSupport'
import { previewLayoutCases } from './PreviewLayoutCases'

/**
 * 预览布局（模板几何）的设备端测试。
 *
 * 用例本体写在 PreviewLayoutCases.ets（不依赖 hypium），
 * 同一份用例也能在本机离线跑：node tools/offline-test.mjs
 */
export default function previewLayoutTest(): void {
  describe('PreviewLayout.templateGeometry', () => {
    const cases: Array<TimelineCase> = previewLayoutCases()
    cases.forEach((testCase: TimelineCase) => {
      it(testCase.name, 0, () => {
        const failure: string = testCase.run()
        // 失败时 failure 就是具体原因，会出现在 hypium 的 actual 里
        expect(failure).assertEqual('')
      })
    })
  })
}
