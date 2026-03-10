import test from 'node:test'
import assert from 'node:assert/strict'
import { HarmonyCoreBridge } from '../src/harmony/coreBridge.js'

test('HarmonyCoreBridge returns permission guidance when required permissions are missing', async () => {
  const bridge = new HarmonyCoreBridge()
  const result = await bridge.initializeLibrary({
    grantedPermissions: ['ohos.permission.READ_MEDIA']
  })

  assert.equal(result.ok, false)
  assert.equal(result.reason, 'permission_denied')
  assert.deepEqual(result.permissionGuide.missing, ['ohos.permission.READ_IMAGEVIDEO'])
  assert.equal(result.state.empty, true)
})

test('HarmonyCoreBridge initializes library and opens editor with scanned trip', async () => {
  const bridge = new HarmonyCoreBridge({
    fileSource: {
      async listFiles() {
        return [
          { filePath: 'C:/videos/DVR_LoopRecording_2026-03-07_20-00-00_Front.mp4', durationSec: 60 },
          { filePath: 'C:/videos/DVR_LoopRecording_2026-03-07_20-00-00_Back.mp4', durationSec: 60 }
        ]
      }
    }
  })

  const initResult = await bridge.initializeLibrary({
    grantedPermissions: ['ohos.permission.READ_MEDIA', 'ohos.permission.READ_IMAGEVIDEO']
  })
  assert.equal(initResult.ok, true)
  assert.equal(initResult.state.empty, false)
  assert.equal(initResult.state.cards.length, 1)

  const tripId = initResult.state.cards[0].id
  const openState = bridge.openTrip(tripId)
  assert.equal(openState.ok, true)
  assert.equal(openState.routeState.current.name, 'editor')

  const editorState = bridge.loadEditor(tripId)
  assert.equal(editorState.ok, true)
  assert.equal(editorState.state.timeline.length, 6)
})

test('HarmonyCoreBridge creates template-driven export plan', async () => {
  const bridge = new HarmonyCoreBridge({
    fileSource: {
      async listFiles() {
        return [{ filePath: 'C:/videos/DVR_LoopRecording_2026-03-07_20-00-00_Front.mp4', durationSec: 60 }]
      }
    }
  })

  const initResult = await bridge.initializeLibrary({
    grantedPermissions: ['ohos.permission.READ_MEDIA', 'ohos.permission.READ_IMAGEVIDEO']
  })
  const tripId = initResult.state.cards[0].id
  bridge.setPrivacyConfig({ hideSpeed: false, hideVin: false, hideGps: false })
  bridge.editorScreen.setControlDeck({ speed: '16.0X', muted: false, watermarkEnabled: true })

  const exportPlan = bridge.createExportPlan({
    tripId,
    outputPath: 'C:/videos/output.mp4'
  })
  assert.equal(exportPlan.ok, true)
  assert.equal(exportPlan.command.type, 'transcode')
  assert.equal(exportPlan.command.args.includes('-filter_complex'), true)
  assert.equal(exportPlan.command.args.includes('-an'), true)
  assert.equal(exportPlan.command.args.some(item => String(item).includes('setpts=PTS/16.00')), true)
  assert.equal(exportPlan.command.args.some(item => String(item).includes('Shot on AITO')), true)
})

test('HarmonyCoreBridge creates multi-track template export plan', async () => {
  const bridge = new HarmonyCoreBridge({
    fileSource: {
      async listFiles() {
        return [
          { filePath: 'C:/videos/DVR_LoopRecording_2026-03-07_20-00-00_Front.mp4', durationSec: 60 },
          { filePath: 'C:/videos/DVR_LoopRecording_2026-03-07_20-00-00_Back.mp4', durationSec: 60 },
          { filePath: 'C:/videos/DVR_LoopRecording_2026-03-07_20-01-00_Front.mp4', durationSec: 60 },
          { filePath: 'C:/videos/DVR_LoopRecording_2026-03-07_20-01-00_Back.mp4', durationSec: 60 }
        ]
      }
    }
  })

  const initResult = await bridge.initializeLibrary({
    grantedPermissions: ['ohos.permission.READ_MEDIA', 'ohos.permission.READ_IMAGEVIDEO']
  })
  const tripId = initResult.state.cards[0].id
  bridge.setPrivacyConfig({ hideSpeed: false, hideVin: false, hideGps: false })

  const exportPlan = bridge.createExportPlan({
    tripId,
    outputPath: 'C:/videos/output.mp4'
  })
  assert.equal(exportPlan.ok, true)
  assert.equal(exportPlan.command.type, 'transcode')
  assert.equal(exportPlan.command.args.includes('-filter_complex'), true)
  assert.equal(exportPlan.command.args.some(item => String(item).includes('overlay=')), true)
  assert.equal(exportPlan.totalDurationSec, 120)
})

test('HarmonyCoreBridge executes export command and updates status', async () => {
  const bridge = new HarmonyCoreBridge({
    fileSource: {
      async listFiles() {
        return [{ filePath: 'C:/videos/DVR_LoopRecording_2026-03-07_20-00-00_Front.mp4', durationSec: 60 }]
      }
    },
    exportExecutor: {
      async execute(command, { onProgress }) {
        assert.equal(typeof command.type, 'string')
        onProgress?.(35)
        onProgress?.(80)
      }
    }
  })

  const initResult = await bridge.initializeLibrary({
    grantedPermissions: ['ohos.permission.READ_MEDIA', 'ohos.permission.READ_IMAGEVIDEO']
  })
  const tripId = initResult.state.cards[0].id
  bridge.loadEditor(tripId)

  const exportResult = await bridge.executeExport({
    tripId,
    outputPath: 'C:/videos/output.mp4'
  })
  assert.equal(exportResult.ok, true)
  assert.equal(exportResult.state.exportStatus.statusText, 'success')
  assert.equal(exportResult.state.exportStatus.progressText, '100%')
})

test('HarmonyCoreBridge task6 links privacy cinematic controls into export plan', async () => {
  const bridge = new HarmonyCoreBridge({
    fileSource: {
      async listFiles() {
        return [{ filePath: 'C:/videos/DVR_LoopRecording_2026-03-07_20-00-00_Front.mp4', durationSec: 60 }]
      }
    }
  })
  const initResult = await bridge.initializeLibrary({
    grantedPermissions: ['ohos.permission.READ_MEDIA', 'ohos.permission.READ_IMAGEVIDEO']
  })
  const tripId = initResult.state.cards[0].id
  bridge.loadEditor(tripId)

  bridge.editorScreen.toggleHideSpeed()
  bridge.editorScreen.toggleHideVin()
  bridge.editorScreen.toggleHideGps()
  bridge.editorScreen.toggleCinematicCrop()
  bridge.editorScreen.setControlDeck({ speed: '8.0X', muted: false, watermarkEnabled: false })

  const exportPlan = bridge.createExportPlan({
    tripId,
    outputPath: 'C:/videos/task6.mp4'
  })

  assert.equal(exportPlan.ok, true)
  assert.equal(exportPlan.command.args.some(item => String(item).includes('crop=in_w:in_w*9/21:0:0')), true)
  assert.equal(exportPlan.command.args.some(item => String(item).includes('drawbox=x=in_w*')), false)
  assert.equal(exportPlan.command.args.some(item => String(item).includes('Shot on AITO')), false)
  assert.equal(exportPlan.command.args.includes('-an'), true)
})
