import test from 'node:test'
import assert from 'node:assert/strict'

// Timeline calculation algorithms mirrored from EditorViewModel & CoreBridge
function getTimelineTicks(totalDurationSec) {
  const result = []
  const interval = totalDurationSec <= 60 ? 10 : 30
  for (let point = 0; point <= totalDurationSec; point += interval) {
    result.push(point)
  }
  if (result.length === 0 || result[result.length - 1] !== totalDurationSec) {
    result.push(totalDurationSec)
  }
  return result
}

function formatTimelineTick(seconds) {
  const min = Math.floor(seconds / 60)
  const sec = Math.floor(seconds % 60)
  return `${min}:${sec.toString().padStart(2, '0')}`
}

function getPlaybackRate(speedLabel) {
  const normalized = speedLabel.replace('X', '')
  const parsed = Number(normalized)
  if (parsed >= 1.0 && parsed <= 4.0) {
    return parsed
  }
  return 1.0
}

function getPreviewAspectRatio(templateId) {
  if (templateId === 'T1') {
    return 1920 / 2160
  }
  if (templateId === 'T2') {
    return 1920 / 1620
  }
  if (templateId === 'T3' || templateId === 'T4') {
    return 3840 / 1080
  }
  return 16 / 9
}

function updateSelectionRange(startSec, endSec, totalDurationSec, currentPlayheadMs) {
  const max = Math.max(0, totalDurationSec)
  const nextStart = Math.max(0, Math.min(Math.floor(startSec), max))
  const nextEnd = Math.max(nextStart, Math.min(Math.floor(endSec), max))
  const nextPlayheadMs = Math.max(nextStart * 1000, Math.min(currentPlayheadMs, nextEnd * 1000))
  return {
    selectionStartSec: nextStart,
    selectionEndSec: nextEnd,
    playheadMs: nextPlayheadMs
  }
}

function stabilizeMinuteBoundary(rawSec, lastStableSec, totalDurationSec, hysteresisSec = 0.35) {
  const clamped = Math.max(0, Math.min(rawSec, totalDurationSec))
  if (lastStableSec <= 0) {
    return clamped
  }
  const lastMinute = Math.floor(lastStableSec / 60)
  const currentMinute = Math.floor(clamped / 60)
  if (lastMinute === currentMinute) {
    return clamped
  }
  const boundary = Math.max(lastMinute, currentMinute) * 60
  if (Math.abs(clamped - boundary) < hysteresisSec) {
    return lastStableSec
  }
  return clamped
}

test('Timeline tick generator creates appropriate intervals and ends at total duration', () => {
  // Short video (<= 60s) -> 10s intervals
  const ticks60 = getTimelineTicks(60)
  assert.deepEqual(ticks60, [0, 10, 20, 30, 40, 50, 60])

  // Non-multiple short video -> 10s intervals ending on exact duration
  const ticks45 = getTimelineTicks(45)
  assert.deepEqual(ticks45, [0, 10, 20, 30, 40, 45])

  // Long video (> 60s) -> 30s intervals
  const ticks180 = getTimelineTicks(180)
  assert.deepEqual(ticks180, [0, 30, 60, 90, 120, 150, 180])

  // Non-multiple long video -> 30s intervals ending on exact duration
  const ticks75 = getTimelineTicks(75)
  assert.deepEqual(ticks75, [0, 30, 60, 75])
})

test('formatTimelineTick properly formats seconds into mm:ss clock text', () => {
  assert.equal(formatTimelineTick(0), '0:00')
  assert.equal(formatTimelineTick(5), '0:05')
  assert.equal(formatTimelineTick(59), '0:59')
  assert.equal(formatTimelineTick(60), '1:00')
  assert.equal(formatTimelineTick(125), '2:05')
  assert.equal(formatTimelineTick(3605), '60:05')
})

test('Playback rate parser safely parses valid multipliers and falls back on invalid values', () => {
  assert.equal(getPlaybackRate('1.0X'), 1.0)
  assert.equal(getPlaybackRate('1.5X'), 1.5)
  assert.equal(getPlaybackRate('2.0X'), 2.0)
  assert.equal(getPlaybackRate('4.0X'), 4.0)

  // Out of range or corrupted labels fall back to 1.0
  assert.equal(getPlaybackRate('0.5X'), 1.0)
  assert.equal(getPlaybackRate('8.0X'), 1.0)
  assert.equal(getPlaybackRate('INVALID'), 1.0)
})

test('Preview aspect ratios correctly map to template specifications', () => {
  assert.equal(getPreviewAspectRatio('T1'), 1920 / 2160)
  assert.equal(getPreviewAspectRatio('T2'), 1920 / 1620)
  assert.equal(getPreviewAspectRatio('T3'), 3840 / 1080)
  assert.equal(getPreviewAspectRatio('T4'), 3840 / 1080)
  assert.equal(getPreviewAspectRatio('T5'), 16 / 9)
  assert.equal(getPreviewAspectRatio('UNKNOWN'), 16 / 9)
})

test('Selection range algorithm clamps boundaries and auto-adjusts playhead', () => {
  const totalDuration = 120

  // Standard range inside video duration
  const res1 = updateSelectionRange(10, 50, totalDuration, 30000)
  assert.equal(res1.selectionStartSec, 10)
  assert.equal(res1.selectionEndSec, 50)
  assert.equal(res1.playheadMs, 30000)

  // Start before 0 and end beyond duration -> clamped
  const res2 = updateSelectionRange(-15, 200, totalDuration, 30000)
  assert.equal(res2.selectionStartSec, 0)
  assert.equal(res2.selectionEndSec, 120)
  assert.equal(res2.playheadMs, 30000)

  // Inverted range (start > end) -> clamped to start
  const res3 = updateSelectionRange(80, 20, totalDuration, 90000)
  assert.equal(res3.selectionStartSec, 80)
  assert.equal(res3.selectionEndSec, 80)
  assert.equal(res3.playheadMs, 80000)

  // Playhead outside selection window gets pulled into window
  const res4 = updateSelectionRange(20, 60, totalDuration, 10000)
  assert.equal(res4.playheadMs, 20000) // pulled forward to start

  const res5 = updateSelectionRange(20, 60, totalDuration, 80000)
  assert.equal(res5.playheadMs, 60000) // pulled back to end
})

test('Minute boundary hysteresis prevents jitter near segment transition points', () => {
  const totalDuration = 300
  const lastStable = 59.9

  // Minor overshoot across 60s boundary within hysteresis (0.35s) -> keeps lastStable
  const stabilized = stabilizeMinuteBoundary(60.1, lastStable, totalDuration, 0.35)
  assert.equal(stabilized, lastStable)

  // Significant scrub exceeding hysteresis window -> transitions cleanly to target
  const scrubbed = stabilizeMinuteBoundary(61.5, lastStable, totalDuration, 0.35)
  assert.equal(scrubbed, 61.5)
})
