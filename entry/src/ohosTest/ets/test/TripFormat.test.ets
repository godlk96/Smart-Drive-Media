import { describe, it, expect } from '@ohos/hypium'
import { TimelineCase } from './TestSupport'
import { tripFormatCases } from './TripFormatCases'

export default function tripFormatTest(): void {
  describe('TripFormat.pureFunctions', () => {
    const cases: Array<TimelineCase> = tripFormatCases()
    cases.forEach((testCase: TimelineCase) => {
      it(testCase.name, 0, () => {
        const failure: string = testCase.run()
        expect(failure).assertEqual('')
      })
    })
  })
}
