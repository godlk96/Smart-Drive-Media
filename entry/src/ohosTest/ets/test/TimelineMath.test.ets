import { describe, it, expect } from '@ohos/hypium'
import { TimelineCase } from './TestSupport'
import { timelineMathCases } from './TimelineMathCases'

/**
 * 纯函数层的设备端测试。
 *
 * 用例本体写在 TimelineMathCases.ets（不依赖 hypium），
 * 同一份用例也能在本机离线跑：node --experimental-transform-types tools/offline-test.mjs
 * 这样"本机绿"和"设备绿"不会因为两份断言而漂移。
 */
export default function timelineMathTest(): void {
  describe('TimelineMath.pureFunctions', () => {
    const cases: Array<TimelineCase> = timelineMathCases()
    cases.forEach((testCase: TimelineCase) => {
      it(testCase.name, 0, () => {
        const failure: string = testCase.run()
        // 失败时 failure 就是具体原因，会出现在 hypium 的 actual 里
        expect(failure).assertEqual('')
      })
    })
  })
}
