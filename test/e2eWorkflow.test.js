import test from 'node:test'
import assert from 'node:assert/strict'
import { TripRepository } from '../src/model/tripRepository.js'
import { TaskRunner } from '../src/logic/taskRunner.js'
import { ScannerService } from '../src/logic/scannerService.js'
import { PassiveImportController } from '../src/logic/passiveImportController.js'
import { TripLibraryViewModel } from '../src/viewmodel/tripLibraryViewModel.js'
import { MultiTrackEditorSession } from '../src/logic/multiTrackEditorSession.js'
import { ExportEngine } from '../src/logic/exportEngine.js'
import { ExportJobState } from '../src/logic/exportJobState.js'

test('E2E flow: startup scan -> open trip -> seek -> export -> complete', async () => {
  const scannerService = new ScannerService({
    repository: new TripRepository(),
    taskRunner: new TaskRunner()
  })

  const fileSource = {
    async listFiles() {
      return [
        { filePath: 'C:/videos/DVR_LoopRecording_2026-03-01_08-30-00_Front.mp4' },
        { filePath: 'C:/videos/DVR_LoopRecording_2026-03-01_08-30-00_Back.mp4' },
        { filePath: 'C:/videos/DVR_LoopRecording_2026-03-01_08-31-00_Front.mp4' }
      ]
    }
  }

  const importController = new PassiveImportController({ scannerService, fileSource })
  const libraryVM = new TripLibraryViewModel({ passiveImportController: importController })
  const libraryState = await libraryVM.initialize()
  assert.equal(libraryState.cards.length, 1)

  const trips = await importController.start()
  const editor = new MultiTrackEditorSession()
  editor.loadTrip(trips[0])
  const position = editor.seekTo(12_000)
  assert.equal(position, 12_000)

  const exportEngine = new ExportEngine()
  const exportPlan = exportEngine.createPlan({
    inputFiles: ['C:/videos/DVR_LoopRecording_2026-03-01_08-30-00_Front.mp4'],
    outputPath: 'C:/videos/output.mp4',
    trackCount: 1,
    privacyConfig: { hideSpeed: false, hideVin: false, hideGps: false }
  })
  assert.equal(exportPlan.type, 'stream_copy')

  const job = new ExportJobState()
  job.start('C:/videos/output.mp4')
  job.updateProgress(100)
  const final = job.succeed()
  assert.equal(final.status, 'success')
})
