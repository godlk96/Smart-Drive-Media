import test from 'node:test'
import assert from 'node:assert/strict'
import { StorageGuard } from '../src/logic/storageGuard.js'

test('StorageGuard rejects when available space is insufficient', () => {
  const guard = new StorageGuard({ reserveBytes: 100 })
  const result = guard.validate({ requiredBytes: 500, availableBytes: 550 })
  assert.equal(result.ok, false)
  assert.equal(result.reason, 'insufficient_storage')
})

test('StorageGuard passes when available space is enough', () => {
  const guard = new StorageGuard({ reserveBytes: 100 })
  const result = guard.validate({ requiredBytes: 500, availableBytes: 700 })
  assert.equal(result.ok, true)
})
