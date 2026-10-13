import appStateModelTest from './AppStateModel.test'
import privacyMaskTest from './PrivacyMask.test'
import exportPayloadTest from './ExportPayload.test'
import timelineMathTest from './TimelineMath.test'
import timelineClockTest from './TimelineClock.test'
import previewLayoutTest from './PreviewLayout.test'

export default function testsuite(): void {
  appStateModelTest()
  privacyMaskTest()
  exportPayloadTest()
  timelineMathTest()
  timelineClockTest()
  previewLayoutTest()
}
