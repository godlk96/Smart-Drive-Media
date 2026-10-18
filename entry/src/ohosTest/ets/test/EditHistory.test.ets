import { describe, it, expect } from '@ohos/hypium'
import { TimelineCase } from './TestSupport'
import { editHistoryCases } from './EditHistoryCases'

export default function editHistoryTest(): void {
  describe('EditHistory.pureFunctions', () => {
    const cases: Array<TimelineCase> = editHistoryCases()
    cases.forEach((testCase: TimelineCase) => {
      it(testCase.name, 0, () => {
        const failure: string = testCase.run()
        expect(failure).assertEqual('')
      })
    })
  })
}
