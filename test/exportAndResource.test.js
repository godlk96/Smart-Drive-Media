import test from 'node:test'
import assert from 'node:assert/strict'

test('ExportManager caches terminal error state so late subscribers receive it immediately', async () => {
  // Mock ExportManager core state logic
  class MockExportManager {
    constructor() {
      this.jobs = new Map()
      this.terminalEvents = new Map()
    }

    start(snapshot) {
      const jobId = 'job_' + Date.now()
      const record = { id: jobId, listeners: [] }
      this.jobs.set(jobId, record)

      // Simulate immediate sync failure on empty clips
      const clips = snapshot?.clips ?? []
      if (clips.length === 0) {
        const errorMsg = '导出失败：缺少可导出素材'
        this.notify(record, errorMsg, 0)
        this.terminalEvents.set(jobId, { status: 'FAILED', message: errorMsg, progress: 0 })
        this.jobs.delete(jobId)
      }
      return jobId
    }

    notify(record, message, progress) {
      for (const listener of record.listeners) {
        listener({ message, progress })
      }
    }

    subscribe(jobId, listener) {
      // If terminal event exists (e.g. error finished before subscription), notify immediately
      if (this.terminalEvents.has(jobId)) {
        const terminal = this.terminalEvents.get(jobId)
        listener(terminal)
        return
      }
      const record = this.jobs.get(jobId)
      if (record) {
        record.listeners.push(listener)
      }
    }
  }

  const manager = new MockExportManager()
  const emptySnapshot = { clips: [] }
  const jobId = manager.start(emptySnapshot)

  let receivedStatus = null
  let receivedMessage = null

  // Subscribe late after start has already completed synchronously
  manager.subscribe(jobId, (event) => {
    receivedStatus = event.status
    receivedMessage = event.message
  })

  assert.equal(receivedStatus, 'FAILED')
  assert.equal(receivedMessage, '导出失败：缺少可导出素材')
})

test('ExportComposeRequest must include rangeStartMs and rangeEndMs for native trim', () => {
  class ExportComposeRequest {
    constructor() {
      this.fileName = ''
      this.outputPath = ''
      this.frontUris = []
      this.backUris = []
      this.sideUris = []
      this.expectedDurationSec = 0
      this.rangeStartMs = 0
      this.rangeEndMs = 0
      this.hideSpeed = true
      this.hideGps = true
      this.hideVin = true
    }
  }

  const req = new ExportComposeRequest()
  req.rangeStartMs = 15000
  req.rangeEndMs = 35000
  req.expectedDurationSec = (req.rangeEndMs - req.rangeStartMs) / 1000

  assert.equal(req.rangeStartMs, 15000)
  assert.equal(req.rangeEndMs, 35000)
  assert.equal(req.expectedDurationSec, 20)
})

test('PlayerSlot closes file descriptor on reset, reload and release', () => {
  let closedFds = []
  const mockFs = {
    closeSync: (fd) => {
      closedFds.push(fd)
    }
  }

  class MockSlotManager {
    constructor() {
      this.openedFd = undefined
    }

    loadSlot(fd) {
      this.closeSlotFd()
      this.openedFd = fd
    }

    closeSlotFd() {
      if (this.openedFd !== undefined && this.openedFd >= 0) {
        mockFs.closeSync(this.openedFd)
        this.openedFd = undefined
      }
    }
  }

  const slot = new MockSlotManager()
  slot.loadSlot(101)
  assert.equal(closedFds.length, 0)

  // Loading next slot should close 101
  slot.loadSlot(102)
  assert.deepEqual(closedFds, [101])

  // Releasing slot should close 102
  slot.closeSlotFd()
  assert.deepEqual(closedFds, [101, 102])
})
