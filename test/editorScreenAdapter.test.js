import test from 'node:test'
import assert from 'node:assert/strict'
import { EditorScreenAdapter } from '../src/ui/editorScreenAdapter.js'
import { MultiTrackEditorSession } from '../src/logic/multiTrackEditorSession.js'
import { ExportStatusViewModel } from '../src/viewmodel/exportStatusViewModel.js'
import { ExportJobState } from '../src/logic/exportJobState.js'
import { ScreenRouter } from '../src/ui/screenRouter.js'
import { Orientation } from '../src/logic/editorLayout.js'
import { CameraPosition } from '../src/model/types.js'

test('EditorScreenAdapter exposes layout sync and export status', () => {
  const adapter = new EditorScreenAdapter({
    editorSession: new MultiTrackEditorSession(),
    exportStatusViewModel: new ExportStatusViewModel({ exportJobState: new ExportJobState() }),
    router: new ScreenRouter()
  })

  adapter.loadTrip({
    videoTracks: [
      {
        cameraPosition: CameraPosition.FRONT,
        segments: [{ filePath: 'front.mp4', startTime: new Date(), duration: 60 }]
      }
    ]
  })
  assert.equal(adapter.getState().timeline.length, 6)

  adapter.setOrientation(Orientation.LANDSCAPE)
  assert.equal(adapter.getState().layout.preview.region, 'left')

  adapter.seekTo(5000)
  adapter.syncToMaster({ [CameraPosition.BACK]: 4000 })
  assert.equal(adapter.getState().syncCorrections.length, 1)

  adapter.startExport('out.mp4')
  adapter.updateExportProgress(60)
  adapter.finishExportSuccess()
  assert.equal(adapter.getState().exportStatus.statusText, 'success')
})
