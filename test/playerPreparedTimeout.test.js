import test from 'node:test'
import assert from 'node:assert/strict'

class MockPlayerSlot {
  constructor(name = 'A') {
    this.name = name
    this.prepared = false
    this.preparedResolve = undefined
    this.preparedTimeoutId = -1
  }

  waitPrepared(timeoutMs = 50) {
    if (this.prepared) {
      return Promise.resolve()
    }
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        if (this.preparedResolve === safeResolve) {
          this.preparedResolve = undefined
          this.preparedTimeoutId = -1
          resolve({ timedOut: true })
        }
      }, timeoutMs)
      this.preparedTimeoutId = timer

      const safeResolve = () => {
        if (this.preparedTimeoutId !== -1) {
          clearTimeout(this.preparedTimeoutId)
          this.preparedTimeoutId = -1
        }
        resolve({ timedOut: false })
      }
      this.preparedResolve = safeResolve
    })
  }

  notifyPrepared() {
    this.prepared = true
    if (this.preparedResolve) {
      this.preparedResolve()
      this.preparedResolve = undefined
    }
  }

  release() {
    if (this.preparedTimeoutId !== -1) {
      clearTimeout(this.preparedTimeoutId)
      this.preparedTimeoutId = -1
    }
    if (this.preparedResolve) {
      this.preparedResolve()
      this.preparedResolve = undefined
    }
  }
}

test('waitPrepared resolves immediately when slot is already prepared', async () => {
  const slot = new MockPlayerSlot('A')
  slot.prepared = true
  const res = await slot.waitPrepared(100)
  assert.equal(res, undefined)
})

test('waitPrepared resolves cleanly when slot becomes prepared within timeout', async () => {
  const slot = new MockPlayerSlot('A')
  const waitPromise = slot.waitPrepared(200)

  setTimeout(() => {
    slot.notifyPrepared()
  }, 20)

  const res = await waitPromise
  assert.equal(res.timedOut, false)
})

test('waitPrepared auto-resolves when prepared event hangs past timeout', async () => {
  const slot = new MockPlayerSlot('B')
  const start = Date.now()
  const res = await slot.waitPrepared(50)
  const elapsed = Date.now() - start

  assert.equal(res.timedOut, true)
  assert.ok(elapsed >= 45)
})

test('releaseSlot clears timeout and resolves pending promises without hang', async () => {
  const slot = new MockPlayerSlot('A')
  const waitPromise = slot.waitPrepared(500)

  slot.release()
  const res = await waitPromise
  assert.equal(res.timedOut, false)
  assert.equal(slot.preparedTimeoutId, -1)
})
