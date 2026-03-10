import test from 'node:test'
import assert from 'node:assert/strict'
import {
  buildScenarioPreview,
  buildTemplateFilterComplex,
  getScenarioTemplate,
  getScenarioTemplateCards
} from '../src/logic/scenarioTemplateEngine.js'

test('scenarioTemplateEngine exposes T1-T4 cards and defaults to T2', () => {
  const cards = getScenarioTemplateCards()
  assert.equal(cards.length, 4)
  assert.deepEqual(cards.map(item => item.id), ['T1', 'T2', 'T3', 'T4'])
  assert.equal(getScenarioTemplate('UNKNOWN').id, 'T2')
})

test('scenarioTemplateEngine resolves preview slots with track fallback', () => {
  const preview = buildScenarioPreview('T4', ['Front'])
  assert.equal(preview.aspectRatio, '9:16')
  assert.equal(preview.slots.length, 3)
  assert.equal(preview.slots.every(slot => slot.track === 'Front'), true)
})

test('scenarioTemplateEngine builds filter graph aligned with template guides', () => {
  const graph = buildTemplateFilterComplex({
    templateId: 'T3',
    streamLabelByTrack: {
      Left: '[left_v]',
      Right: '[right_v]'
    },
    privacyFilter: 'crop=in_w:in_h:0:0'
  })
  assert.equal(graph.includes('color=c=black:s=1920x1080'), true)
  assert.equal(graph.includes('[left_v]setpts=PTS-STARTPTS'), true)
  assert.equal(graph.includes('[right_v]setpts=PTS-STARTPTS'), true)
  assert.equal(graph.includes('drawbox=x='), true)
  assert.equal(graph.includes('[layout_v]crop=in_w:in_h:0:0[v]'), true)
})
