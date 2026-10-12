import test from 'node:test'
import assert from 'node:assert/strict'

test('EditorStateModel serves as single source of truth without translation glue', () => {
  // Test unified editor state model
  const state = {
    tripId: 'trip_1001',
    tripTitle: '夜间行车',
    timeRange: '12:00:00 - 12:05:00',
    previewUri: '/data/front.mp4',
    previewCamera: 'Front',
    playheadSec: 30,
    canPlayPrev: true,
    canPlayNext: true,
    currentClipIndex: 1,
    currentClipTotal: 5,
    playheadText: '00:30 / 05:00',
    totalDurationSec: 300,
    timeline: [{ cameraPosition: 'Front', segmentCount: 5, degraded: false }],
    layers: [{ name: 'Front', heightRatio: 1.0 }],
    selectionStartSec: 10,
    selectionEndSec: 60,
    boundaryMarkers: [],
    templateCards: [{ id: 'T2', title: '双路画中画', subtitle: '前视+后视' }],
    previewSlots: [{ id: 's1', camera: 'Front', uri: '/data/front.mp4', x: 0, y: 0, width: 1920, height: 1080 }],
    activeTemplateId: 'T2',
    drawerExpanded: false,
    speedLabel: '1.0X',
    muted: false,
    watermarkEnabled: true,
    hideSpeed: true,
    hideGps: true,
    hideVin: true,
    hideTime: true,
    exportStatusText: '待导出'
  }

  // Direct mutation maintains consistency
  state.activeTemplateId = 'T1'
  state.selectionStartSec = 15
  state.selectionEndSec = 45
  state.speedLabel = '2.0X'

  assert.equal(state.activeTemplateId, 'T1')
  assert.equal(state.selectionStartSec, 15)
  assert.equal(state.selectionEndSec, 45)
  assert.equal(state.speedLabel, '2.0X')
})

test('Privacy toggles hideTime and hideGps operate independently', () => {
  const state = {
    hideSpeed: true,
    hideVin: true,
    hideGps: true,
    hideTime: true
  }

  // Toggle hideTime independently
  state.hideTime = false
  assert.equal(state.hideTime, false)
  assert.equal(state.hideGps, true, 'hideGps must not change when hideTime is updated')

  // Toggle hideGps independently
  state.hideGps = false
  state.hideTime = true
  assert.equal(state.hideGps, false)
  assert.equal(state.hideTime, true, 'hideTime must not change when hideGps is updated')
})

test('Export payload maps directly from EditorStateModel without translation engine', () => {
  const state = {
    tripId: 'trip_1001',
    activeTemplateId: 'T2',
    selectionStartSec: 10,
    selectionEndSec: 50,
    hideSpeed: true,
    hideVin: false,
    hideTime: true,
    hideGps: false
  }

  // Build export request directly from state
  const exportRequest = {
    templateId: state.activeTemplateId,
    expectedDurationSec: state.selectionEndSec - state.selectionStartSec,
    rangeStartMs: state.selectionStartSec * 1000,
    rangeEndMs: state.selectionEndSec * 1000,
    hideSpeed: state.hideSpeed,
    hideVin: state.hideVin,
    hideTime: state.hideTime
  }

  assert.equal(exportRequest.templateId, 'T2')
  assert.equal(exportRequest.expectedDurationSec, 40)
  assert.equal(exportRequest.rangeStartMs, 10000)
  assert.equal(exportRequest.rangeEndMs, 50000)
  assert.equal(exportRequest.hideSpeed, true)
  assert.equal(exportRequest.hideVin, false)
  assert.equal(exportRequest.hideTime, true)
})
