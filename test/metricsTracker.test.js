import test from 'node:test'
import assert from 'node:assert/strict'
import { MetricsTracker } from '../src/logic/metricsTracker.js'

test('MetricsTracker records only supported business metrics', () => {
  const tracker = new MetricsTracker()
  tracker.track('scan_duration', 1234, { source: 'album' })
  tracker.track('unknown_metric', 1)

  const events = tracker.getEvents()
  assert.equal(events.length, 1)
  assert.equal(events[0].name, 'scan_duration')
})
