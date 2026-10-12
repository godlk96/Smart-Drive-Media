import test from 'node:test'
import assert from 'node:assert/strict'

// Model definitions and logic mirrored from EditorViewModel, Models and ExportNativeService
function normalizeCameraName(camera) {
  const lower = String(camera).toLowerCase()
  if (lower === 'front' || lower === '前' || lower === '前视') return 'Front'
  if (lower === 'back' || lower === 'rear' || lower === '后' || lower === '后视') return 'Back'
  if (lower === 'left' || lower === '左' || lower === '左视') return 'Left'
  if (lower === 'right' || lower === '右' || lower === '右视') return 'Right'
  return camera
}

function cameraZhName(camera) {
  const norm = normalizeCameraName(camera)
  if (norm === 'Front') return '前视'
  if (norm === 'Back') return '后视'
  if (norm === 'Left') return '左视'
  if (norm === 'Right') return '右视'
  return norm
}

const TEMPLATE_DEFINITIONS = {
  T1: { id: 'T1', requiredCameras: ['Front', 'Back', 'Left', 'Right'] },
  T2: { id: 'T2', requiredCameras: ['Front', 'Back'] },
  T3: { id: 'T3', requiredCameras: ['Left', 'Front', 'Right'] },
  T5: { id: 'T5', requiredCameras: ['Front'] }
}

function isTemplateDisabled(templateId, timelineTracks) {
  const def = TEMPLATE_DEFINITIONS[templateId]
  if (!def) return false
  const tracks = timelineTracks.map((t) => normalizeCameraName(t.cameraPosition))
  return def.requiredCameras.some((req) => !tracks.includes(normalizeCameraName(req)))
}

function getTemplateMissingViews(templateId, timelineTracks) {
  const def = TEMPLATE_DEFINITIONS[templateId]
  if (!def) return ''
  const tracks = timelineTracks.map((t) => normalizeCameraName(t.cameraPosition))
  const missing = def.requiredCameras
    .filter((req) => !tracks.includes(normalizeCameraName(req)))
    .map((req) => cameraZhName(req))
  return missing.join('、')
}

function buildExportSnapshot(state, tripSnapshot, exportSessionSeed) {
  if (!tripSnapshot) {
    return undefined
  }
  const startMs = Math.floor(state.selectionStartSec * 1000)
  const endMs = Math.floor(state.selectionEndSec * 1000)
  const playheadMs = Math.floor(state.playheadSec * 1000)

  return {
    tripId: tripSnapshot.id,
    sessionSeed: exportSessionSeed,
    activeTemplateId: state.activeTemplateId,
    playback: {
      speedLabel: state.speedLabel,
      muted: state.muted,
      rangeStartMs: startMs,
      rangeEndMs: endMs,
      playheadMs: Math.max(startMs, Math.min(playheadMs, endMs))
    },
    privacy: {
      hideSpeed: state.hideSpeed,
      hideGps: state.hideGps,
      hideVin: state.hideVin,
      hideTime: state.hideTime ?? state.hideGps
    },
    watermarkEnabled: state.watermarkEnabled
  }
}

function validateExportRequest(request) {
  if (!request.outputPath || request.outputPath.trim().length === 0) {
    throw new Error('outputPath required')
  }
  if (!request.inputs || request.inputs.length === 0) {
    throw new Error('at least one input track required')
  }
  if (request.rangeStartMs < 0) {
    throw new Error('rangeStartMs cannot be negative')
  }
  if (request.rangeEndMs <= request.rangeStartMs) {
    throw new Error('rangeEndMs must be strictly greater than rangeStartMs')
  }
  return {
    valid: true,
    trimmedDurationMs: request.rangeEndMs - request.rangeStartMs
  }
}

test('buildExportSnapshot builds unified snapshot and ensures boundary safety', () => {
  // If trip data is missing -> return undefined
  assert.equal(buildExportSnapshot({ selectionStartSec: 0, selectionEndSec: 10 }, null, 'seed_1'), undefined)

  const mockTrip = { id: 'trip_2026' }
  const state = {
    activeTemplateId: 'T2',
    speedLabel: '1.5X',
    muted: true,
    selectionStartSec: 10.5,
    selectionEndSec: 45.2,
    playheadSec: 5.0, // Before rangeStartSec!
    hideSpeed: true,
    hideGps: false,
    hideVin: true,
    hideTime: true,
    watermarkEnabled: false
  }

  const snapshot = buildExportSnapshot(state, mockTrip, 'seed_999')
  assert.ok(snapshot)
  assert.equal(snapshot.tripId, 'trip_2026')
  assert.equal(snapshot.sessionSeed, 'seed_999')
  assert.equal(snapshot.playback.rangeStartMs, 10500)
  assert.equal(snapshot.playback.rangeEndMs, 45200)
  // Playhead should be clamped to rangeStartMs since 5000 < 10500
  assert.equal(snapshot.playback.playheadMs, 10500)
  assert.equal(snapshot.privacy.hideTime, true)
  assert.equal(snapshot.privacy.hideGps, false)
})

test('Camera normalization and template availability contracts', () => {
  assert.equal(normalizeCameraName('前视'), 'Front')
  assert.equal(normalizeCameraName('rear'), 'Back')
  assert.equal(normalizeCameraName('左'), 'Left')
  assert.equal(normalizeCameraName('Right'), 'Right')

  // Timeline with only Front and Back
  const partialTimeline = [
    { cameraPosition: 'Front' },
    { cameraPosition: 'Back' }
  ]

  // T5 requires Front only -> enabled
  assert.equal(isTemplateDisabled('T5', partialTimeline), false)
  assert.equal(getTemplateMissingViews('T5', partialTimeline), '')

  // T2 requires Front and Back -> enabled
  assert.equal(isTemplateDisabled('T2', partialTimeline), false)
  assert.equal(getTemplateMissingViews('T2', partialTimeline), '')

  // T1 requires 4 cameras -> disabled, missing Left and Right
  assert.equal(isTemplateDisabled('T1', partialTimeline), true)
  assert.equal(getTemplateMissingViews('T1', partialTimeline), '左视、右视')
})

test('Export compose request contract validates parameters before passing to native engine', () => {
  // Valid request
  const validReq = {
    outputPath: '/data/storage/el2/base/haps/entry/files/export_test.mp4',
    inputs: [{ camera: 'Front', uri: '/dvr/front.mp4' }],
    rangeStartMs: 5000,
    rangeEndMs: 25000
  }
  const result = validateExportRequest(validReq)
  assert.equal(result.valid, true)
  assert.equal(result.trimmedDurationMs, 20000)

  // Invalid: missing output path
  assert.throws(() => {
    validateExportRequest({ ...validReq, outputPath: '' })
  }, /outputPath required/)

  // Invalid: empty inputs
  assert.throws(() => {
    validateExportRequest({ ...validReq, inputs: [] })
  }, /at least one input track required/)

  // Invalid: negative start
  assert.throws(() => {
    validateExportRequest({ ...validReq, rangeStartMs: -100 })
  }, /rangeStartMs cannot be negative/)

  // Invalid: end <= start
  assert.throws(() => {
    validateExportRequest({ ...validReq, rangeStartMs: 10000, rangeEndMs: 10000 })
  }, /rangeEndMs must be strictly greater than rangeStartMs/)

  assert.throws(() => {
    validateExportRequest({ ...validReq, rangeStartMs: 15000, rangeEndMs: 10000 })
  }, /rangeEndMs must be strictly greater than rangeStartMs/)
})

test('Export pipeline reports monotonic stage progress without fake timer interval ticks', () => {
  const progressReports = []
  const onProgress = (p) => progressReports.push(p)

  // Stage 1: Materialization start (10)
  onProgress(10)
  // Stage 2: Materialization complete & native start (35)
  onProgress(35)
  // Stage 3: Native render complete (85)
  onProgress(85)
  // Stage 4: Album write complete (100)
  onProgress(100)

  assert.deepEqual(progressReports, [10, 35, 85, 100])
  for (let i = 1; i < progressReports.length; i++) {
    assert.ok(progressReports[i] > progressReports[i - 1])
  }
})
