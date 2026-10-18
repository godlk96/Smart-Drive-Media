import { describe, it, expect } from '@ohos/hypium'
import { TimelineCase } from './TestSupport'
import { editRestoreCases } from './EditRestoreCases'

export default function editRestoreTest(): void {
  describe('EditRestore.pureFunctions', () => {
    const cases: Array<TimelineCase> = editRestoreCases()
    cases.forEach((testCase: TimelineCase) => {
      it(testCase.name, 0, () => {
        const failure: string = testCase.run()
        expect(failure).assertEqual('')
      })
    })
  })
}
