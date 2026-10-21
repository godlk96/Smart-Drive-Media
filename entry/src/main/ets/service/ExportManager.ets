import common from '@ohos.app.ability.common'
import fs from '@ohos.file.fs'
import { CameraPosition, ExportSnapshot, toLegacyCamera } from '../model/Models'
import { DvrMeta, ExportComposeRequest } from '../model/TripModels'
import { buildComposeRequestByService } from './ExportService'
import { exportDurationSec } from '../model/SegmentModel'
import { executeComposeByService, cancelNativeExportPipeline } from './ExportNativeService'
import { WorkMeta, workIdFromFileName, templateAspectRatio } from '../model/WorkMeta'
import { collectWorkTracks } from '../model/WorkRestore'
import { WorkStore } from './WorkStore'
import { PreferencesService } from './PreferencesService'
import { debugLog } from '../utils/Logger'
import { ExportProgressUpdate, exportPercent, exportStageText } from '../model/ExportProgress'

export type ExportJobId = string

/**
 * 作品绑定的**全部**源片段名（这一趟 / 这几趟行程里所有视角），去重保序。
 *
 * 与 `collectWorkTracks` 的区别：那个记的是"导出时真正送进编码器的四条轨道"，
 * 单视角导出只有 front 一条；这个记的是"这件作品依赖哪些源文件"，用来回答
 * 「原素材是不是少了一个」。详见 `WorkMeta.sourceClips` 的注释。
 */
function collectSourceClipNames(clips: Array<DvrMeta>): Array<string> {
  const out: Array<string> = []
  for (let i = 0; i < clips.length; i++) {
    const name: string = clips[i].fileName
    if (name.length > 0 && out.indexOf(name) < 0) {
      out.push(name)
    }
  }
  return out
}

export interface ExportJobEvent {
  jobId: ExportJobId
  status: string
  progress: number
  /** 仅终态事件带：sidecar 是否落盘。false = 降级卡片，调用方据此如实告知用户。 */
  metaSaved?: boolean
}

type ExportListener = (event: ExportJobEvent) => void

/** 终态事件缓存上限：仅用于给迟到订阅者补发，超出即淘汰最旧项 */
const TERMINAL_EVENT_KEEP: number = 8

interface ExportJobRecord {
  id: ExportJobId
  snapshot: ExportSnapshot
  listeners: Array<ExportListener>
  cancelled: boolean
  progress: number
  status: string
  lastNotificationAt: number
  lastNotifiedStage: string
  /** 空串 = 新建作品；非空 = 就地覆写这个已有作品（文件基名即作品 id） */
  overwriteWorkId: string
  /**
   * 是否已进入「作品库写入阶段」（清旧 sidecar → 换 mp4 → 写新 sidecar）。
   *
   * 置位后这次导出就一定会落成一个作品，因此 `cancel()` 不再发「已取消导出」终态 ——
   * 否则用户会看到「已取消导出」，作品却实实在在地出现在「我的剪辑」里。
   */
  libraryWriteStarted: boolean
}

function snapshotToLegacyClips(snapshot: ExportSnapshot): Array<DvrMeta> {
  const clips: Array<DvrMeta> = []
  const cameras: Array<CameraPosition> = [
    CameraPosition.FRONT,
    CameraPosition.REAR,
    CameraPosition.LEFT,
    CameraPosition.RIGHT,
    CameraPosition.LEFT_FRONT,
    CameraPosition.RIGHT_FRONT
  ]
  cameras.forEach((camera: CameraPosition) => {
    const track = snapshot.trip.tracks[camera]
    track.segments.forEach((segment) => {
      const clip = new DvrMeta()
      // 用快照里记的真名，不要再拿 `${clipId}.mp4` 编一个：clipId 里嵌着不稳定的
      // trip id 和一个会随片段增删移位的下标，编出来的名字对不上任何源文件。
      clip.fileName = segment.fileName
      clip.uri = segment.uri
      clip.camera = toLegacyCamera(camera)
      clip.timestamp = segment.timestampMs
      clip.date = ''
      clip.time = ''
      clips.push(clip)
    })
  })
  clips.sort((a: DvrMeta, b: DvrMeta) => a.timestamp - b.timestamp)
  return clips
}

function buildExportFileName(): string {
  const now = new Date()
  const yyyy = now.getFullYear().toString()
  const mm = (now.getMonth() + 1).toString().padStart(2, '0')
  const dd = now.getDate().toString().padStart(2, '0')
  const hh = now.getHours().toString().padStart(2, '0')
  const min = now.getMinutes().toString().padStart(2, '0')
  const ss = now.getSeconds().toString().padStart(2, '0')
  return `SmartDrive_Export_${yyyy}${mm}${dd}_${hh}${min}${ss}.mp4`
}

function cloneExportSnapshot(snapshot: ExportSnapshot): ExportSnapshot {
  return JSON.parse(JSON.stringify(snapshot)) as ExportSnapshot
}

export class ExportManager {
  private jobs: Map<ExportJobId, ExportJobRecord> = new Map()
  private terminalEvents: Map<ExportJobId, ExportJobEvent> = new Map()

  private recordTerminalEvent(jobId: ExportJobId, event: ExportJobEvent): void {
    this.terminalEvents.set(jobId, event)
    // 有界缓存：只保留最近 TERMINAL_EVENT_KEEP 条，避免长会话无界增长
    while (this.terminalEvents.size > TERMINAL_EVENT_KEEP) {
      let oldestKey: ExportJobId | undefined = undefined
      for (const key of this.terminalEvents.keys()) {
        oldestKey = key
        break
      }
      if (oldestKey === undefined) {
        break
      }
      this.terminalEvents.delete(oldestKey)
    }
  }

  private notify(record: ExportJobRecord, status: string, progress: number, metaSaved: boolean = false): void {
    const normalizedProgress = Math.max(record.progress, exportPercent(progress))
    record.progress = normalizedProgress
    record.status = status
    const stage = status.split(' · ')[0]
    const terminal = normalizedProgress === 100 || status.startsWith('导出失败：') || status === '已取消导出'
    if (!terminal && stage === record.lastNotifiedStage && Date.now() - record.lastNotificationAt < 120) {
      return
    }
    record.lastNotificationAt = Date.now()
    record.lastNotifiedStage = stage
    const event: ExportJobEvent = { jobId: record.id, status: status, progress: normalizedProgress, metaSaved: metaSaved }
    record.listeners.forEach((listener: ExportListener) => {
      listener(event)
    })
  }

  subscribe(jobId: ExportJobId, listener: ExportListener): void {
    const terminal = this.terminalEvents.get(jobId)
    if (terminal) {
      // 迟到的订阅者：补发终态事件后即可回收该缓存项
      this.terminalEvents.delete(jobId)
      listener(terminal)
      return
    }
    const record = this.jobs.get(jobId)
    if (!record) {
      return
    }
    record.listeners = [...record.listeners, listener]
    listener({ jobId: record.id, status: record.status, progress: record.progress })
  }

  cancel(jobId: ExportJobId): void {
    const record = this.jobs.get(jobId)
    if (!record) {
      return
    }
    record.cancelled = true
    cancelNativeExportPipeline()
    // 已进入作品库写入阶段：成片会被保存下来，作品会成立。此刻立刻播「已取消导出」
    // 是在撒谎 —— 而且 `run()` 有意在这个阶段不再做取消检查（见那里的注释），
    // 它随后一定会发出 `已保存：` 终态，两条终态事件互相矛盾。
    // 所以这里只置取消位、停掉 native 管线，终态交给 `run()` 唯一的那条事件。
    if (record.libraryWriteStarted) {
      return
    }
    // 记录终态，保证订阅者必定 settle（否则只能等 180s 超时）
    const cancelEvent: ExportJobEvent = { jobId: record.id, status: '已取消导出', progress: 0 }
    this.recordTerminalEvent(record.id, cancelEvent)
    this.notify(record, '已取消导出', 0)
  }

  cancelAll(): void {
    cancelNativeExportPipeline()
    const jobIds: Array<ExportJobId> = []
    this.jobs.forEach((_, key) => {
      jobIds.push(key)
    })
    jobIds.forEach((id) => this.cancel(id))
  }

  async start(
    snapshot: ExportSnapshot,
    context: common.UIAbilityContext,
    overwriteWorkId?: string
  ): Promise<ExportJobId> {
    // 原生只有一份进度/取消状态；旧任务完全退出前不能复用这份全局状态。
    if (this.jobs.size > 0) {
      throw new Error('上一次导出仍在结束处理中，请稍后重试')
    }
    // 导出不一定经过 CoreBridge，那条路径上的 setContext 可能还没跑过，这里补一次
    // （重复设置无副作用）。PreferencesService 供旧记录链，WorkStore 供作品库文件系统层。
    PreferencesService.getInstance().setContext(context)
    WorkStore.getInstance().setContext(context)
    const isolatedSnapshot = cloneExportSnapshot(snapshot)
    const jobId = `${isolatedSnapshot.sessionId}_${Date.now()}`
    const record: ExportJobRecord = {
      id: jobId,
      snapshot: isolatedSnapshot,
      listeners: [],
      cancelled: false,
      progress: 0,
      status: '准备导出',
      lastNotificationAt: 0,
      lastNotifiedStage: '',
      overwriteWorkId: overwriteWorkId ?? '',
      libraryWriteStarted: false
    }
    this.jobs.set(jobId, record)
    this.notify(record, '导出处理中 0%', 0)
    void this.run(record, context)
    return jobId
  }

  private async run(record: ExportJobRecord, context: common.UIAbilityContext): Promise<void> {
    const store = WorkStore.getInstance()
    const fileName = buildExportFileName()
    // 覆盖时沿用被覆盖那条作品的 id（文件基名）；新建时取本次导出文件名去扩展名。
    const workId = record.overwriteWorkId.length > 0 ? record.overwriteWorkId : workIdFromFileName(fileName)
    let outputPath: string = ''
    try {
      const snapshot = record.snapshot
      const clips = snapshotToLegacyClips(snapshot)
      if (clips.length === 0) {
        throw new Error('缺少可导出素材')
      }
      const cacheDir = context.cacheDir ?? context.filesDir ?? '/data/storage/el2/base/files'
      // 合成产物先落 cacheDir：native 会把 `<outputPath>.front.concat.mp4` 之类的中间态写在同级、
      // JS 侧的素材副本也落在 outputPath 的父目录 —— 绝不能是 exports/，否则作品库被垃圾污染。
      outputPath = `${cacheDir}/${workId}.mp4.tmp`
      const request = buildComposeRequestByService(
        clips,
        fileName,
        outputPath,
        Math.max(1, exportDurationSec(snapshot.playback.segments)),
        snapshot.selectedTemplateId,
        snapshot.playback.segments,
        snapshot.brand.watermarkEnabled
      )
      debugLog('导出', `【导出参数-任务快照】workId=${workId} template=${request.templateId} expectedDurationSec=${request.expectedDurationSec} watermark=${request.watermarkEnabled}`)
      debugLog('导出', `【导出参数-轨道输入】Front=${request.frontUris.length}路 Back=${request.backUris.length}路 Side=${request.sideUris.length}路`)
      request.frontUris.forEach((uri, idx) => debugLog('导出', `  -> Front[${idx}]: ${uri}`))
      request.backUris.forEach((uri, idx) => debugLog('导出', `  -> Back[${idx}]: ${uri}`))
      request.sideUris.forEach((uri, idx) => debugLog('导出', `  -> Side[${idx}]: ${uri}`))
      debugLog('导出', `【导出参数-片段列表】总段数=${request.segments.length}`)
      for (let i = 0; i < request.segments.length; i++) {
        const seg = request.segments[i]
        debugLog('导出', `  -> Seg[${i}]: [${seg.startMs}ms ~ ${seg.endMs}ms] (${(seg.startMs / 1000).toFixed(2)}s ~ ${(seg.endMs / 1000).toFixed(2)}s) speed=${seg.speedLabel} muted=${seg.muted ? 'YES' : 'NO'}`)
      }
      if (record.cancelled) {
        return
      }
      // 合成前查空间：freeBytes() 取不到返回 -1（探针失败 = 未知），此时跳过校验继续导出 ——
      // 写成 `free < max(...)` 的话，一次探针失败会让**每一次**导出都永久失败。
      // 预留 3 倍源大小：合成期间同时存在 native 的轨道 concat 副本、JS 侧落地的素材副本、成品本身。
      const sourceBytes = await this.sumSourceBytes(request)
      const free = await store.freeBytes()
      if (free >= 0 && free < Math.max(512 * 1024 * 1024, sourceBytes * 3)) {
        throw new Error('存储空间不足，无法导出')
      }
      const sourceUri = await executeComposeByService(
        request,
        (message: string) => {
          debugLog('导出', message)
        },
        (update: ExportProgressUpdate) => {
          if (!record.cancelled) {
            // 百分比只由浮层中间那个进度环来表达。原来这行文案里也塞了一个
            // 「· 28.9% ·」，于是同一个数字在同一个弹窗里出现两次。
            // detail 为空时不再拖一个光秃秃的分隔符在尾巴上。
            const label: string = update.detail.length > 0
              ? `${exportStageText(update.stage)} · ${update.detail}`
              : exportStageText(update.stage)
            this.notify(record, label, update.percent)
          }
        },
        (): boolean => record.cancelled
      )
      if (record.cancelled) {
        return
      }
      const saveStartProgress = Math.max(85, Math.min(99, record.progress))
      // 从这里起是「作品库写入阶段」：清旧 sidecar/封面 → 换 mp4 → 抽封面 → 写新 sidecar。
      // 一旦进入这个阶段，这次导出就注定会落成一个作品，所以先置位：cancel() 见到它
      // 就不再播「已取消导出」终态（作品确实会被保存下来，那时改口说「已取消」才是撒谎），
      // 由本方法末尾那条唯一终态事件如实收尾。
      record.libraryWriteStarted = true
      // 覆盖时沿用旧作品的 createdAt，所以必须在成片被替换**之前**读它：此刻 `<id>.json`
      // 还是上一次编辑的 sidecar，createdAt 就是那个值；挪到 moveIntoLibrary 之后读，
      // 读到的会是刚被清掉的那份（什么都没有）。
      const overwriting = record.overwriteWorkId.length > 0
      const existingMeta = overwriting ? await store.readMeta(workId) : undefined
      if (overwriting) {
        // 覆盖 = 就地换掉 `<id>.mp4`，但 `<id>.json` / `<id>.jpg` 不会自己跟着换。
        // 旧 sidecar 必须**在换 mp4 之前**删掉：否则 writeMeta 失败（ENOSPC/EIO）或
        // 进程在中间被杀时，盘上留下的是「**新成片 + 上一次编辑的元数据**」——卡片照样
        // 显示可重新剪辑（canReedit 只看 meta !== undefined），点进去按旧模板/旧分段还原
        // 一条不是它渲染出来的视频，再导出一次就把新编辑静默改回旧编辑。
        // 先删则最坏退化成**已设计**的降级态（有 mp4 无 json → 「无法重新剪辑」徽标）。
        // 这一步也是「mp4 → jpg → json」那个写入顺序成立的前提：该顺序只对**新作品**
        // 天然成立，覆盖时必须先把上一份 sidecar 拿掉才等价。
        const cleared = await store.clearWorkMetaAndCover(workId)
        if (!cleared) {
          debugLog('导出', `旧元数据/封面清理失败（仍继续覆盖） id=${workId}`)
        }
      }
      this.notify(record, '正在写入作品库', saveStartProgress)
      // 有意为之：合成后到这里之间不再做取消检查。moveIntoLibrary 只是一次 rename，
      // 取消若落在它期间，成片已经进库、作品已成立 —— 此时改口说「已取消」才是撒谎。
      // 成片本体搬进作品库：mp4 才是作品本体，这一步失败就没有「作品」可言，如实报失败。
      const moved = await store.moveIntoLibrary(sourceUri, workId)
      if (!moved) {
        throw new Error('导出产物保存失败')
      }
      // 封面首帧：抽成片本体（此刻已在 exports/<id>.mp4）的首帧写 <id>.jpg。
      // 失败只记日志、不阻断导出 —— 没有 jpg 就是卡片回落到占位图（Task 7）。
      const coverSaved = await store.writeCoverFrom(`${store.exportsDir()}/${workId}.mp4`, workId,
        templateAspectRatio(snapshot.selectedTemplateId))
      if (!coverSaved) {
        debugLog('导出', `封面首帧写入失败（成片已落库） id=${workId}`)
      }
      const meta = this.buildWorkMeta(snapshot, clips, request, workId, existingMeta)
      const metaSaved = await store.writeMeta(meta)
      if (!metaSaved) {
        // mp4 已经是作品本体，sidecar 没落盘只影响卡片的元信息；此时把导出报成失败是撒谎。
        debugLog('导出', `作品元数据写入失败（成片已落库） id=${workId}`)
      }
      // 单一终态事件：文案只说「已保存」，降级信息走 metaSaved 结构化字段，由调用方措辞。
      const terminalText: string = `已保存：${workId}`
      this.recordTerminalEvent(record.id, { jobId: record.id, status: terminalText, progress: 100, metaSaved: metaSaved })
      this.notify(record, terminalText, 100, metaSaved)
    } catch (error) {
      if (record.cancelled) {
        debugLog('导出', '任务已取消，终止 run 并清理残留文件')
        try {
          if (outputPath.length > 0 && fs.accessSync(outputPath)) {
            fs.unlinkSync(outputPath)
          }
        } catch (_) {
        }
        // 进入作品库写入阶段后 `cancel()` 有意不再发终态（那时作品会成立，改口说「已取消」
        // 是撒谎）。可这一步抛错意味着作品**并没有**成立 —— 必须由这里补一条终态，
        // 否则订阅者拿不到任何 settle 信号，只能干等 NativeExportManager 的 180s 超时。
        if (record.libraryWriteStarted) {
          const cancelEvent: ExportJobEvent = { jobId: record.id, status: '已取消导出', progress: 0 }
          this.recordTerminalEvent(record.id, cancelEvent)
          this.notify(record, '已取消导出', 0)
        }
        return
      }
      const message = error instanceof Error ? error.message : String(error)
      if (message.indexOf('已取消') >= 0 || message.indexOf('cancel') >= 0) {
        record.cancelled = true
        debugLog('导出', '底层上报取消，终止 run 并清理残留文件')
        try {
          if (outputPath.length > 0 && fs.accessSync(outputPath)) {
            fs.unlinkSync(outputPath)
          }
        } catch (_) {
        }
        const cancelEvent: ExportJobEvent = { jobId: record.id, status: '已取消导出', progress: 0 }
        this.recordTerminalEvent(record.id, cancelEvent)
        this.notify(record, '已取消导出', 0)
        return
      }
      const stack = error instanceof Error && error.stack !== undefined ? error.stack : ''
      debugLog('导出', `导出失败：${message}${stack.length > 0 ? `\n${stack}` : ''}`)
      const failureEvent: ExportJobEvent = { jobId: record.id, status: `导出失败：${message}`, progress: 0 }
      this.recordTerminalEvent(record.id, failureEvent)
      this.notify(record, `导出失败：${message}`, 0)
    } finally {
      this.jobs.delete(record.id)
    }
  }

  /**
   * 四条轨道全部源片段的字节和，用于导出前的空间校验。
   *
   * 单个文件 `fs.stat` 失败按 0 计 —— 探不到就当它小，绝不因为一个源文件读不到就阻断导出。
   */
  private async sumSourceBytes(request: ExportComposeRequest): Promise<number> {
    const uris: Array<string> = [
      ...request.frontUris,
      ...request.backUris,
      ...request.sideUris,
      ...request.side2Uris
    ]
    let total: number = 0
    for (let i = 0; i < uris.length; i++) {
      try {
        const stat = await fs.stat(uris[i])
        total += Math.max(0, Number(stat.size ?? 0))
      } catch (_) {
      }
    }
    return total
  }

  /**
   * 构造作品 sidecar。`createdAt` 在覆盖时沿用旧作品的，新建时用现在；
   * `tracks` 记的是导出那一刻真正送进 native 的四条轨道（Task 3 的 `collectWorkTracks`）。
   */
  private buildWorkMeta(
    snapshot: ExportSnapshot,
    clips: Array<DvrMeta>,
    request: ExportComposeRequest,
    workId: string,
    existing: WorkMeta | undefined
  ): WorkMeta {
    const meta = new WorkMeta()
    meta.id = workId
    meta.createdAt = existing ? existing.createdAt : Date.now()
    meta.exportedAt = Date.now()
    meta.tripTitle = snapshot.trip.title
    meta.tripStartTs = snapshot.trip.startTs
    meta.tripEndTs = snapshot.trip.endTs
    meta.sourceTripCount = snapshot.trip.groupCount
    meta.tracks = collectWorkTracks(clips, request)
    // 记下**全部**源片段，而不只是导出用到的那几路 —— 还原时"少一个就不让进"靠它判定。
    meta.sourceClips = collectSourceClipNames(clips)
    meta.templateId = snapshot.selectedTemplateId
    meta.playback = snapshot.playback
    meta.watermarkEnabled = snapshot.brand.watermarkEnabled
    meta.segmentCount = snapshot.playback.segments.length
    meta.durationMs = Math.round(exportDurationSec(snapshot.playback.segments) * 1000)
    return meta
  }
}

export const sharedExportManager = new ExportManager()
