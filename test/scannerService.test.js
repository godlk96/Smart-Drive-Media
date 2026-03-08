import test from 'node:test'
import assert from 'node:assert/strict'
import { ScannerService } from '../src/logic/scannerService.js'
import { TripRepository } from '../src/model/tripRepository.js'
import { TaskRunner } from '../src/logic/taskRunner.js'

test('ScannerService returns desc ordered trips and filters invalid files', async () => {
  const repository = new TripRepository()
  const taskRunner = new TaskRunner()
  const service = new ScannerService({ repository, taskRunner })

  const result = await service.scan([
    {
      filePath: 'C:/videos/DVR_LoopRecording_2026-03-01_09-00-00_Front.mp4',
      durationSec: 60
    },
    {
      filePath: 'C:/videos/DVR_LoopRecording_2026-03-01_08-30-00_Front.mp4',
      durationSec: 60
    },
    {
      filePath: 'C:/videos/random_holiday.mp4',
      durationSec: 60
    }
  ])

  assert.equal(result.length, 2)
  assert.equal(result[0].startTime > result[1].startTime, true)
})
