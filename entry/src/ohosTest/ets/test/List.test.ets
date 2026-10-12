import appStateModelTest from './AppStateModel.test'
import privacyMaskTest from './PrivacyMask.test'
import exportPayloadTest from './ExportPayload.test'

export default function testsuite(): void {
  appStateModelTest()
  privacyMaskTest()
  exportPayloadTest()
}
