import test from 'node:test'
import assert from 'node:assert/strict'
import { bindLibraryScreen, bindEditorScreen } from '../src/ui/screenBindings.js'
import { TripLibraryScreenAdapter } from '../src/ui/tripLibraryScreenAdapter.js'
import { EditorScreenAdapter } from '../src/ui/editorScreenAdapter.js'
import { ScreenRouter } from '../src/ui/screenRouter.js'
import { TripLibraryViewModel } from '../src/viewmodel/tripLibraryViewModel.js'
import { MultiTrackEditorSession } from '../src/logic/multiTrackEditorSession.js'
import { ExportStatusViewModel } from '../src/viewmodel/exportStatusViewModel.js'
import { ExportJobState } from '../src/logic/exportJobState.js'
import { CameraPosition } from '../src/model/types.js'

test('bindLibraryScreen publishes state updates on initialize and openTrip', async () => {
  const viewModel = new TripLibraryViewModel({
    passiveImportController: {
      async start() {
        return [
          {
            id: 'trip-9',
            startTime: new Date('2026-03-07T08:00:00'),
            endTime: new Date('2026-03-07T08:20:00'),
            duration: 1200,
            thumbnailUrl: 'thumb.jpg',
            videoTracks: [{}, {}, {}]
          }
        ]
      }
    }
  })
  const binding = bindLibraryScreen(
    new TripLibraryScreenAdapter({
      viewModel,
      router: new ScreenRouter()
    })
  )

  const events = []
  const unsubscribe = binding.subscribe(state => events.push(state.route.current.name))
  const initState = await binding.initialize()
  assert.equal(initState.cards.length, 1)
  binding.openTrip('trip-9')
  unsubscribe()

  assert.equal(events[0], 'trip_library')
  assert.equal(events[1], 'editor')
})

test('bindEditorScreen publishes status and timeline updates', () => {
  const binding = bindEditorScreen(
    new EditorScreenAdapter({
      editorSession: new MultiTrackEditorSession(),
      exportStatusViewModel: new ExportStatusViewModel({ exportJobState: new ExportJobState() }),
      router: new ScreenRouter()
    })
  )

  const events = []
  binding.subscribe(state => events.push(state.exportStatus.statusText))
  binding.loadTrip({
    videoTracks: [
      {
        cameraPosition: CameraPosition.FRONT,
        segments: [{ filePath: 'front.mp4', startTime: new Date(), duration: 60 }]
      }
    ]
  })
  binding.startExport('output.mp4')
  binding.updateSelectionRange(5000, 30000)
  binding.selectTemplate('T3')
  binding.setDrawerExpanded(false)
  binding.updateExportProgress(80)
  const finalState = binding.finishExportSuccess()

  assert.equal(finalState.timeline.length, 6)
  assert.equal(finalState.templateDrawer.activeTemplateId, 'T3')
  assert.deepEqual(finalState.selectionRangeMs, { start: 5000, end: 30000 })
  assert.equal(finalState.templateDrawer.expanded, false)
  assert.equal(finalState.exportStatus.statusText, 'success')
  assert.equal(events.includes('running'), true)
  assert.equal(events[events.length - 1], 'success')
})
