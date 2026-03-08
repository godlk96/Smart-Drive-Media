import test from 'node:test'
import assert from 'node:assert/strict'
import { ExportJobState } from '../src/logic/exportJobState.js'
import { ExportStatusViewModel } from '../src/viewmodel/exportStatusViewModel.js'

test('ExportStatusViewModel exposes visible status and trace records', () => {
  const vm = new ExportStatusViewModel({
    exportJobState: new ExportJobState()
  })

  vm.start('C:/videos/out.mp4')
  vm.progress(30)
  vm.fail('encode_error')
  const state = vm.getState()

  assert.equal(state.statusText, 'failed')
  assert.equal(state.progressText, '30%')
  assert.equal(state.errorText, 'encode_error')
  assert.equal(state.trace.length >= 3, true)
})
