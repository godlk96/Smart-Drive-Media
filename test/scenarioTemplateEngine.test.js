import test from 'node:test'
import assert from 'node:assert/strict'
import {
  buildScenarioPreview,
  buildTemplateFilterComplex,
  getScenarioTemplate,
  getScenarioTemplateCards
} from '../src/logic/scenarioTemplateEngine.js'

test('scenarioTemplateEngine exposes T1-T5 cards and defaults to T2', () => {
  const cards = getScenarioTemplateCards()
  assert.equal(cards.length, 5)
  assert.deepEqual(cards.map(item => item.id), ['T1', 'T2', 'T3', 'T4', 'T5'])
  assert.equal(getScenarioTemplate('T5').id, 'T5')
  assert.equal(getScenarioTemplate('UNKNOWN').id, 'T2')
})

test('scenarioTemplateEngine resolves T1/T2/T4 preview slots with corrected track fallback', () => {
  const t1Preview = buildScenarioPreview('T1', ['Front', 'Back'])
  assert.equal(t1Preview.slots[0].track, 'Front')
  assert.equal(t1Preview.slots[1].track, 'Back')
  assert.equal(t1Preview.slots[0].id, 'top')
  assert.equal(t1Preview.slots[1].id, 'bottom')

  const t2Preview = buildScenarioPreview('T2', ['Front', 'Left', 'Right'])
  assert.equal(t2Preview.aspectRatio, '32:27')
  assert.deepEqual(t2Preview.outputSize, { width: 1920, height: 1620 })
  assert.equal(t2Preview.slots[0].track, 'Front')
  assert.equal(t2Preview.slots[1].track, 'Left')
  assert.equal(t2Preview.slots[2].track, 'Right')
  assert.equal(t2Preview.slots[0].rect.height, 0.6667)
  assert.equal(t2Preview.slots[1].rect.y, 0.6667)
  assert.equal(t2Preview.slots[2].rect.height, 0.3333)

  const preview = buildScenarioPreview('T4', ['Front', 'RightFront'])
  assert.equal(preview.aspectRatio, '16:9')
  assert.equal(preview.slots.length, 3)
  assert.equal(preview.slots[2].id, 'right')
  assert.equal(preview.slots[2].track, 'RightFront')
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

test('scenarioTemplateEngine supports T5 preview and export filter graph', () => {
  const preview = buildScenarioPreview('T5', ['Left', 'Front', 'Right'])
  assert.equal(preview.templateId, 'T5')
  assert.equal(preview.aspectRatio, '16:9')
  assert.equal(preview.slots.length, 1)
  assert.equal(preview.slots[0].track, 'Front')
  assert.equal(preview.slots[0].id, 'top')
  assert.equal(preview.guides.length, 0)

  const graph = buildTemplateFilterComplex({
    templateId: 'T5',
    streamLabelByTrack: {
      Left: '[left_v]',
      Front: '[front_v]',
      Right: '[right_v]'
    },
    privacyFilter: 'crop=in_w:in_h:0:0'
  })
  assert.equal(graph.includes('color=c=black:s=1920x1080'), true)
  assert.equal(graph.includes('[front_v]setpts=PTS-STARTPTS'), true)
  assert.equal(graph.includes('[left_v]setpts=PTS-STARTPTS'), false)
  assert.equal(graph.includes('[right_v]setpts=PTS-STARTPTS'), false)
  assert.equal(graph.includes('drawbox=x='), false)
  assert.equal(graph.includes('[layout_v]crop=in_w:in_h:0:0[v]'), true)
})

test('scenarioTemplateEngine prevents non-back slots from degrading to Back', () => {
  const t5Preview = buildScenarioPreview('T5', ['Back'])
  assert.equal(t5Preview.slots[0].track, 'Front')

  const t5Graph = buildTemplateFilterComplex({
    templateId: 'T5',
    streamLabelByTrack: {
      Back: '[back_v]'
    }
  })
  assert.equal(t5Graph.includes('[back_v]setpts=PTS-STARTPTS'), false)
  assert.equal(t5Graph.includes('[0:v]setpts=PTS-STARTPTS'), true)

  const t2Graph = buildTemplateFilterComplex({
    templateId: 'T2',
    streamLabelByTrack: {
      Back: '[back_v]',
      Right: '[right_v]'
    }
  })
  assert.equal(t2Graph.includes('[back_v]setpts=PTS-STARTPTS'), false)
})
