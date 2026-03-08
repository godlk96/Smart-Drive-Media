import test from 'node:test'
import assert from 'node:assert/strict'
import { ScannerService } from '../src/logic/scannerService.js'
import { TripRepository } from '../src/model/tripRepository.js'
import { TaskRunner } from '../src/logic/taskRunner.js'

function createSyntheticFiles() {
  const files = []
  const start = new Date('2026-03-01T08:00:00')
  for (let i = 0; i < 360; i += 1) {
    const time = new Date(start.getTime() + i * 60 * 1000)
    const date = `${time.getFullYear()}-${String(time.getMonth() + 1).padStart(2, '0')}-${String(
      time.getDate()
    ).padStart(2, '0')}`
    const clock = `${String(time.getHours()).padStart(2, '0')}-${String(time.getMinutes()).padStart(
      2,
      '0'
    )}-${String(time.getSeconds()).padStart(2, '0')}`
    files.push({
      filePath: `C:/videos/DVR_LoopRecording_${date}_${clock}_Front.mp4`,
      durationSec: 60
    })
  }
  return files
}

test('ScannerService aggregates one-hour scale data under target time', async () => {
  const service = new ScannerService({
    repository: new TripRepository(),
    taskRunner: new TaskRunner()
  })
  const files = createSyntheticFiles()
  const started = Date.now()
  const trips = await service.scan(files)
  const elapsedMs = Date.now() - started

  assert.equal(trips.length > 0, true)
  assert.equal(elapsedMs < 5000, true)
})
