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
  const renamed = []
  const dirs = new Set()
  let nextFd = 1
  let writeCount = 0
  let renameCount = 0
  return {
    files, opened, buffers, removed, renamed, dirs,
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
    async unlink(path) { removed.push(path); files.delete(path) },
    // 以下四个是 WorkStore（作品库文件层）要用的：`exists` 走 accessSync，
    // `writeMeta` 走 rename，`readMeta` 走 readText，`ensureExportsDir` 走 mkdir。
    accessSync(path) {
      if (files.has(path) || dirs.has(path)) return true
      // 目录没显式建过，但已经有文件挂在它下面 —— 沙盒里就是这么个事实。
      for (const file of files.keys()) {
        if (file.startsWith(`${path}/`)) return true
      }
      return false
    },
    async mkdir(path) { dirs.add(path) },
    async readText(path) {
      if (!files.has(path)) throw new Error('not found')
      return files.get(path).toString('utf8')
    },
    async rename(from, to) {
      // failRenameAt: 第 n 次 rename 抛错，用来复现「真机上 fs.rename 拒绝覆盖已存在文件」。
      if (++renameCount === options.failRenameAt) throw new Error('rename refused')
      if (!files.has(from)) throw new Error('not found')
      files.set(to, files.get(from))
      files.delete(from)
      renamed.push({ from, to })
    }
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
    sideUris: [], side2Uris: [], templateId: 'T1', outputPath: '/data/storage/cache/out.mp4',
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
  // 相册目标初始为空：相册那份 App 不再管理（不覆盖、不截断），saveWorkToAlbum
  // 总是写进系统新建的空条目。
  const fs = memoryFs(new Map([['source', content], ['album', Buffer.alloc(0)]]), options)
  const { ExportManager } = loadEts('entry/src/main/ets/service/ExportManager.ets', {
    '@ohos.file.fs': fs,
    // WorkStore.freeBytes() 走这条：返回一个很大的数，让导出前的空间预检无条件放行。
    '@ohos.file.statvfs': { async getFreeSize() { return Number.MAX_SAFE_INTEGER } },
    '../model/Models': {}, '../model/TripModels': {}, './ExportService': {}, '../model/SegmentModel': {},
    './ExportNativeService': {},
    './PreferencesService': {}, '../utils/Logger': { debugLog() {} }
  })
  // 相册保存已从 ExportManager 抽到独立模块 AlbumExport（Task 10）。
  const { saveWorkToAlbum } = loadEts('entry/src/main/ets/service/AlbumExport.ets', {
    '@ohos.file.fs': fs,
    // 系统保存对话框的桩：总是返回一个已存在的目标路径。
    '@ohos.file.photoAccessHelper': {
      PhotoType: { VIDEO: 1 },
      PhotoSubtype: { DEFAULT: 0 },
      getPhotoAccessHelper: () => ({ showAssetsCreationDialog: async () => ['album'] })
    },
    // WorkEntry 只被当类型用（导入会被转译器消除）；给个空桩，免得加载 WorkStore 的裸依赖。
    './WorkStore': {},
    '../model/ExportProgress': loadEts('entry/src/main/ets/model/ExportProgress.ets'),
    '../utils/Logger': { debugLog() {} }
  })
  const manager = new ExportManager()
  const updates = []
  // saveWorkToAlbum 只读 entry.videoPath，用普通对象字面量即可（不必造真 WorkEntry）。
  const save = () => saveWorkToAlbum({}, { videoPath: 'source' },
    (percent, detail) => updates.push({ percent, detail }))
  return { fs, manager, updates, save, content }
}
test('album save retries short writes and writes the exact bytes', async () => {
  const f = managerFixture({ writeLimit: 13 }, Buffer.from('new video bytes'))
  // 契约：成功返回空串（调用方据此 toast「已保存到相册」）。
  assert.equal(await f.save(), '')
  assert.deepEqual(f.fs.files.get('album'), f.content)
  assert.equal(f.fs.opened.size, 0)
  assert.ok(f.updates.every(update => update.percent < 100))
})
test('album write error never fabricates final progress', async () => {
  const f = managerFixture({ failWriteAt: 2 })
  // 契约：失败返回给用户看的文案，而不是抛错。断言仍咬住底层原因，只是换成读返回值。
  const message = await f.save()
  assert.match(message, /^保存到相册失败：/)
  assert.match(message, /disk full/)
  assert.ok(f.updates.every(update => update.percent < 99))
  assert.equal(f.fs.opened.size, 0)
})
test('unknown album size holds percentage while reporting written bytes', async () => {
  const f = managerFixture({ unknownSize: true })
  await f.save()
  assert.ok(f.updates.every(update => update.percent === 85))
  assert.ok(f.updates.at(-1).detail.includes('已写入'))
})
test('album target close failure cannot report success', async () => {
  const f = managerFixture({ failClosePath: 'album' })
  assert.match(await f.save(), /close failed/)
})
test('album flush failure cannot report success', async () => {
  const f = managerFixture({ failSync: true })
  assert.match(await f.save(), /flush failed/)
})
test('empty output cannot be saved as a successful video', async () => {
  const f = managerFixture({}, Buffer.alloc(0))
  assert.match(await f.save(), /为空/)
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
  // 导出成功终态现在是 `已保存：<workId>`（Task 6 起，相册不再参与导出）。
  f.emit({ jobId: 'job', status: '已保存：work1', progress: 100 })
  const outcome = await pending
  assert.equal(outcome.workId, 'work1')
  assert.equal(outcome.metaSaved, false)
  assert.equal(f.cleared, true)
  assert.deepEqual(f.cancelled, [])
})

/**
 * `WorkStore`（作品库文件层）的夹具。
 *
 * 为什么值得单开一套：`WorkStore` 原来不进任何套件，而「覆盖导出」这条路的
 * 每一步都在它身上 —— 先删目标再改名会**毁掉用户唯一一份成片**，
 * 覆盖时不先清旧 sidecar 会留下「新成片 + 旧元数据」。这两条都是回归测试该咬住的。
 *
 * 每个用例自己传一份 `files`：`loadEts` 每次调用一份新的模块缓存，
 * 因此每次拿到的都是全新的 `WorkStore` 单例与全新的 memoryFs，用例之间不串味。
 */
function workStoreFixture(files, options = {}) {
  const fs = memoryFs(new Map(files), options)
  const { WorkStore } = loadEts('entry/src/main/ets/service/WorkStore.ets', {
    '@ohos.file.fs': fs,
    '@ohos.file.statvfs': { async getFreeSize() { return Number.MAX_SAFE_INTEGER } },
    // 封面抽帧要真的解 mp4，离线桩给不了 —— 固定返回 false（writeCoverFrom 只当它没抽到）。
    './ExportNativeService': { async extractFirstFrameToPath() { return false } },
    '../utils/Logger': { debugLog() {} }
  })
  const store = WorkStore.getInstance()
  store.setContext({ filesDir: '/files', cacheDir: '/cache' })
  return { fs, store }
}

test('moveIntoLibrary renames onto an existing work instead of unlinking it first', async () => {
  const f = workStoreFixture([
    ['/cache/render.mp4', Buffer.from('new render')],
    ['/files/exports/W.mp4', Buffer.from('old render')]
  ])
  assert.equal(await f.store.moveIntoLibrary('/cache/render.mp4', 'W'), true)
  assert.deepEqual(f.fs.files.get('/files/exports/W.mp4'), Buffer.from('new render'))
  // 关键不变量：**没有**先 unlink 目标。先删再改名的话，改名一旦抛错，
  // 用户手里那条作品就已经没了（而新成片还留在 cacheDir）。
  assert.deepEqual(f.fs.removed, [])
  assert.deepEqual(f.fs.renamed, [{ from: '/cache/render.mp4', to: '/files/exports/W.mp4' }])
})

test('a refused rename still lands the render through unlink plus rename', async () => {
  // 真机上 fs.rename 可能拒绝覆盖已存在文件：第一次 rename 抛错，兜底路径必须接管。
  const f = workStoreFixture([
    ['/cache/render.mp4', Buffer.from('new render')],
    ['/files/exports/W.mp4', Buffer.from('old render')]
  ], { failRenameAt: 1 })
  assert.equal(await f.store.moveIntoLibrary('/cache/render.mp4', 'W'), true)
  assert.deepEqual(f.fs.files.get('/files/exports/W.mp4'), Buffer.from('new render'))
  assert.deepEqual(f.fs.removed, ['/files/exports/W.mp4'])
})

test('clearing a work keeps its video and drops only the sidecar and the cover', async () => {
  const f = workStoreFixture([
    ['/files/exports/W.mp4', Buffer.from('video')],
    ['/files/exports/W.json', Buffer.from('{"id":"W"}')],
    ['/files/exports/W.jpg', Buffer.from('cover')]
  ])
  assert.equal(await f.store.clearWorkMetaAndCover('W'), true)
  assert.deepEqual([...f.fs.files.keys()], ['/files/exports/W.mp4'])
})

/**
 * 导出 → 落库整条路的夹具。
 *
 * 与 `managerFixture` 分开：那边只用到 `notify` 与 `saveWorkToAlbum`，所以
 * `'./ExportService': {}` 这类空桩够用；这边的 `ExportManager.run()` 会把
 * `buildComposeRequestByService` / `executeComposeByService` / `exportDurationSec`
 * 逐个调起来，空桩一调就 TypeError，必须给出能跑的形状。
 */
function libraryFixture(options = {}) {
  const oldRender = Buffer.from('edit-A-render')
  const newRender = Buffer.from('edit-B-render')
  const oldMeta = Buffer.from(JSON.stringify({
    schemaVersion: 1, id: 'W', createdAt: 111, exportedAt: 222, tripTitle: '旧编辑',
    tripStartTs: 1, tripEndTs: 2, templateId: 'T1',
    tracks: { front: ['a.mp4'], back: [], side: [], side2: [] },
    playback: { playheadMs: 0, segments: [{ startMs: 0, endMs: 1000, speedLabel: '1.0X', muted: false }] },
    watermarkEnabled: true, segmentCount: 1, durationMs: 1000
  }))
  const fs = memoryFs(new Map([
    ['/cache/render.mp4', newRender],
    ['/files/exports/W.mp4', oldRender],
    ['/files/exports/W.json', oldMeta],
    ['/files/exports/W.jpg', Buffer.from('edit-A-cover')]
  ]), options)
  const { ExportManager } = loadEts('entry/src/main/ets/service/ExportManager.ets', {
    '@ohos.file.fs': fs,
    '@ohos.file.statvfs': { async getFreeSize() { return Number.MAX_SAFE_INTEGER } },
    '../model/Models': {
      // 六个机位都要给：snapshotToLegacyClips 会挨个查 snapshot.trip.tracks[camera]，
      // 少一个就是 undefined.segments。
      CameraPosition: {
        FRONT: 'Front', REAR: 'Rear', LEFT: 'Left', RIGHT: 'Right',
        LEFT_FRONT: 'LeftFront', RIGHT_FRONT: 'RightFront'
      },
      toLegacyCamera: camera => camera
    },
    '../model/TripModels': {
      DvrMeta: class {
        constructor() {
          this.fileName = ''
          this.uri = ''
          this.camera = ''
          this.timestamp = 0
          this.date = ''
          this.time = ''
        }
      }
    },
    './ExportService': {
      buildComposeRequestByService: (clips, fileName, outputPath, expectedDurationSec, templateId) => ({
        frontUris: clips.map(clip => clip.uri), backUris: [], sideUris: [], side2Uris: [],
        templateId, outputPath, segments: [], rangeStartMs: 0, rangeEndMs: 0, expectedDurationSec
      })
    },
    '../model/SegmentModel': { exportDurationSec: () => 3 },
    './ExportNativeService': {
      // 合成产物：run() 会把它当 sourceUri 搬进作品库，所以路径要落在 memoryFs 里。
      executeComposeByService: async () => '/cache/render.mp4',
      extractFirstFrameToPath: async () => false,
      cancelNativeExportPipeline: () => {}
    },
    './PreferencesService': { PreferencesService: { getInstance: () => ({ setContext() {} }) } },
    '../utils/Logger': { debugLog() {} }
  })
  const snapshot = {
    sessionId: 's1',
    createdAt: 1,
    trip: {
      id: 'trip-1', title: '行程', startTs: 100, endTs: 200,
      tracks: {
        Front: { segments: [{ fileName: 'a.mp4', uri: 'file://clip/a.mp4', timestampMs: 1 }] },
        Rear: { segments: [] }, Left: { segments: [] }, Right: { segments: [] },
        LeftFront: { segments: [] }, RightFront: { segments: [] }
      }
    },
    selectedTemplateId: 'T1',
    playback: { playheadMs: 0, segments: [{ startMs: 0, endMs: 3000, speedLabel: '1.0X', muted: false }] },
    brand: { watermarkEnabled: false }
  }
  const context = { filesDir: '/files', cacheDir: '/cache' }
  return { fs, manager: new ExportManager(), snapshot, context, newRender }
}

/** 起一次导出并等到终态事件（`run()` 是 `void` 出去的，只能靠订阅收口）。 */
async function runExportToTerminal(f) {
  const events = []
  const jobId = await f.manager.start(f.snapshot, f.context, 'W')
  await new Promise(resolve => {
    f.manager.subscribe(jobId, event => {
      events.push(event)
      if (event.status.startsWith('已保存：') || event.status.startsWith('导出失败：') ||
        event.status === '已取消导出') {
        resolve()
      }
    })
  })
  return events
}

test('an overwrite whose sidecar write fails leaves no trace of the previous edit', async () => {
  // failWriteAt: 1 —— run() 走到写 sidecar 之前一次 fs.write 都没有（素材字节和是 stat，
  // 搬运用的是 rename，封面抽帧被桩成没抽到），所以第一次写就是 `<id>.json.tmp`。
  const f = libraryFixture({ failWriteAt: 1 })
  const events = await runExportToTerminal(f)
  const terminal = events.at(-1)
  assert.equal(terminal.status, '已保存：W')
  assert.equal(terminal.metaSaved, false)
  // 成片本体确实换成了新渲染。
  assert.deepEqual(f.fs.files.get('/files/exports/W.mp4'), f.newRender)
  // 不变量：**不得**还挂着上一次编辑的 sidecar / 封面。
  // 唯一允许的结局是「有 mp4 无 json」的降级态（卡片显示「无法重新剪辑」）——
  // 留下旧 sidecar 的话，卡片看上去可以重新剪辑，点进去却按旧模板/旧分段去还原
  // 一条不是它渲染出来的视频，再导出一次就把新编辑静默改回旧编辑。
  assert.equal(f.fs.files.has('/files/exports/W.json'), false)
  assert.equal(f.fs.files.has('/files/exports/W.jpg'), false)
})

let failed = 0
for (const { name, run } of tests) {
  try { await run(); console.log(`PASS ${name}`) }
  catch (error) { failed++; console.error(`FAIL ${name}: ${error.message}`) }
}
console.log(`Export regression: ${tests.length - failed}/${tests.length} passed`)
process.exitCode = failed ? 1 : 0
