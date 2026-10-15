import { ExportComposeRequest, ExportSegment } from '../model/TripModels'
import fs from '@ohos.file.fs'
import image from '@ohos.multimedia.image'
import media from '@ohos.multimedia.media'
import smartdriveExporter from 'libsmartdrive_exporter.so'
import { debugLog } from '../utils/Logger'

// 封面要铺满 356vp 宽的卡片（3x 屏 ≈ 1068px），480×270 被放大 2.2 倍，卡面文字全糊。
// 直接按行车记录仪的原生档位取帧。
const THUMB_WIDTH: number = 1920
const THUMB_HEIGHT: number = 1080
const THUMB_JPEG_QUALITY: number = 92
const THUMB_TIME_US: number = 0
// 缓存版本号：取帧尺寸/质量一变就必须递增。isUsableThumbnail 只检查文件 size > 0，
// 不校验分辨率，否则上一版 480×270 的旧文件会被当有效缓存复用，改了参数也不生效。
const THUMB_CACHE_VERSION: string = 'v2'

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
  tempUris: Array<string>
}

class NativeExportPipelineResult {
  code: number = 0
  message: string = ''
  outputPath: string = ''
}

interface NativeExportProgressResponse {
  percent: number
  currentFrame: number
  totalFrames: number
  stage: number
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
  cacheKey: string
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

    const params: media.PixelMapParams = { width: THUMB_WIDTH, height: THUMB_HEIGHT }
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

async function copyUriToLocal(sourceUri: string, targetPath: string): Promise<void> {
  let srcFd: number = -1
  let dstFd: number = -1
  const chunkSize: number = 1024 * 1024
  try {
    const src = await fs.open(sourceUri, fs.OpenMode.READ_ONLY)
    srcFd = src.fd
    const dst = await fs.open(targetPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE)
    dstFd = dst.fd
    while (true) {
      const buffer = new ArrayBuffer(chunkSize)
      const readLen = await fs.read(srcFd, buffer)
      if (readLen <= 0) {
        break
      }
      await fs.write(dstFd, buffer.slice(0, readLen))
    }
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
  outputPath: string,
  prefix: string,
  onLog: (message: string) => void,
  onFileCopied?: () => void
): Promise<MaterializedUriSet> {
  const outputDir = resolveParentDir(outputPath)
  const inputUris: Array<string> = []
  const tempUris: Array<string> = []
  for (let index = 0; index < uris.length; index++) {
    const uri = uris[index]
    if (uri.startsWith('/data/storage/')) {
      inputUris.push(uri)
      if (onFileCopied) {
        onFileCopied()
      }
      continue
    }
    const targetPath = `${outputDir}/${prefix}_${Date.now()}_${index}.mp4`
    await copyUriToLocal(uri, targetPath)
    onLog(`Native导出阶段 素材落地 ${prefix}[${index}] -> ${targetPath}`)
    inputUris.push(targetPath)
    tempUris.push(targetPath)
    if (onFileCopied) {
      onFileCopied()
    }
  }
  return { inputUris, tempUris }
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
  onProgress: (percent: number) => void
): Promise<string> {
  const isolatedRequest = cloneRequestForExportIsolation(request)
  const runPipelineAsync = (smartdriveExporter as Record<string, Object | Function> | undefined)?.runExportPipelineAsync as ((payload: NativeExportPipelineRequest) => Promise<NativeExportPipelineResult>) | undefined

  if (isolatedRequest.frontUris.length === 0 || isolatedRequest.backUris.length === 0) {
    throw new Error('导出失败：前后路素材不足')
  }

  // 阶段 1: 素材准备与切片物化 (5% ~ 20%)
  onProgress(5)
  const materializeStart = Date.now()
  const totalClips = Math.max(1, isolatedRequest.frontUris.length + isolatedRequest.backUris.length +
    isolatedRequest.sideUris.length + isolatedRequest.side2Uris.length)
  let copiedClipsCount = 0
  const onFileCopied = () => {
    copiedClipsCount++
    const p = Math.min(20, Math.floor(5 + (copiedClipsCount / totalClips) * 15))
    onProgress(p)
  }
  const materialized = await Promise.all([
    materializeInputUris(isolatedRequest.frontUris, isolatedRequest.outputPath, 'front', onLog, onFileCopied),
    materializeInputUris(isolatedRequest.backUris, isolatedRequest.outputPath, 'back', onLog, onFileCopied),
    materializeInputUris(isolatedRequest.sideUris, isolatedRequest.outputPath, 'side', onLog, onFileCopied),
    materializeInputUris(isolatedRequest.side2Uris, isolatedRequest.outputPath, 'side2', onLog, onFileCopied)
  ])
  const frontInputUris = materialized[0]?.inputUris ?? []
  const backInputUris = materialized[1]?.inputUris ?? []
  const sideInputUris = materialized[2]?.inputUris ?? []
  const side2InputUris = materialized[3]?.inputUris ?? []
  const tempUris = [
    ...(materialized[0]?.tempUris ?? []),
    ...(materialized[1]?.tempUris ?? []),
    ...(materialized[2]?.tempUris ?? []),
    ...(materialized[3]?.tempUris ?? [])
  ]
  onLog(`Native导出阶段 素材落地耗时=${Date.now() - materializeStart}ms`)
  // T6 需要 4 路素材；缺第 4 路时提前给出中文原因，而不是让原生返回一个裸错误码。
  if (isolatedRequest.templateId === 'T6' && side2InputUris.length === 0) {
    throw new Error('导出失败：四机位模板需要右后（Right）素材')
  }
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
  if (typeof runPipelineAsync !== 'function') {
    throw new Error('smartdrive_exporter.runExportPipelineAsync 未实现')
  }

  // 阶段 2: 启动 Native 渲染合成 (20% ~ 85%)，启动高频定时轮询 Native 进度，保证 UI 细腻跳动不卡顿
  onProgress(20)
  onLog('Native导出阶段 启动 export_engine 渲染合成管线')
  const nativeStart = Date.now()
  let outputPath: string = ''
  let lastReportedProgress = 20
  const progressTimer = setInterval(() => {
    try {
      const getProgressFn = (smartdriveExporter as Record<string, Object | Function> | undefined)?.getExportProgress as (() => NativeExportProgressResponse) | undefined
      if (typeof getProgressFn === 'function') {
        const prog = getProgressFn()
        const pct = Number(prog?.percent ?? 0)
        if (pct > lastReportedProgress && pct <= 85) {
          lastReportedProgress = pct
          onProgress(pct)
        }
      }
    } catch (_) {
    }
  }, 120)

  try {
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
  } finally {
    clearInterval(progressTimer)
    await removeMaterializedTempUris(tempUris, onLog)
  }
  if (outputPath.length === 0) {
    throw new Error('导出失败：native 导出返回为空')
  }
  onLog(`Native导出阶段 Native处理耗时=${Date.now() - nativeStart}ms`)

  // 阶段 3: Native 合成完成，进入相册写入 (85% ~ 100%)
  onProgress(85)
  onLog(`Native导出阶段 完成 输出=${outputPath}`)
  return outputPath
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
