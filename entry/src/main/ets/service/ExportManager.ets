import common from '@ohos.app.ability.common'
import fs from '@ohos.file.fs'
import photoAccessHelper from '@ohos.file.photoAccessHelper'
import { CameraPosition, ExportSnapshot, toLegacyCamera } from '../model/Models'
import { DvrMeta } from '../model/TripModels'
import { buildComposeRequestByService } from './ExportService'
import { exportDurationSec } from '../model/SegmentModel'
import { executeComposeByService, cancelNativeExportPipeline } from './ExportNativeService'
import { debugLog } from '../utils/Logger'

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
    const normalizedProgress = Math.max(0, Math.min(100, Math.floor(progress)))
    record.progress = normalizedProgress
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

  async start(snapshot: ExportSnapshot, context: common.UIAbilityContext): Promise<ExportJobId> {
    const isolatedSnapshot = cloneExportSnapshot(snapshot)
    const jobId = `${isolatedSnapshot.sessionId}_${Date.now()}`
    const record: ExportJobRecord = {
      id: jobId,
      snapshot: isolatedSnapshot,
      listeners: [],
      cancelled: false,
      progress: 0
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
        (progress: number) => {
          if (!record.cancelled) {
            this.notify(record, `导出处理中 ${progress}%`, progress)
          }
        }
      )
      if (record.cancelled) {
        return
      }
      const saveStartProgress = Math.max(85, Math.min(99, record.progress))
      this.notify(record, `保存相册中 ${saveStartProgress}%`, saveStartProgress)
      const albumUri = await this.saveVideoToAlbum(fileName, sourceUri, context, saveStartProgress, (progress: number) => {
        if (!record.cancelled) {
          this.notify(record, `导出处理中 ${progress}%`, progress)
        }
      })
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
    onProgress: (percent: number) => void
  ): Promise<string> {
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
    try {
        const desFileUris = await helper.showAssetsCreationDialog(srcFileUris, photoCreationConfigs)
        const albumUri = desFileUris[0]
        if (!albumUri || albumUri.length === 0) {
          throw new Error('未选择相册保存位置')
        }
        debugLog('导出', `相册写入开始 source=${sourceUri} target=${albumUri}`)
        let srcFd: number = -1
        let dstFd: number = -1
        const chunkSize: number = 1024 * 1024
        let totalSize: number = 0
        let copiedSize: number = 0
        const baseProgress: number = Math.max(85, Math.min(99, startProgress))
        let reportedProgress: number = baseProgress
        let copyError: string = ''
        try {
          try {
            const stat = await fs.stat(sourceUri)
            totalSize = Number(stat.size ?? 0)
          } catch (_) {
            totalSize = 0
          }
          const src = await fs.open(sourceUri, fs.OpenMode.READ_ONLY)
          srcFd = src.fd
          const dst = await fs.open(albumUri, fs.OpenMode.READ_WRITE)
          dstFd = dst.fd
          while (true) {
            const buffer = new ArrayBuffer(chunkSize)
            let readLen = 0
            try {
              readLen = await fs.read(srcFd, buffer)
            } catch (e) {
              copyError = `读取失败: ${e instanceof Error ? e.message : String(e)}`
              break
            }
            if (readLen <= 0) {
              break
            }
            try {
              await fs.write(dstFd, buffer.slice(0, readLen))
            } catch (e) {
              copyError = `写入失败: ${e instanceof Error ? e.message : String(e)}`
              break
            }
            copiedSize += readLen
            if (totalSize > 0) {
              const progressSpan = Math.max(0, 99 - baseProgress)
              const targetProgress = baseProgress + Math.min(progressSpan, Math.floor((copiedSize * progressSpan) / totalSize))
              while (reportedProgress < targetProgress) {
                reportedProgress += 1
                onProgress(reportedProgress)
              }
            } else if (reportedProgress < 99) {
              reportedProgress += 1
              onProgress(reportedProgress)
            }
          }
          while (reportedProgress < 99) {
            reportedProgress += 1
            onProgress(reportedProgress)
          }
          if (copyError.length > 0) {
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
            } catch (_) {
            }
          }
        }
        return albumUri
      } catch (error) {
        throw new Error(`保存到相册失败: ${error instanceof Error ? error.message : String(error)}`)
      }
  }
}

export const sharedExportManager = new ExportManager()
