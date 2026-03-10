import test from 'node:test'
import assert from 'node:assert/strict'
import { Orientation, getEditorLayout } from '../src/logic/editorLayout.js'

test('getEditorLayout returns portrait ratios by default', () => {
  const layout = getEditorLayout(Orientation.PORTRAIT)
  assert.equal(layout.preview.region, 'top')
  assert.equal(layout.timeline.region, 'bottom')
  assert.equal(layout.preview.ratio, 0.35)
  assert.deepEqual(
    layout.layers.map(layer => layer.id),
    ['preview', 'control', 'timeline', 'drawer']
  )
})

test('getEditorLayout returns landscape ratios', () => {
  const layout = getEditorLayout(Orientation.LANDSCAPE)
  assert.equal(layout.preview.region, 'left')
  assert.equal(layout.timeline.region, 'right')
  assert.equal(layout.preview.ratio, 0.6)
  assert.equal(layout.layers.length, 4)
})
