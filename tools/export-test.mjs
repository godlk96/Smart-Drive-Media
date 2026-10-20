import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, resolve } from 'node:path'
import vm from 'node:vm'

const require = createRequire(import.meta.url)
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js')
const root = resolve(import.meta.dirname, '..')
function loadEts(relative, mocks = {}, cache = new Map()) {
  const path = resolve(root, relative)
  if (cache.has(path)) return cache.get(path).exports
  const module = { exports: {} }
  cache.set(path, module)
  const compiled = ts.transpileModule(readFileSync(path, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS, esModuleInterop: true }
  }).outputText
  const localRequire = name => {
    if (Object.hasOwn(mocks, name)) return mocks[name]
    if (name.startsWith('.')) return loadEts(resolve(dirname(path), `${name}.ets`), mocks, cache)
    throw new Error(`Missing platform mock: ${name}`)
  }
  vm.runInNewContext(compiled, { module, exports: module.exports, require: localRequire,
    ArrayBuffer, Uint8Array, setInterval, clearInterval, setTimeout, clearTimeout, console,
    ...(mocks.__globals ?? {}) }, { filename: path })
  return module.exports
}

function memoryFs(contents = new Map(), options = {}) {
  const files = new Map([...contents].map(([path, bytes]) => [path, Buffer.from(bytes)]))
  const opened = new Map()
  const buffers = new Set()
  const removed = []
  let nextFd = 1
  let writeCount = 0
  return {
    files, opened, buffers, removed,
    OpenMode: { READ_ONLY: 0, READ_WRITE: 2, CREATE: 64, TRUNC: 512 },
    async stat(path) {
      if (options.unknownSize) throw new Error('unknown size')
      if (!files.has(path)) throw new Error('not found')
      return { size: files.get(path).length }
    },
    async open(path, mode) {
      if (mode & 64 || mode & 512) files.set(path, Buffer.alloc(0))
      if (!files.has(path)) throw new Error('not found')
      const fd = nextFd++
      opened.set(fd, { path, position: 0 })
      return { fd }
    },
    async read(fd, buffer) {
      buffers.add(buffer)
      const file = opened.get(fd)
      const content = files.get(file.path)
      const count = Math.min(buffer.byteLength, content.length - file.position, options.readLimit ?? Infinity)
      new Uint8Array(buffer).set(content.subarray(file.position, file.position + count))
      file.position += count
      return count
    },
    async write(fd, buffer, writeOptions = {}) {
      if (++writeCount === options.failWriteAt) throw new Error('disk full')
      const file = opened.get(fd)
      const count = Math.min(writeOptions.length ?? buffer.byteLength, options.writeLimit ?? Infinity)
      files.set(file.path, Buffer.concat([files.get(file.path), Buffer.from(buffer).subarray(0, count)]))
      file.position += count
      return count
    },
    async fsync() { if (options.failSync) throw new Error('flush failed') },
    async close(fd) {
      const path = opened.get(fd)?.path
      opened.delete(fd)
      if (path === options.failClosePath) throw new Error('close failed')
    },
    async unlink(path) { removed.push(path); files.delete(path) }
  }
}

const tests = []
const test = (name, run) => tests.push({ name, run })
async function copyFixture(options = {}) {
  const content = Buffer.from('0123456789'.repeat(7))
  const fs = memoryFs(new Map([['source', content], ['target', Buffer.alloc(0)]]), options)
  const source = await fs.open('source', 0)
  const target = await fs.open('target', 2)
  const { copyExportFileData } = loadEts('entry/src/main/ets/service/ExportFileCopy.ets', { '@ohos.file.fs': fs })
  return { content, fs, source, target, copyExportFileData }
}

test('copy reuses one buffer and honors short reads', async () => {
  const f = await copyFixture({ readLimit: 13 })
  const progress = []
  assert.equal(await f.copyExportFileData(f.source.fd, f.target.fd, f.content.length,
    (copied, total) => progress.push([copied, total]), () => false), f.content.length)
  assert.deepEqual(f.fs.files.get('target'), f.content)
  assert.equal(f.fs.buffers.size, 1)
  assert.ok(progress.length > 1)
  assert.deepEqual(progress.at(-1), [70, 70])
})
test('copy retries partial writes without losing bytes', async () => {
  const f = await copyFixture({ writeLimit: 7 })
  await f.copyExportFileData(f.source.fd, f.target.fd, 70, () => {}, () => false)
  assert.deepEqual(f.fs.files.get('target'), f.content)
})
test('copy cancellation prevents the next write', async () => {
  const f = await copyFixture({ readLimit: 10 })
  let cancelled = false
  await assert.rejects(f.copyExportFileData(f.source.fd, f.target.fd, 70,
    copied => { if (copied > 0) cancelled = true }, () => cancelled), /取消/)
  assert.equal(f.fs.files.get('target').length, 10)
})
test('copy detects truncated input and reports no fabricated completion', async () => {
  const f = await copyFixture()
  const progress = []
  await assert.rejects(f.copyExportFileData(f.source.fd, f.target.fd, 100,
    copied => progress.push(copied), () => false), /不完整|长度|截短/)
  assert.ok(progress.every(value => value <= 70))
})
test('copy propagates write errors without completion', async () => {
  const f = await copyFixture({ failWriteAt: 1 })
  const progress = []
  await assert.rejects(f.copyExportFileData(f.source.fd, f.target.fd, 70,
    copied => progress.push(copied), () => false), /disk full/)
  assert.ok(progress.every(value => value === 0))
})
test('copy rejects zero-byte writes', async () => {
  const f = await copyFixture({ writeLimit: 0 })
  await assert.rejects(f.copyExportFileData(f.source.fd, f.target.fd, 70, () => {}, () => false), /写入/)
})
test('native frame progress keeps fractional precision and reserves finalization', () => {
  const { nativeExportProgress } = loadEts('entry/src/main/ets/model/ExportProgress.ets')
  const update = nativeExportProgress({ percent: 25, stage: 2, currentFrame: 1, totalFrames: 100,
    completedUnits: 0, totalUnits: 0 })
  assert.equal(update.percent, 25.6)
  assert.equal(update.stage, 'encoding')
  assert.match(update.detail, /1.*100/)
  assert.equal(nativeExportProgress({ percent: 85, stage: 2, currentFrame: 120, totalFrames: 100 }).percent, 84.9)
})
test('native concat progress uses real work and never reaches save completion', () => {
  const { nativeExportProgress } = loadEts('entry/src/main/ets/model/ExportProgress.ets')
  const update = nativeExportProgress({ percent: 22, stage: 4, currentFrame: 0, totalFrames: 0,
    completedUnits: 1, totalUnits: 2 })
  assert.equal(update.percent, 23.5)
  assert.equal(update.stage, 'concatenating')
})

function pipelineFixture(fs, native = {}) {
  let calls = 0
  let payload
  const exporter = {
    getExportProgress: () => ({ percent: 25, stage: 2, currentFrame: 1, totalFrames: 100 }),
    cancelExport: () => true,
    async runExportPipelineAsync(request) {
      ++calls
      payload = request
      return native.run ? await native.run(request) : { code: 0, outputPath: request.outputPath }
    }
  }
  const service = loadEts('entry/src/main/ets/service/ExportNativeService.ets', {
    '@ohos.file.fs': fs, '@ohos.multimedia.image': {}, '@ohos.multimedia.media': {},
    'libsmartdrive_exporter.so': exporter, '../utils/Logger': { debugLog() {} }
  })
  const request = { frontUris: ['shared', 'shared'], backUris: ['shared', 'shared'],
    sideUris: [], side2Uris: [], templateId: 'T5', outputPath: '/data/storage/cache/out.mp4',
    segments: [{ startMs: 0, endMs: 10000, speedLabel: '1.0X', muted: false }],
    rangeStartMs: 0, rangeEndMs: 10000, expectedDurationSec: 10 }
  return { service, request, get calls() { return calls }, get payload() { return payload } }
}
test('materialization deduplicates source bytes while preserving repeated timeline references', async () => {
  const fs = memoryFs(new Map([['shared', Buffer.alloc(2500000, 3)]]))
  const f = pipelineFixture(fs)
  const updates = []
  await f.service.executeComposeByService(f.request, () => {}, update => updates.push(update))
  assert.equal(f.calls, 1)
  assert.equal(f.payload.frontUris.length, 2)
  assert.equal(new Set([...f.payload.frontUris, ...f.payload.backUris]).size, 1)
  assert.equal(fs.removed.length, 1)
  assert.equal(fs.opened.size, 0)
  assert.ok(updates.some(update => update.stage === 'preparing' && update.percent > 5 && update.percent < 20))
})
test('materialization failure cleans files and closes handles before rejecting', async () => {
  const fs = memoryFs(new Map([['shared', Buffer.alloc(70)]]), { failWriteAt: 1 })
  const f = pipelineFixture(fs)
  await assert.rejects(f.service.executeComposeByService(f.request, () => {}, () => {}), /disk full/)
  assert.equal(f.calls, 0)
  assert.equal(fs.opened.size, 0)
  assert.ok(![...fs.files.keys()].some(path => path.startsWith('/data/storage/cache/')))
})
test('cancelling during materialization never starts the native pipeline', async () => {
  const fs = memoryFs(new Map([['shared', Buffer.alloc(2500000)]]))
  const f = pipelineFixture(fs)
  let cancelled = false
  await assert.rejects(f.service.executeComposeByService(f.request, () => {}, update => {
    if (update.stage === 'preparing' && update.percent > 5) cancelled = true
  }, () => cancelled), /取消/)
  assert.equal(f.calls, 0)
  assert.equal(fs.opened.size, 0)
})
test('a failed parallel track reports the original error after other tracks stop', async () => {
  const fs = memoryFs(new Map([['front', Buffer.alloc(2500000)], ['back', Buffer.alloc(2500000)]]), { failWriteAt: 2 })
  const f = pipelineFixture(fs)
  f.request.frontUris = ['front']
  f.request.backUris = ['back']
  await assert.rejects(f.service.executeComposeByService(f.request, () => {}, () => {}), /disk full/)
  assert.equal(f.calls, 0)
  assert.equal(fs.opened.size, 0)
  assert.ok(![...fs.files.keys()].some(path => path.startsWith('/data/storage/cache/')))
})

function managerFixture(options = {}, content = Buffer.alloc(2500000, 7)) {
  // 相册目标初始为空：覆盖不再经过相册，saveVideoToAlbum 总是写进系统新建的空条目
  // （旧代码靠 OpenMode.TRUNC 把这里预置的字节清掉，TRUNC 分支已随覆盖路径一并删除）。
  const fs = memoryFs(new Map([['source', content], ['album', Buffer.alloc(0)]]), options)
  const { ExportManager } = loadEts('entry/src/main/ets/service/ExportManager.ets', {
    '@ohos.file.fs': fs,
    // 覆盖不再经过相册后，saveVideoToAlbum 总是走系统保存对话框；桩返回一个已存在的目标路径。
    '@ohos.file.photoAccessHelper': {
      PhotoType: { VIDEO: 1 },
      PhotoSubtype: { DEFAULT: 0 },
      getPhotoAccessHelper: () => ({ showAssetsCreationDialog: async () => ['album'] })
    },
    // WorkStore.freeBytes() 走这条：返回一个很大的数，让导出前的空间预检无条件放行。
    '@ohos.file.statvfs': { async getFreeSize() { return Number.MAX_SAFE_INTEGER } },
    '../model/Models': {}, '../model/TripModels': {}, './ExportService': {}, '../model/SegmentModel': {},
    './ExportNativeService': {}, '../model/EditRecord': {}, './EditHistoryService': {},
    './PreferencesService': {}, '../utils/Logger': { debugLog() {} }
  })
  const manager = new ExportManager()
  const updates = []
  const save = (isCancelled = () => false) => manager.saveVideoToAlbum('out.mp4', 'source', {}, 85,
    (percent, detail) => updates.push({ percent, detail }), isCancelled)
  return { fs, manager, updates, save, content }
}
test('album save retries short writes and writes the exact bytes', async () => {
  const f = managerFixture({ writeLimit: 13 }, Buffer.from('new video bytes'))
  assert.equal(await f.save(), 'album')
  assert.deepEqual(f.fs.files.get('album'), f.content)
  assert.equal(f.fs.opened.size, 0)
  assert.ok(f.updates.every(update => update.percent < 100))
})
test('album write error never fabricates final progress', async () => {
  const f = managerFixture({ failWriteAt: 2 })
  await assert.rejects(f.save(), /disk full/)
  assert.ok(f.updates.every(update => update.percent < 99))
  assert.equal(f.fs.opened.size, 0)
})
test('unknown album size holds percentage while reporting written bytes', async () => {
  const f = managerFixture({ unknownSize: true })
  await f.save()
  assert.ok(f.updates.every(update => update.percent === 85))
  assert.ok(f.updates.at(-1).detail.includes('已写入'))
})
test('album cancellation stops copying and closes both handles', async () => {
  const f = managerFixture()
  await assert.rejects(f.save(() => f.fs.files.get('album').length > 0 && f.updates.length > 1), /取消/)
  assert.equal(f.fs.files.get('album').length, 1048576)
  assert.equal(f.fs.opened.size, 0)
})
test('album target close failure cannot report success', async () => {
  const f = managerFixture({ failClosePath: 'album' })
  await assert.rejects(f.save(), /close failed/)
})
test('album flush failure cannot report success', async () => {
  const f = managerFixture({ failSync: true })
  await assert.rejects(f.save(), /flush failed/)
})
test('empty output cannot be saved as a successful video', async () => {
  const f = managerFixture({}, Buffer.alloc(0))
  await assert.rejects(f.save(), /为空/)
})
test('manager keeps fractional monotonic progress and immediately reports stage changes', () => {
  const { manager } = managerFixture()
  const events = []
  const record = { id: 'job', progress: 0, status: '', lastNotificationAt: 0, lastNotifiedStage: '',
    listeners: [event => events.push(event)] }
  manager.notify(record, '合成视频 · 25.7%', 25.7)
  manager.notify(record, '完成封装', 25.6)
  assert.deepEqual(events.map(event => event.progress), [25.7, 25.7])
})
test('a cancelled job cannot overlap another native job until cleanup completes', async () => {
  const { manager } = managerFixture()
  manager.jobs.set('old', { cancelled: true })
  await assert.rejects(manager.start({}, {}), /结束处理中/)
})

function nativeManagerFixture() {
  let timer
  let listener
  let cleared = false
  const cancelled = []
  let markReady
  const ready = new Promise(resolve => { markReady = resolve })
  const sharedExportManager = {
    async start() { return 'job' },
    subscribe(_job, callback) { listener = callback; markReady() },
    cancel(job) {
      cancelled.push(job)
      listener({ jobId: job, status: '已取消导出', progress: 0 })
    }
  }
  const wrapper = loadEts('entry/src/main/ets/NativeExportManager.ets', {
    './service/ExportManager': { sharedExportManager },
    __globals: { setTimeout(callback) { timer = callback; return 1 }, clearTimeout() { cleared = true } }
  })
  return { wrapper, cancelled, ready, fireTimer: () => timer(), emit: event => listener(event), get cleared() { return cleared } }
}
test('export timeout cancels the same background job before allowing a later retry', async () => {
  const f = nativeManagerFixture()
  const pending = f.wrapper.startNativeExport({}, {})
  await f.ready
  f.fireTimer()
  await assert.rejects(pending, /超时/)
  assert.deepEqual(f.cancelled, ['job'])
})
test('successful export clears its timeout without cancelling the job', async () => {
  const f = nativeManagerFixture()
  const pending = f.wrapper.startNativeExport({}, {})
  await f.ready
  f.emit({ jobId: 'job', status: '相册保存成功：album', progress: 100 })
  const outcome = await pending
  assert.equal(outcome.workId, 'album')
  assert.equal(outcome.metaSaved, false)
  assert.equal(f.cleared, true)
  assert.deepEqual(f.cancelled, [])
})

let failed = 0
for (const { name, run } of tests) {
  try { await run(); console.log(`PASS ${name}`) }
  catch (error) { failed++; console.error(`FAIL ${name}: ${error.message}`) }
}
console.log(`Export regression: ${tests.length - failed}/${tests.length} passed`)
process.exitCode = failed ? 1 : 0
