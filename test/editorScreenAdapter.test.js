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
  assert.equal(adapter.getState().layout.layers.length, 4)

  adapter.seekTo(5000)
  adapter.syncToMaster({ [CameraPosition.BACK]: 4000 })
  assert.equal(adapter.getState().syncCorrections.length, 1)

  adapter.startExport('out.mp4')
  adapter.updateExportProgress(60)
  adapter.finishExportSuccess()
  assert.equal(adapter.getState().exportStatus.statusText, 'success')
})

test('EditorScreenAdapter supports task3 timeline range and task4 template preview states', () => {
  const adapter = new EditorScreenAdapter({
    editorSession: new MultiTrackEditorSession(),
    exportStatusViewModel: new ExportStatusViewModel({ exportJobState: new ExportJobState() }),
    router: new ScreenRouter()
  })

  adapter.loadTrip({
    videoTracks: [
      {
        cameraPosition: CameraPosition.FRONT,
        segments: [
          { filePath: 'front-a.mp4', startTime: new Date(), duration: 60 },
          { filePath: 'front-b.mp4', startTime: new Date(Date.now() + 60000), duration: 60 }
        ]
      }
    ]
  })

  adapter.updateSelectionRange(10000, 70000)
  assert.deepEqual(adapter.getState().selectionRangeMs, { start: 10000, end: 70000 })
  assert.deepEqual(adapter.getState().templateDrawer.cards.map(item => item.id), ['T1', 'T2', 'T3', 'T4', 'T5'])
  assert.equal(adapter.getState().previewTemplate.aspectRatio, '32:27')

  adapter.selectTemplate('T4')
  assert.equal(adapter.getState().templateDrawer.activeTemplateId, 'T4')
  assert.equal(adapter.getState().previewTemplate.aspectRatio, '16:9')
  assert.equal(adapter.getState().previewTemplate.slots.length, 3)
  assert.equal(adapter.getState().previewTemplate.slots[0].track, CameraPosition.LEFT_FRONT)
  assert.equal(adapter.getState().previewTemplate.slots[2].track, CameraPosition.RIGHT_FRONT)
  assert.equal(adapter.getState().previewTemplate.guides.length, 2)

  adapter.setDrawerExpanded(false)
  assert.equal(adapter.getState().templateDrawer.expanded, false)

  adapter.cycleSpeed()
  assert.equal(adapter.getState().controlDeck.speed, '4.0X')
  assert.equal(adapter.getState().controlDeck.forcedMuted, true)

  adapter.toggleMuted()
  assert.equal(adapter.getState().controlDeck.muted, true)

  adapter.selectTemplate('T5')
  assert.equal(adapter.getState().templateDrawer.activeTemplateId, 'T5')
  assert.equal(adapter.getState().previewTemplate.slots.length, 1)
  assert.equal(adapter.getState().previewTemplate.slots[0].id, 'top')
  assert.equal(adapter.getState().previewTemplate.slots[0].track, CameraPosition.FRONT)
  assert.equal(adapter.getState().previewTemplate.guides.length, 0)
})

test('EditorScreenAdapter supports task6 privacy switches cinematic crop and forced mute', () => {
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

  adapter.toggleHideSpeed()
  adapter.toggleHideVin()
  adapter.toggleHideGps()
  const privacyDisabled = adapter.getState()
  assert.equal(privacyDisabled.privacyConfig.hideSpeed, false)
  assert.equal(privacyDisabled.privacyConfig.hideVin, false)
  assert.equal(privacyDisabled.privacyConfig.hideGps, false)
  assert.equal(privacyDisabled.privacyPreview.overlayMasks.length, 0)

  adapter.toggleCinematicCrop()
  const cinematicState = adapter.getState()
  assert.equal(cinematicState.privacyConfig.cinematicCrop, true)
  assert.equal(cinematicState.privacyPreview.outputAspectRatio, '21:9')

  adapter.setControlDeck({ speed: '16.0X', muted: false, watermarkEnabled: true })
  const forcedMute = adapter.getState()
  assert.equal(forcedMute.controlDeck.muted, true)
  assert.equal(forcedMute.controlDeck.forcedMuted, true)
})
