import test from 'node:test'
import assert from 'node:assert/strict'
import { ScannerService } from '../src/logic/scannerService.js'
import { TripRepository } from '../src/model/tripRepository.js'
import { TaskRunner } from '../src/logic/taskRunner.js'
import { buildStreamCopyCommand } from '../src/logic/ffmpegBuilder.js'

test('ScannerService output can be consumed by FFmpegBuilder stream copy', async () => {
  const service = new ScannerService({
    repository: new TripRepository(),
    taskRunner: new TaskRunner()
  })

  const trips = await service.scan([
    { filePath: 'C:/videos/DVR_LoopRecording_2026-03-01_08-30-00_Front.mp4' },
    { filePath: 'C:/videos/DVR_LoopRecording_2026-03-01_08-31-00_Front.mp4' }
  ])

  const frontTrack = trips[0].videoTracks.find(track => track.cameraPosition === 'Front')
  const inputFiles = frontTrack.segments.map(item => item.filePath)
  const command = buildStreamCopyCommand(inputFiles, 'output.mp4')

  assert.equal(command.type, 'stream_copy')
  assert.equal(command.concatFileContent.includes('DVR_LoopRecording_2026-03-01_08-30-00_Front.mp4'), true)
})
