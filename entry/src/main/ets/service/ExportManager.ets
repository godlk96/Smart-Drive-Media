import common from '@ohos.app.ability.common'
import fs from '@ohos.file.fs'
import photoAccessHelper from '@ohos.file.photoAccessHelper'
import { CameraPosition, ExportSnapshot, toLegacyCamera } from '../model/Models'
import { DvrMeta, ExportComposeRequest } from '../model/TripModels'
import { buildComposeRequestByService } from './ExportService'
import { exportDurationSec } from '../model/SegmentModel'
import { executeComposeByService, cancelNativeExportPipeline } from './ExportNativeService'
import { WorkMeta, workIdFromFileName } from '../model/WorkMeta'
import { collectWorkTracks } from '../model/WorkRestore'
import { WorkStore } from './WorkStore'
import { PreferencesService } from './PreferencesService'
import { debugLog } from '../utils/Logger'
import { copyExportFileData } from './ExportFileCopy'
import { ExportProgressUpdate, exportPercent, exportStageText } from '../model/ExportProgress'

export type ExportJobId = string

export interface ExportJobEvent {
  jobId: ExportJobId
  status: string
  progress: number
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

  private notify(record: ExportJobRecord, status: string, progress: number): void {
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
    const event: ExportJobEvent = { jobId: record.id, status: status, progress: normalizedProgress }
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
      overwriteWorkId: overwriteWorkId ?? ''
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
            this.notify(record, `${exportStageText(update.stage)} · ${update.percent.toFixed(1)}% · ${update.detail}`, update.percent)
          }
        },
        (): boolean => record.cancelled
      )
      if (record.cancelled) {
        return
      }
      const saveStartProgress = Math.max(85, Math.min(99, record.progress))
      this.notify(record, '正在写入作品库', saveStartProgress)
      // 成片本体搬进作品库：mp4 才是作品本体，这一步失败就没有「作品」可言，如实报失败。
      const moved = await store.moveIntoLibrary(sourceUri, workId)
      if (!moved) {
        throw new Error('导出产物保存失败')
      }
      // 覆盖时沿用旧作品的 createdAt；sidecar 缺失（首次导出 / 降级卡片）则用现在。
      const existingMeta = record.overwriteWorkId.length > 0 ? await store.readMeta(workId) : undefined
      const meta = this.buildWorkMeta(snapshot, clips, request, workId, existingMeta)
      const metaSaved = await store.writeMeta(meta)
      if (!metaSaved) {
        // mp4 已经是作品本体，sidecar 没落盘只影响卡片的元信息；此时把导出报成失败是撒谎。
        debugLog('导出', `作品元数据写入失败（成片已落库） id=${workId}`)
      }
      const successEvent: ExportJobEvent = { jobId: record.id, status: `已保存：${workId}`, progress: 100 }
      this.recordTerminalEvent(record.id, successEvent)
      this.notify(record, `导出完成：${workId}`, 100)
      this.notify(record, `已保存：${workId}`, 100)
    } catch (error) {
      if (record.cancelled) {
        debugLog('导出', '任务已取消，终止 run 并清理残留文件')
        try {
          if (outputPath.length > 0 && fs.accessSync(outputPath)) {
            fs.unlinkSync(outputPath)
          }
        } catch (_) {
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
   * 把成片写入系统相册（**总是新建条目**）。
   *
   * 本任务已把它的**调用**移出导出主流程：成片改为落进 App 私有作品库，相册不再参与导出。
   * 方法体保留给 Task 10 抽成显式的「保存到相册」动作复用，故此处只删掉就地覆写
   * （`fs.OpenMode.TRUNC`）分支 —— 覆盖不再经过相册，不再需要截断旧字节。
   */
  private async saveVideoToAlbum(
    fileName: string,
    sourceUri: string,
    context: common.UIAbilityContext,
    startProgress: number,
    onProgress: (percent: number, detail: string) => void,
    isCancelled: () => boolean
  ): Promise<string> {
    try {
      const helper = photoAccessHelper.getPhotoAccessHelper(context)
      const srcFileUris: Array<string> = [sourceUri]
      const dotIndex = fileName.lastIndexOf('.')
      const title = dotIndex > 0 ? fileName.slice(0, dotIndex) : fileName
      const photoCreationConfigs: Array<photoAccessHelper.PhotoCreationConfig> = [{
        title: title,
        fileNameExtension: 'mp4',
        photoType: photoAccessHelper.PhotoType.VIDEO,
        subtype: photoAccessHelper.PhotoSubtype.DEFAULT
      }]
      const desFileUris = await helper.showAssetsCreationDialog(srcFileUris, photoCreationConfigs)
      const created = desFileUris[0]
      if (!created || created.length === 0) {
        throw new Error('未选择相册保存位置')
      }
      const albumUri = created
      debugLog('导出', `相册写入开始 source=${sourceUri} target=${albumUri}`)
      let srcFd: number = -1
      let dstFd: number = -1
      let totalSize: number = 0
      let copiedSize: number = 0
      const baseProgress: number = Math.max(85, Math.min(99, startProgress))
      try {
        try {
          const stat = await fs.stat(sourceUri)
          totalSize = Number(stat.size ?? 0)
        } catch (_) {
          totalSize = 0
        }
        if (isCancelled()) {
          throw new Error('已取消导出')
        }
        const src = await fs.open(sourceUri, fs.OpenMode.READ_ONLY)
        srcFd = src.fd
        const dst = await fs.open(albumUri, fs.OpenMode.READ_WRITE)
        dstFd = dst.fd
        try {
          await copyExportFileData(srcFd, dstFd, totalSize, (copied: number, total: number) => {
            copiedSize = copied
            const percent = total > 0 ? exportPercent(baseProgress + Math.min(1, copied / total) * (99 - baseProgress)) : baseProgress
            const detail = total > 0 ? `${(copied / 1048576).toFixed(1)} / ${(total / 1048576).toFixed(1)} MB` :
              `已写入 ${(copied / 1048576).toFixed(1)} MB`
            onProgress(percent, detail)
          }, isCancelled)
          if (copiedSize <= 0) {
            throw new Error('导出文件为空，未写入相册')
          }
          await fs.fsync(dstFd)
        } catch (error) {
          if (isCancelled()) {
            throw new Error('已取消导出')
          }
          const copyError = error instanceof Error ? error.message : String(error)
          throw new Error(`相册写入中断（已写入 ${copiedSize}/${totalSize} 字节）：${copyError}`)
        }
      } finally {
        if (srcFd >= 0) {
          try {
            await fs.close(srcFd)
          } catch (_) {
          }
        }
        if (dstFd >= 0) {
          try {
            await fs.close(dstFd)
          } catch (error) {
            throw new Error(`相册文件关闭失败：${error instanceof Error ? error.message : String(error)}`)
          }
        }
      }
      return albumUri
    } catch (error) {
      throw new Error(`保存到相册失败: ${error instanceof Error ? error.message : String(error)}`)
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
    meta.tracks = collectWorkTracks(clips, request)
    meta.templateId = snapshot.selectedTemplateId
    meta.playback = snapshot.playback
    meta.watermarkEnabled = snapshot.brand.watermarkEnabled
    meta.segmentCount = snapshot.playback.segments.length
    meta.durationMs = Math.round(exportDurationSec(snapshot.playback.segments) * 1000)
    return meta
  }
}

export const sharedExportManager = new ExportManager()
