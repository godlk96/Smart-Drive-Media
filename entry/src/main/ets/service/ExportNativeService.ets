import { ExportComposeRequest, ExportSegment } from '../model/TripModels'
import fs from '@ohos.file.fs'
import image from '@ohos.multimedia.image'
import media from '@ohos.multimedia.media'
import smartdriveExporter from 'libsmartdrive_exporter.so'
import { debugLog } from '../utils/Logger'

const THUMB_WIDTH: number = 480
const THUMB_HEIGHT: number = 270
const THUMB_JPEG_QUALITY: number = 80
const THUMB_TIME_US: number = 0

interface NativeExportPipelineRequest {
  frontUris: Array<string>
  backUris: Array<string>
  sideUris: Array<string>
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

async function isUsableThumbnail(path: string): Promise<boolean> {
  try {
    const stat = await fs.stat(path)
    return Number(stat.size ?? 0) > 0
  } catch (_) {
    return false
  }
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

  const sanitizedKey = cacheKey.replace(/[^a-zA-Z0-9_-]/g, '_')
  const targetImagePath = `${cacheDir}/thumb_${sanitizedKey}.jpg`

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
  onLog: (message: string) => void
): Promise<MaterializedUriSet> {
  const outputDir = resolveParentDir(outputPath)
  const inputUris: Array<string> = []
  const tempUris: Array<string> = []
  for (let index = 0; index < uris.length; index++) {
    const uri = uris[index]
    if (uri.startsWith('/data/storage/')) {
      inputUris.push(uri)
      continue
    }
    const targetPath = `${outputDir}/${prefix}_${Date.now()}_${index}.mp4`
    await copyUriToLocal(uri, targetPath)
    onLog(`Native导出阶段 素材落地 ${prefix}[${index}] -> ${targetPath}`)
    inputUris.push(targetPath)
    tempUris.push(targetPath)
  }
  return { inputUris, tempUris }
}

function buildNativeExportPayload(
  request: ExportComposeRequest,
  frontInputUris: Array<string>,
  backInputUris: Array<string>,
  sideInputUris: Array<string>
): NativeExportPipelineRequest {
  const payload: NativeExportPipelineRequest = {
    frontUris: frontInputUris,
    backUris: backInputUris,
    sideUris: sideInputUris,
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

  // 阶段 1: 素材准备与切片物化 (10%)
  onProgress(10)
  const materializeStart = Date.now()
  const materialized = await Promise.all([
    materializeInputUris(isolatedRequest.frontUris, isolatedRequest.outputPath, 'front', onLog),
    materializeInputUris(isolatedRequest.backUris, isolatedRequest.outputPath, 'back', onLog),
    materializeInputUris(isolatedRequest.sideUris, isolatedRequest.outputPath, 'side', onLog)
  ])
  const frontInputUris = materialized[0]?.inputUris ?? []
  const backInputUris = materialized[1]?.inputUris ?? []
  const sideInputUris = materialized[2]?.inputUris ?? []
  const tempUris = [
    ...(materialized[0]?.tempUris ?? []),
    ...(materialized[1]?.tempUris ?? []),
    ...(materialized[2]?.tempUris ?? [])
  ]
  onLog(`Native导出阶段 素材落地耗时=${Date.now() - materializeStart}ms`)
  const payload = buildNativeExportPayload(isolatedRequest, frontInputUris, backInputUris, sideInputUris)
  onLog(`Native导出阶段 输入统计 Front=${isolatedRequest.frontUris.length} Back=${isolatedRequest.backUris.length} 输出=${isolatedRequest.outputPath}`)
  let segmentText = ''
  for (let index = 0; index < payload.segments.length; index++) {
    const item = payload.segments[index]
    segmentText += `[${item.startMs},${item.endMs}]@${item.speedLabel}${item.muted ? '/mute' : ''} `
  }
  onLog(`Native导出阶段 请求负载 template=${payload.templateId} expectedDurationSec=${payload.expectedDurationSec} startMs=${payload.startMs} endMs=${payload.endMs} segments=${payload.segments.length} ${segmentText}`)
  if (typeof runPipelineAsync !== 'function') {
    throw new Error('smartdrive_exporter.runExportPipelineAsync 未实现')
  }

  // 阶段 2: 启动 Native 渲染合成 (35%)
  onProgress(35)
  onLog('Native导出阶段 启动 export_engine 渲染合成管线')
  const nativeStart = Date.now()
  let outputPath: string = ''
  try {
    const result = await runPipelineAsync(payload)
    const errorCode = Number(result?.code ?? -1)
    const resultMessage = String(result?.message ?? '')
    onLog(`Native导出阶段 返回 code=${errorCode} message=${resultMessage}`)
    if (errorCode !== 0) {
      throw new Error(`导出失败[${errorCode}]：${resultMessage.length > 0 ? resultMessage : 'UNKNOWN'}`)
    }
    outputPath = String(result?.outputPath ?? '')
  } finally {
    await removeMaterializedTempUris(tempUris, onLog)
  }
  if (outputPath.length === 0) {
    throw new Error('导出失败：native 导出返回为空')
  }
  onLog(`Native导出阶段 Native处理耗时=${Date.now() - nativeStart}ms`)

  // 阶段 3: Native 合成完成，进入相册写入 (85%)
  onProgress(85)
  onLog(`Native导出阶段 完成 输出=${outputPath}`)
  return outputPath
}
