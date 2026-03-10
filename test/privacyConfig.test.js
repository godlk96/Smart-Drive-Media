import test from 'node:test'
import assert from 'node:assert/strict'
import { createDefaultPrivacyConfig, buildPrivacyPlan } from '../src/logic/privacyConfig.js'

test('createDefaultPrivacyConfig enables privacy by default', () => {
  const config = createDefaultPrivacyConfig()
  assert.equal(config.hideSpeed, true)
  assert.equal(config.hideVin, true)
  assert.equal(config.hideGps, true)
  assert.equal(config.cinematicCrop, false)
})

test('buildPrivacyPlan uses relative crop expression', () => {
  const plan = buildPrivacyPlan({ hideSpeed: true, hideVin: false, hideGps: true, mode: 'overlay' }, 0.83)
  assert.equal(plan.overlayMasks.length, 2)
  assert.equal(plan.cropExpression, 'crop=in_w:in_h*0.83:0:0')
  assert.equal(plan.cropExpression.includes('3840'), false)
})

test('buildPrivacyPlan switches to 21:9 cinematic crop when enabled', () => {
  const plan = buildPrivacyPlan({
    hideSpeed: true,
    hideVin: true,
    hideGps: true,
    cinematicCrop: true
  })
  assert.equal(plan.cinematicCrop, true)
  assert.equal(plan.cropExpression, 'crop=in_w:in_w*9/21:0:0')
  assert.equal(plan.outputAspectRatio, '21:9')
})
