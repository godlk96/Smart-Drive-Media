import appStateModelTest from './AppStateModel.test'
import exportPayloadTest from './ExportPayload.test'
import timelineMathTest from './TimelineMath.test'
import timelineClockTest from './TimelineClock.test'
import previewLayoutTest from './PreviewLayout.test'
import segmentModelTest from './SegmentModel.test'
import tripFormatTest from './TripFormat.test'
import editHistoryTest from './EditHistory.test'
import editRestoreTest from './EditRestore.test'
import workMetaTest from './WorkMeta.test'
import workRestoreTest from './WorkRestore.test'
import pendingNavigationTest from './PendingNavigation.test'

export default function testsuite(): void {
  appStateModelTest()
  exportPayloadTest()
  timelineMathTest()
  timelineClockTest()
  previewLayoutTest()
  segmentModelTest()
  tripFormatTest()
  editHistoryTest()
  editRestoreTest()
  workMetaTest()
  workRestoreTest()
  pendingNavigationTest()
}
