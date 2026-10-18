import { ExportComposeRequest, ExportSegment } from '../model/TripModels'
import fs from '@ohos.file.fs'
import image from '@ohos.multimedia.image'
import media from '@ohos.multimedia.media'
import smartdriveExporter from 'libsmartdrive_exporter.so'
import { debugLog } from '../utils/Logger'
import { copyExportFileData } from './ExportFileCopy'
import { ExportProgressUpdate, NativeExportWork, exportPercent, nativeExportProgress } from '../model/ExportProgress'

// 封面要铺满 356vp 宽的卡片（3x 屏 ≈ 1068px），480×270 被放大 2.2 倍，卡面文字全糊。
// 直接按行车记录仪的原生档位取帧。
const THUMB_WIDTH: number = 1920
const THUMB_HEIGHT: number = 1080
const THUMB_JPEG_QUALITY: number = 92
const THUMB_TIME_US: number = 0
// 缓存版本号：取帧尺寸/质量一变就必须递增。isUsableThumbnail 只检查文件 size > 0，
// 不校验分辨率，否则上一版 480×270 的旧文件会被当有效缓存复用，改了参数也不生效。
// v3：首帧改为按源画面比例取帧（v2 一律压成 16:9，T3/T4 的 32:9 成片被横向拉扁）。
const THUMB_CACHE_VERSION: string = 'v3'

/**
 * 首帧缓存文件名里必须带的版本标记。
 *
 * 记录里存着 `coverPath`，光递增版本号没用 —— 老路径指向的文件还在，
 * `isCoverUsable` 会判"能用"，拉伸的旧封面永远换不掉。调用方拿这个标记
 * 过一遍，旧版本的路径一律当失效处理。
 */
export const THUMB_CACHE_TAG: string = `thumb_${THUMB_CACHE_VERSION}_`

/**
 * 按源画面比例算取帧高度，保证不被拉伸。
 *
 * `fetchFrameByTime` 的 `PixelMapParams` 是**非等比缩放**：给多少宽高就硬压成多少，
 * 3840×1080（T3 左右分屏 / T4 三分屏）塞进 1920×1080 会被横向压扁三分之一。
 * 所以高度要跟着源比例走，让卡片那边用 `ImageFit.Cover` 去裁，而不是在这里压。
 *
 * @param sourceAspectRatio 源宽/源高；<=0 或不合法时退回 16:9
 */
function resolveFrameHeight(sourceAspectRatio: number): number {
  if (!(sourceAspectRatio > 0) || !isFinite(sourceAspectRatio)) {
    return THUMB_HEIGHT
  }
  const natural: number = Math.round(THUMB_WIDTH / sourceAspectRatio)
  if (natural < 1) {
    return 1
  }
  // 极端竖片（T1 是 8:9，正常）兜个上限，避免算出天量像素把解码器打爆。
  if (natural > THUMB_WIDTH * 2) {
    return THUMB_WIDTH * 2
  }
  return natural
}

interface NativeExportPipelineRequest {
  frontUris: Array<string>
  backUris: Array<string>
  sideUris: Array<string>
  /** T6 四机位专用第 4 路（右下 / 右后）；其余模板为空数组。 */
  side2Uris: Array<string>
  templateId: string
  expectedDurationSec: number
  startMs: number
  endMs: number
  outputPath: string
  segments: Array<ExportSegment>
}

interface MaterializedUriSet {
  inputUris: Array<string>
}

class NativeExportPipelineResult {
  code: number = 0
  message: string = ''
  outputPath: string = ''
}

function deepCloneJson<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T
}

function cloneRequestForExportIsolation(request: ExportComposeRequest): ExportComposeRequest {
  return deepCloneJson(request) as ExportComposeRequest
}

function isImagePath(uri: string): boolean {
  const lower = uri.toLowerCase()
  return lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png') || lower.endsWith('.webp')
}

export async function isUsableThumbnail(path: string): Promise<boolean> {
  try {
    const stat = await fs.stat(path)
    return Number(stat.size ?? 0) > 0
  } catch (_) {
    return false
  }
}

export function resolveThumbnailCachePath(cacheDir: string, cacheKey: string): string {
  const sanitizedKey = cacheKey.replace(/[^a-zA-Z0-9_-]/g, '_')
  return `${cacheDir}/thumb_${THUMB_CACHE_VERSION}_${sanitizedKey}.jpg`
}

async function writeArrayBufferToFile(targetPath: string, buffer: ArrayBuffer): Promise<void> {
  let fd: number = -1
  try {
    const file = await fs.open(targetPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC)
    fd = file.fd
    await fs.write(fd, buffer)
  } catch (err) {
    debugLog('ExportNative', `writeArrayBufferToFile failed: ${String(err)}`)
    throw new Error(String(err))
  } finally {
    if (fd >= 0) {
      try {
        await fs.close(fd)
      } catch (_) {
      }
    }
  }
}

/**
 * 提取视频首帧并落盘为 JPEG 缩略图。
 * 成功返回缩略图路径；任何失败均返回空字符串，由调用方回退到占位图（绝不返回视频 URI）。
 */
// @SuppressWarnings syscap
export async function extractFirstFrameByService(
  sourceUri: string,
  cacheDir: string,
  cacheKey: string,
  sourceAspectRatio: number = 0
): Promise<string> {
  if (!sourceUri || sourceUri.length === 0 || cacheDir.length === 0) {
    return ''
  }
  if (isImagePath(sourceUri)) {
    return sourceUri
  }

  const targetImagePath = resolveThumbnailCachePath(cacheDir, cacheKey)

  if (await isUsableThumbnail(targetImagePath)) {
    return targetImagePath
  }

  let generator: media.AVImageGenerator | undefined = undefined
  let sourceFd: number = -1
  let pixelMap: image.PixelMap | undefined = undefined
  let packer: image.ImagePacker | undefined = undefined
  try {
    const sourceFile = await fs.open(sourceUri, fs.OpenMode.READ_ONLY)
    sourceFd = sourceFile.fd

    if (!canIUse('SystemCapability.Multimedia.Media.AVImageGenerator')) {
      return ''
    }
    // @SuppressWarnings syscap
    const created = await media.createAVImageGenerator()
    if (!created) {
      return ''
    }
    generator = created

    const descriptor: media.AVFileDescriptor = { fd: sourceFd }
    generator.fdSrc = descriptor

    const params: media.PixelMapParams = { width: THUMB_WIDTH, height: resolveFrameHeight(sourceAspectRatio) }
    pixelMap = await generator.fetchFrameByTime(
      THUMB_TIME_US,
      2 as media.AVImageQueryOptions,
      params
    )
    if (!pixelMap) {
      return ''
    }

    packer = image.createImagePacker()
    const option: image.PackingOption = { format: 'image/jpeg', quality: THUMB_JPEG_QUALITY }
    const packed: ArrayBuffer = await packer.packToData(pixelMap, option)
    if (!packed || packed.byteLength === 0) {
      return ''
    }
    await writeArrayBufferToFile(targetImagePath, packed)

    if (!(await isUsableThumbnail(targetImagePath))) {
      return ''
    }
    debugLog('封面', `首帧提取成功，封面=${targetImagePath}`)
    return targetImagePath
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    debugLog('封面', `首帧提取失败，回退占位图，原因=${message}`)
    return ''
  } finally {
    if (packer) {
      try {
        await packer.release()
      } catch (_) {
      }
    }
    if (pixelMap) {
      try {
        await pixelMap.release()
      } catch (_) {
      }
    }
    if (generator) {
      try {
        await generator.release()
      } catch (_) {
      }
    }
    if (sourceFd >= 0) {
      try {
        await fs.close(sourceFd)
      } catch (_) {
      }
    }
  }
}

function resolveParentDir(path: string): string {
  const index = path.lastIndexOf('/')
  if (index <= 0) {
    return '/data/storage/el2/base/files'
  }
  return path.slice(0, index)
}

async function copyUriToLocal(
  sourceUri: string,
  targetPath: string,
  totalBytes: number,
  onProgress: (copied: number, total: number) => void,
  isCancelled: () => boolean
): Promise<void> {
  let srcFd: number = -1
  let dstFd: number = -1
  try {
    if (isCancelled()) {
      throw new Error('已取消导出')
    }
    const src = await fs.open(sourceUri, fs.OpenMode.READ_ONLY)
    srcFd = src.fd
    const dst = await fs.open(targetPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC)
    dstFd = dst.fd
    await copyExportFileData(srcFd, dstFd, totalBytes, onProgress, isCancelled)
  } catch (error) {
    const reason = String(error ?? 'unknown')
    throw new Error(`素材落地失败：${reason}`)
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
}

async function materializeInputUris(
  uris: Array<string>,
  materialize: (uri: string) => Promise<string>
): Promise<MaterializedUriSet> {
  const inputUris: Array<string> = []
  for (let index = 0; index < uris.length; index++) {
    inputUris.push(await materialize(uris[index]))
  }
  return { inputUris }
}

function buildNativeExportPayload(
  request: ExportComposeRequest,
  frontInputUris: Array<string>,
  backInputUris: Array<string>,
  sideInputUris: Array<string>,
  side2InputUris: Array<string>
): NativeExportPipelineRequest {
  const payload: NativeExportPipelineRequest = {
    frontUris: frontInputUris,
    backUris: backInputUris,
    sideUris: sideInputUris,
    side2Uris: side2InputUris,
    templateId: request.templateId,
    expectedDurationSec: request.expectedDurationSec,
    startMs: request.rangeStartMs,
    endMs: request.rangeEndMs,
    outputPath: request.outputPath,
    segments: request.segments
  }
  return deepCloneJson(payload)
}

async function removeMaterializedTempUris(uris: Array<string>, onLog: (message: string) => void): Promise<void> {
  for (const uri of uris) {
    try {
      await fs.unlink(uri)
      onLog(`Native导出阶段 清理临时素材 ${uri}`)
    } catch (_) {
    }
  }
}

export async function executeComposeByService(
  request: ExportComposeRequest,
  onLog: (message: string) => void,
  onProgress: (update: ExportProgressUpdate) => void,
  isCancelled: () => boolean = (): boolean => false
): Promise<string> {
  const isolatedRequest = cloneRequestForExportIsolation(request)
  const runPipelineAsync = (smartdriveExporter as Record<string, Object | Function> | undefined)?.runExportPipelineAsync as ((payload: NativeExportPipelineRequest) => Promise<NativeExportPipelineResult>) | undefined

  if (isolatedRequest.frontUris.length === 0 || isolatedRequest.backUris.length === 0) {
    throw new Error('导出失败：前后路素材不足')
  }
  if (isolatedRequest.templateId === 'T6' && isolatedRequest.side2Uris.length === 0) {
    throw new Error('导出失败：四机位模板需要右后（Right）素材')
  }
  if (typeof runPipelineAsync !== 'function') {
    throw new Error('smartdrive_exporter.runExportPipelineAsync 未实现')
  }

  onProgress({ percent: 5, stage: 'preparing', detail: '正在准备视频素材' })
  const materializeStart = Date.now()
  const allUris: Array<string> = [...isolatedRequest.frontUris, ...isolatedRequest.backUris,
    ...isolatedRequest.sideUris, ...isolatedRequest.side2Uris]
  const sizes: Map<string, number> = new Map()
  allUris.forEach((uri: string) => sizes.set(uri, 0))
  const uniqueUris: Array<string> = []
  sizes.forEach((_, uri: string) => uniqueUris.push(uri))
  let totalBytes = 0
  let allSizesKnown = true
  await Promise.all(uniqueUris.map(async (uri: string) => {
    try {
      const stat = await fs.stat(uri)
      const size = Math.max(0, Number(stat.size))
      sizes.set(uri, size)
      totalBytes += size
      if (size <= 0) {
        allSizesKnown = false
      }
    } catch (_) {
      allSizesKnown = false
    }
  }))
  const copiedByUri: Map<string, number> = new Map()
  const completedUris: Set<string> = new Set()
  const pending: Map<string, Promise<string>> = new Map()
  const tempUris: Array<string> = []
  let lastCopyReportAt = 0
  let materializationFailed = false
  let materializationError = ''
  const stopped = (): boolean => isCancelled() || materializationFailed
  const reportCopy = (force: boolean): void => {
    if (!force && Date.now() - lastCopyReportAt < 120) {
      return
    }
    let copied = 0
    let completedFraction = 0
    copiedByUri.forEach((bytes: number, uri: string) => {
      copied += bytes
      const size = sizes.get(uri) ?? 0
      completedFraction += size > 0 ? Math.min(1, bytes / size) : (completedUris.has(uri) ? 1 : 0)
    })
    const fraction = allSizesKnown && totalBytes > 0 ? copied / totalBytes : completedFraction / Math.max(1, uniqueUris.length)
    lastCopyReportAt = Date.now()
    onProgress({ percent: exportPercent(5 + Math.min(1, fraction) * 15), stage: 'preparing',
      detail: allSizesKnown ? `${completedUris.size} / ${uniqueUris.length} 个素材 · ${(copied / 1048576).toFixed(1)} / ${(totalBytes / 1048576).toFixed(1)} MB` :
        `已准备 ${completedUris.size} / ${uniqueUris.length} 个素材` })
  }
  const materialize = (uri: string): Promise<string> => {
    const existing = pending.get(uri)
    if (existing) {
      return existing
    }
    const promise = (async (): Promise<string> => {
      if (stopped()) {
        throw new Error('已取消导出')
      }
      let inputPath = uri
      if (!uri.startsWith('/data/storage/')) {
        inputPath = `${resolveParentDir(isolatedRequest.outputPath)}/input_${Date.now()}_${tempUris.length}.mp4`
        tempUris.push(inputPath)
        await copyUriToLocal(uri, inputPath, sizes.get(uri) ?? 0, (bytes: number) => {
          copiedByUri.set(uri, bytes)
          if (bytes > 0) {
            reportCopy(false)
          }
        }, stopped)
        onLog(`Native导出阶段 素材落地 ${uri} -> ${inputPath}`)
      }
      completedUris.add(uri)
      copiedByUri.set(uri, sizes.get(uri) ?? 0)
      reportCopy(true)
      return inputPath
    })()
    pending.set(uri, promise)
    return promise
  }
  let progressTimer = -1
  try {
    const prepareTrack = async (uris: Array<string>): Promise<MaterializedUriSet> => {
      try {
        return await materializeInputUris(uris, materialize)
      } catch (error) {
        if (!materializationFailed) {
          materializationError = error instanceof Error ? error.message : String(error)
        }
        materializationFailed = true
        throw new Error(error instanceof Error ? error.message : String(error))
      }
    }
    // 等待各路都退出后再清理，避免 Promise.all 提前失败后仍有复制写入临时文件。
    const results = await Promise.allSettled([
      prepareTrack(isolatedRequest.frontUris), prepareTrack(isolatedRequest.backUris),
      prepareTrack(isolatedRequest.sideUris), prepareTrack(isolatedRequest.side2Uris)
    ])
    const materialized: Array<MaterializedUriSet> = []
    let prepareError: Error | undefined = undefined
    for (const result of results) {
      if (result.status === 'fulfilled') {
        materialized.push(result.value)
      } else if (!prepareError) {
        const reason = result.reason as Object
        prepareError = new Error(reason instanceof Error ? reason.message : String(reason))
      }
    }
    if (prepareError) {
      throw new Error(materializationError.length > 0 ? materializationError : prepareError.message)
    }
    if (isCancelled()) {
      throw new Error('已取消导出')
    }
    const frontInputUris = materialized[0].inputUris
    const backInputUris = materialized[1].inputUris
    const sideInputUris = materialized[2].inputUris
    const side2InputUris = materialized[3].inputUris
    onLog(`Native导出阶段 素材落地耗时=${Date.now() - materializeStart}ms`)
    const payload = buildNativeExportPayload(isolatedRequest, frontInputUris, backInputUris, sideInputUris, side2InputUris)
    onLog(`【Native入参-落地文件】Front=[${frontInputUris.join(', ')}]`)
    onLog(`【Native入参-落地文件】Back=[${backInputUris.join(', ')}]`)
    onLog(`【Native入参-落地文件】Side=[${sideInputUris.join(', ')}]`)
    onLog(`【Native入参-落地文件】Side2=[${side2InputUris.join(', ')}]`)
    onLog(`【Native入参-输出路径】outputPath=${payload.outputPath}`)
    let segmentText = ''
    for (let index = 0; index < payload.segments.length; index++) {
      const item = payload.segments[index]
      segmentText += `[#${index} ${item.startMs}ms~${item.endMs}ms (${item.startMs/1000}s~${item.endMs/1000}s) @${item.speedLabel} ${item.muted ? 'MUTED' : 'UNMUTED'}] `
    }
    onLog(`【Native入参-模板与片段】template=${payload.templateId} expectedDurationSec=${payload.expectedDurationSec} segments(${payload.segments.length})=${segmentText}`)
    onProgress({ percent: 20, stage: 'checking', detail: '正在检查视频素材' })
    onLog('Native导出阶段 启动 export_engine 渲染合成管线')
    const nativeStart = Date.now()
    let outputPath: string = ''
    let lastReportedProgress = 20
    let lastStage = ''
    progressTimer = setInterval(() => {
      try {
        if (isCancelled()) {
          cancelNativeExportPipeline()
          return
        }
        const getProgressFn = (smartdriveExporter as Record<string, Object | Function> | undefined)?.getExportProgress as (() => NativeExportWork) | undefined
        if (typeof getProgressFn === 'function') {
          const prog = getProgressFn()
          if (prog.stage <= 0 || prog.percent < 0) {
            return
          }
          const update = nativeExportProgress(prog)
          if (update.percent >= lastReportedProgress && (update.percent > lastReportedProgress || update.stage !== lastStage)) {
            lastReportedProgress = update.percent
            lastStage = update.stage
            onProgress(update)
          }
        }
      } catch (_) {
      }
    }, 120)

    const result = await runPipelineAsync(payload)
    const errorCode = Number(result?.code ?? -1)
    const resultMessage = String(result?.message ?? '')
    if (errorCode !== 0) {
      if (errorCode === 1009 || resultMessage.indexOf('cancel') >= 0) {
        throw new Error('导出已取消')
      }
      throw new Error(`导出失败[${errorCode}]：${resultMessage.length > 0 ? resultMessage : 'UNKNOWN'}`)
    }
    outputPath = String(result?.outputPath ?? '')
    if (outputPath.length === 0) {
      throw new Error('导出失败：native 导出返回为空')
    }
    onLog(`Native导出阶段 Native处理耗时=${Date.now() - nativeStart}ms`)

    // 阶段 3: Native 合成完成，进入相册写入 (85% ~ 100%)
    onProgress({ percent: 85, stage: 'finalizing', detail: '视频已生成，正在准备保存' })
    onLog(`Native导出阶段 完成 输出=${outputPath}`)
    return outputPath
  } finally {
    if (progressTimer >= 0) {
      clearInterval(progressTimer)
    }
    await removeMaterializedTempUris(tempUris, onLog)
  }
}

export function cancelNativeExportPipeline(): void {
  try {
    const cancelFn = (smartdriveExporter as Record<string, Object | Function> | undefined)?.cancelExport as (() => boolean) | undefined
    if (typeof cancelFn === 'function') {
      cancelFn()
      debugLog('ExportNative', '已触发底层 smartdriveExporter.cancelExport()')
    }
  } catch (error) {
    debugLog('ExportNative', `cancelNativeExportPipeline 异常: ${String(error)}`)
  }
}
