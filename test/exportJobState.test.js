import test from 'node:test'
import assert from 'node:assert/strict'
import { ExportJobState } from '../src/logic/exportJobState.js'

test('ExportJobState tracks progress and final states', () => {
  const state = new ExportJobState()

  state.start('out.mp4')
  state.updateProgress(42)
  assert.equal(state.snapshot().status, 'running')
  assert.equal(state.snapshot().progress, 42)

  state.succeed()
  assert.equal(state.snapshot().status, 'success')
  assert.equal(state.snapshot().progress, 100)

  state.start('out2.mp4')
  state.fail('disk_full')
  assert.equal(state.snapshot().status, 'failed')
  assert.equal(state.snapshot().errorMessage, 'disk_full')
})
