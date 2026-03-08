import test from 'node:test'
import assert from 'node:assert/strict'
import { PassiveImportController } from '../src/logic/passiveImportController.js'
import { ScanTarget } from '../src/model/scanTargets.js'

test('PassiveImportController starts passive scan with fixed targets', async () => {
  let receivedTargets = []
  const fileSource = {
    async listFiles(targets) {
      receivedTargets = targets
      return [{ filePath: 'C:/videos/DVR_LoopRecording_2026-03-01_09-00-00_Front.mp4' }]
    }
  }
  const scannerService = {
    async scan(entries) {
      return [{ id: 'trip-1', entries }]
    }
  }

  const controller = new PassiveImportController({ scannerService, fileSource })
  const result = await controller.start()

  assert.deepEqual(receivedTargets, [ScanTarget.SYSTEM_ALBUM, ScanTarget.HUAWEI_SHARE])
  assert.equal(result.length, 1)
})
