import common from '@ohos.app.ability.common'
import fs from '@ohos.file.fs'
import photoAccessHelper from '@ohos.file.photoAccessHelper'
import { CameraPosition, ExportSnapshot, toLegacyCamera } from '../model/Models'
import { DvrMeta } from '../model/TripModels'
import { buildComposeRequestByService } from './ExportService'
import { exportDurationSec } from '../model/SegmentModel'
import { executeComposeByService, cancelNativeExportPipeline } from './ExportNativeService'
import { EditRecord, makeRecordId } from '../model/EditRecord'
import { EditHistoryService } from './EditHistoryService'
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
  /** 空串 = 新建相册条目；非空 = 就地覆写这个已有条目的 URI（spec 4.5） */
  overwriteTargetUri: string
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
      clip.fileName = `${segment.clipId}.mp4`
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
    overwriteTargetUri?: string
  ): Promise<ExportJobId> {
    // 原生只有一份进度/取消状态；旧任务完全退出前不能复用这份全局状态。
    if (this.jobs.size > 0) {
      throw new Error('上一次导出仍在结束处理中，请稍后重试')
    }
    // 记录落盘要用 context 打开偏好设置。导出不一定经过 CoreBridge，
    // 那条路径上的 setContext 可能还没跑过，这里补一次（重复设置无副作用）。
    PreferencesService.getInstance().setContext(context)
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
      overwriteTargetUri: overwriteTargetUri ?? ''
    }
    this.jobs.set(jobId, record)
    this.notify(record, '导出处理中 0%', 0)
    void this.run(record, context)
    return jobId
  }

  private async run(record: ExportJobRecord, context: common.UIAbilityContext): Promise<void> {
    const fileName = buildExportFileName()
    let outputPath: string = ''
    try {
      const snapshot = record.snapshot
      const clips = snapshotToLegacyClips(snapshot)
      if (clips.length === 0) {
        throw new Error('缺少可导出素材')
      }
      const cacheDir = context.cacheDir ?? context.filesDir ?? '/data/storage/el2/base/files'
      outputPath = `${cacheDir}/${fileName}`
      const request = buildComposeRequestByService(
        clips,
        fileName,
        outputPath,
        Math.max(1, exportDurationSec(snapshot.playback.segments)),
        snapshot.selectedTemplateId,
        snapshot.playback.segments,
        snapshot.brand.watermarkEnabled
      )
      debugLog('导出', `【导出参数-任务快照】fileName=${fileName} template=${request.templateId} expectedDurationSec=${request.expectedDurationSec} watermark=${request.watermarkEnabled}`)
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
      this.notify(record, record.overwriteTargetUri.length > 0 ? '保存相册 · 正在打开成片' : '请选择相册保存位置', saveStartProgress)
      const albumUri = await this.saveVideoToAlbum(fileName, sourceUri, context, saveStartProgress, (progress: number, detail: string) => {
        if (!record.cancelled) {
          this.notify(record, `保存相册 · ${progress.toFixed(1)}% · ${detail}`, progress)
        }
      }, record.overwriteTargetUri, (): boolean => record.cancelled)
      // 取消可能发生在拷贝途中：拷完才发的取消也不能再落记录，
      // 否则用户看到「已取消导出」，相册却多了一条、历史里也多了一条。
      if (record.cancelled) {
        debugLog('导出', '相册写入完成后发现已取消，放弃落记录')
        return
      }
      // 先落记录再发成功事件：列表里能立刻看到这条作品。
      // persistRecord 内部吞掉一切异常 —— 落盘失败不能把成功的导出判成失败。
      await this.persistRecord(record, albumUri, fileName)
      const successEvent: ExportJobEvent = { jobId: record.id, status: `相册保存成功：${albumUri}`, progress: 100 }
      this.recordTerminalEvent(record.id, successEvent)
      this.notify(record, `导出完成：${fileName}`, 100)
      this.notify(record, `相册保存成功：${albumUri}`, 100)
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

  private async saveVideoToAlbum(
    fileName: string,
    sourceUri: string,
    context: common.UIAbilityContext,
    startProgress: number,
    onProgress: (percent: number, detail: string) => void,
    overwriteTargetUri: string,
    isCancelled: () => boolean
  ): Promise<string> {
    const isOverwrite = overwriteTargetUri.length > 0
    let albumUri = overwriteTargetUri
    try {
        if (!isOverwrite) {
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
          albumUri = created
        }
        debugLog('导出', `相册写入开始 source=${sourceUri} target=${albumUri} 覆盖=${isOverwrite ? 'YES' : 'NO'}`)
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
          // 覆盖必须带 TRUNC：新成片比旧的短时，不截断会在文件尾部残留旧字节，
          // 产物直接损坏（spec 4.6）。新建条目本来就是空的，不需要。
          const dstMode = isOverwrite
            ? fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC
            : fs.OpenMode.READ_WRITE
          const dst = await fs.open(albumUri, dstMode)
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
            throw new Error(isOverwrite
              ? `相册写入中断（已写入 ${copiedSize}/${totalSize} 字节）：${copyError}；上一次导出的成片可能已被截断，建议重新导出`
              : `相册写入中断（已写入 ${copiedSize}/${totalSize} 字节）：${copyError}`)
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
   * 把这次导出写进「我的剪辑」历史。
   *
   * **吞掉一切异常**：记录没落盘，成片也已经在相册里了，此时把导出报成失败是撒谎。
   * 覆盖场景沿用被覆盖那条记录的 id —— id 不变，upsertRecord 才会替换而不是追加。
   * 若那条记录已被用户删掉，就退回新建一条：相册条目此时已被覆写，
   * 新记录指向同一个 albumUri，语义仍然正确。
   */
  private async persistRecord(
    record: ExportJobRecord,
    albumUri: string,
    fileName: string
  ): Promise<void> {
    try {
      const snapshot = record.snapshot
      const service = EditHistoryService.getInstance()
      let recordId = ''
      let coverPath = ''
      if (record.overwriteTargetUri.length > 0) {
        const existing = await service.list()
        for (let i = 0; i < existing.length; i++) {
          if (existing[i].albumUri === record.overwriteTargetUri) {
            recordId = existing[i].id
            // 刻意**不**继承旧记录的 coverPath：相册里那条视频已经被换了内容，
            // 旧的首帧缓存还停在上一版画面上。留空让列表重新取一次。
            break
          }
        }
      }
      if (recordId.length === 0) {
        recordId = makeRecordId(Date.now(), Math.random())
      }
      const item = new EditRecord()
      item.id = recordId
      item.tripId = snapshot.trip.tripId
      item.tripTitle = snapshot.trip.title
      item.tripStartTs = snapshot.trip.startTs
      item.tripEndTs = snapshot.trip.endTs
      item.albumUri = albumUri
      item.fileName = fileName
      item.exportedAt = Date.now()
      item.durationMs = Math.round(exportDurationSec(snapshot.playback.segments) * 1000)
      item.segmentCount = snapshot.playback.segments.length
      item.templateId = snapshot.selectedTemplateId
      item.snapshot = JSON.stringify(snapshot)
      item.coverPath = coverPath
      const saved = await service.upsert(item)
      if (saved) {
        debugLog('我的剪辑', `作品记录已保存 id=${recordId} 覆盖=${record.overwriteTargetUri.length > 0 ? 'YES' : 'NO'}`)
      } else {
        debugLog('我的剪辑', `作品记录仅留在内存（落盘失败） id=${recordId}`)
      }
    } catch (error) {
      debugLog('我的剪辑', `作品记录保存失败：${error instanceof Error ? error.message : String(error)}`)
    }
  }
}

export const sharedExportManager = new ExportManager()
