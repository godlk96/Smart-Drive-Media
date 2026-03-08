import test from 'node:test'
import assert from 'node:assert/strict'
import { ScreenRouter } from '../src/ui/screenRouter.js'

test('ScreenRouter navigates forward and backward', () => {
  const router = new ScreenRouter()
  assert.equal(router.getState().current.name, 'trip_library')
  assert.equal(router.getState().depth, 1)

  router.navigate('editor', { tripId: 't1' })
  assert.equal(router.getState().current.name, 'editor')
  assert.equal(router.getState().current.params.tripId, 't1')
  assert.equal(router.getState().depth, 2)

  router.back()
  assert.equal(router.getState().current.name, 'trip_library')
  assert.equal(router.getState().depth, 1)
})
