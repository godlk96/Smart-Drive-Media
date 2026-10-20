import { describe, it, expect } from '@ohos/hypium'
import { TimelineCase } from './TestSupport'
import { workRestoreCases } from './WorkRestoreCases'

export default function workRestoreTest(): void {
  describe('WorkRestore.pureFunctions', () => {
    const cases: Array<TimelineCase> = workRestoreCases()
    cases.forEach((testCase: TimelineCase) => {
      it(testCase.name, 0, () => {
        const failure: string = testCase.run()
        expect(failure).assertEqual('')
      })
    })
  })
}
