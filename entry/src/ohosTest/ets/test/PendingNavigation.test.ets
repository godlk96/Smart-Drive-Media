import { describe, it, expect } from '@ohos/hypium'
import { TimelineCase } from './TestSupport'
import { pendingNavigationCases } from './PendingNavigationCases'

export default function pendingNavigationTest(): void {
  describe('PendingNavigation.pureFunctions', () => {
    const cases: Array<TimelineCase> = pendingNavigationCases()
    cases.forEach((testCase: TimelineCase) => {
      it(testCase.name, 0, () => {
        const failure: string = testCase.run()
        expect(failure).assertEqual('')
      })
    })
  })
}
