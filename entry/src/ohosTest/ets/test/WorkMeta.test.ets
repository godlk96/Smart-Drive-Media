import { describe, it, expect } from '@ohos/hypium'
import { TimelineCase } from './TestSupport'
import { workMetaCases } from './WorkMetaCases'

export default function workMetaTest(): void {
  describe('WorkMeta.pureFunctions', () => {
    const cases: Array<TimelineCase> = workMetaCases()
    cases.forEach((testCase: TimelineCase) => {
      it(testCase.name, 0, () => {
        const failure: string = testCase.run()
        expect(failure).assertEqual('')
      })
    })
  })
}
