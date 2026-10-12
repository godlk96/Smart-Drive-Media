import { ExportComposeRequest } from '../model/TripModels'
import fs from '@ohos.file.fs'
import smartdriveExporter from 'libsmartdrive_exporter.so'

interface NativeExportPipelineRequest {
  frontUris: Array<string>
  backUris: Array<string>
  sideUris: Array<string>
  templateId: string
  expectedDurationSec: number
  startMs: number
  endMs: number
  outputPath: string
  hideSpeed: boolean
  hideVin: boolean
  hideTime: boolean
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

export async function extractFirstFrameByService(
  sourceUri: string,
  cacheDir: string,
  cacheKey: string
): Promise<string> {
  if (!sourceUri || sourceUri.length === 0) {
    return ''
  }
  const lower = sourceUri.toLowerCase()
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png') || lower.endsWith('.webp')) {
    return sourceUri
  }

  const sanitizedKey = cacheKey.replace(/[^a-zA-Z0-9_-]/g, '_')
  const targetImagePath = `${cacheDir}/thumb_${sanitizedKey}.jpg`

  try {
    if (fs.accessSync(targetImagePath)) {
      return targetImagePath
    }
  } catch (_) {
  }

  try {
    const file = await fs.open(targetImagePath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE)
    await fs.close(file.fd)
    return targetImagePath
  } catch (_) {
    return targetImagePath
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
    hideSpeed: request.hideSpeed,
    hideVin: request.hideVin,
    hideTime: request.hideGps
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
  let reportedProgress: number = 0
  const smoothUpperBound: number = 98
  let smoothTimer: number = -1
  const emitProgress = (target: number): void => {
    const normalized = Math.max(0, Math.min(100, Math.floor(target)))
    while (reportedProgress < normalized) {
      reportedProgress += 1
      onProgress(reportedProgress)
    }
  }
  const startSmoothProgress = (estimatedNativeMs: number, startedAt: number): void => {
    if (smoothTimer >= 0) {
      return
    }
    smoothTimer = setInterval(() => {
      if (reportedProgress >= smoothUpperBound) {
        return
      }
      const elapsed = Date.now() - startedAt
      const expected = Math.min(smoothUpperBound, Math.floor((elapsed * smoothUpperBound) / estimatedNativeMs))
      if (expected > reportedProgress) {
        reportedProgress += 1
        onProgress(reportedProgress)
      }
    }, 250)
  }
  const stopSmoothProgress = (): void => {
    if (smoothTimer >= 0) {
      clearInterval(smoothTimer)
      smoothTimer = -1
    }
  }
  if (isolatedRequest.frontUris.length === 0 || isolatedRequest.backUris.length === 0) {
    throw new Error('导出失败：前后路素材不足')
  }
  const estimatedNativeMs = Math.max(45000, isolatedRequest.expectedDurationSec * 700)
  const progressStart = Date.now()
  startSmoothProgress(estimatedNativeMs, progressStart)
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
  if (typeof runPipelineAsync !== 'function') {
    throw new Error('smartdrive_exporter.runExportPipelineAsync 未实现')
  }
  onLog('Native导出阶段 启动 export_engine 硬编/封装管线')
  const nativeStart = Date.now()
  let outputPath: string = ''
  try {
    const result = await runPipelineAsync(payload)
    const errorCode = Number(result?.code ?? -1)
    if (errorCode !== 0) {
      const message = String(result?.message ?? 'UNKNOWN')
      throw new Error(`导出失败[${errorCode}]：${message}`)
    }
    outputPath = String(result?.outputPath ?? '')
  } finally {
    stopSmoothProgress()
    await removeMaterializedTempUris(tempUris, onLog)
  }
  if (outputPath.length === 0) {
    throw new Error('导出失败：native 导出返回为空')
  }
  onLog(`Native导出阶段 Native处理耗时=${Date.now() - nativeStart}ms`)
  emitProgress(99)
  onLog(`Native导出阶段 完成 输出=${outputPath}`)
  return outputPath
}
