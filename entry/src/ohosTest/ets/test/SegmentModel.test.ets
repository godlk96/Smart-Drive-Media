import { describe, it, expect } from '@ohos/hypium'
import { TimelineCase } from './TestSupport'
import { segmentModelCases } from './SegmentModelCases'

export default function segmentModelTest(): void {
  describe('SegmentModel.pureFunctions', () => {
    const cases: Array<TimelineCase> = segmentModelCases()
    cases.forEach((testCase: TimelineCase) => {
      it(testCase.name, 0, () => {
        const failure: string = testCase.run()
        expect(failure).assertEqual('')
      })
    })
  })
}
