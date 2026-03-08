import test from 'node:test'
import assert from 'node:assert/strict'
import { CrashReporter } from '../src/logic/crashReporter.js'

test('CrashReporter masks sensitive fields', () => {
  const reporter = new CrashReporter()
  const record = reporter.capture(new Error('decode_failed'), {
    vin: 'LJ123456789',
    gps: '22.3,113.9',
    camera: 'Front'
  })

  assert.equal(record.context.vin, '***')
  assert.equal(record.context.gps, '***')
  assert.equal(record.context.camera, 'Front')
})
