import test from 'node:test'
import assert from 'node:assert/strict'
import { ExportEngine, ExportMode, selectExportMode } from '../src/logic/exportEngine.js'

test('selectExportMode chooses stream copy for single track clean export', () => {
  const mode = selectExportMode({
    trackCount: 1,
    hasPrivacyMask: false,
    hasVisualEffects: false
  })
  assert.equal(mode, ExportMode.STREAM_COPY)
})

test('selectExportMode chooses transcode when privacy enabled', () => {
  const mode = selectExportMode({
    trackCount: 1,
    hasPrivacyMask: true,
    hasVisualEffects: false
  })
  assert.equal(mode, ExportMode.TRANSCODE)
})

test('ExportEngine creates stream copy plan and transcode plan', () => {
  const engine = new ExportEngine()

  const streamPlan = engine.createPlan({
    inputFiles: ['a.mp4', 'b.mp4'],
    outputPath: 'out.mp4',
    trackCount: 1,
    privacyConfig: { hideSpeed: false, hideVin: false, hideGps: false }
  })
  assert.equal(streamPlan.type, ExportMode.STREAM_COPY)

  const transcodePlan = engine.createPlan({
    inputFiles: ['a.mp4'],
    outputPath: 'out2.mp4',
    trackCount: 2,
    privacyConfig: { hideSpeed: true, hideVin: false, hideGps: false }
  })
  assert.equal(transcodePlan.type, ExportMode.TRANSCODE)
})
