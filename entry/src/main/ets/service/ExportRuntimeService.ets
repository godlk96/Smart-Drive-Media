import fs from '@ohos.file.fs'
import { FFAbortController, FFmpeg } from '@sj/ffmpeg'
import { ExportComposeRequest } from '../model/TripModels'

function toFfmpegPath(uri: string): string {
  return uri.startsWith('file://') ? uri.slice(7) : uri
}

async function resolveInputForFfmpeg(uri: string): Promise<string> {
  const candidates: Array<string> = [toFfmpegPath(uri), uri]
  for (const candidate of candidates) {
    if (!candidate || candidate.length === 0) {
      continue
    }
    try {
      await fs.stat(candidate)
      return candidate
    } catch (_) {
    }
  }
  throw new Error(`输入文件不可读：${uri}`)
}

async function copyForFfmpeg(sourcePath: string, index: number, cacheDir: string): Promise<string> {
  const targetPath = `${cacheDir}/ffmpeg_input_${Date.now()}_${index}.mp4`
  let srcFd: number = -1
  let dstFd: number = -1
  const chunkSize: number = 1024 * 1024
  try {
    const src = await fs.open(sourcePath, fs.OpenMode.READ_ONLY)
    srcFd = src.fd
    const dst = await fs.open(targetPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE)
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
    const message = error instanceof Error ? error.message : String(error)
    throw new Error(`准备FFmpeg输入失败：${message}`)
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
  return targetPath
}

async function probeVideoBitrate(inputPath: string): Promise<number> {
  let output = ''
  try {
    await FFmpeg.execute([
      '-v', 'error',
      '-select_streams', 'v:0',
      '-show_entries', 'stream=bit_rate',
      '-of', 'default=noprint_wrappers=1',
      inputPath
    ], {
      outputCallback: (msg: string) => {
        output += msg
      }
    })
    const match = output.match(/bit_rate=(\d+)/)
    if (!match) {
      return 0
    }
    return Number(match[1] ?? '0')
  } catch (_) {
    return 0
  }
}

function parseSpeedValue(speedLabel: string): number {
  const speed = Number.parseFloat(String(speedLabel ?? '1.0X').replace(/x$/i, ''))
  if (!Number.isFinite(speed) || speed <= 0) {
    return 1
  }
  return speed
}

function buildAtempoChain(speed: number): string {
  const nodes: Array<string> = []
  let rest = speed
  while (rest > 2) {
    nodes.push('atempo=2')
    rest = rest / 2
  }
  while (rest < 0.5) {
    nodes.push('atempo=0.5')
    rest = rest / 0.5
  }
  if (Math.abs(rest - 1) > 0.001) {
    nodes.push(`atempo=${rest.toFixed(3)}`)
  }
  if (nodes.length === 0) {
    return 'anull'
  }
  return nodes.join(',')
}

function buildTemplateLayoutNodes(templateId: string, hasBack: boolean, hasSide: boolean): Array<string> {
  const normalizedId = templateId === 'T1' || templateId === 'T2' || templateId === 'T3' || templateId === 'T4'
    ? templateId
    : 'T2'
  if (normalizedId === 'T1') {
    if (!hasBack) {
      return ['[front_v]scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black[layout_v]']
    }
    return [
      '[front_v]scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black[base_v]',
      '[back_v]scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:(ow-iw)/2:(oh-ih)/2:black[pip_v]',
      '[base_v][pip_v]overlay=x=W-w-48:y=48[layout_v]'
    ]
  }
  if (normalizedId === 'T2') {
    if (!hasBack && !hasSide) {
      return ['[front_v]scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black[layout_v]']
    }
    if (!hasBack) {
      return [
        '[front_v]scale=1920:540:force_original_aspect_ratio=decrease,pad=1920:540:(ow-iw)/2:(oh-ih)/2:black[top_v]',
        '[side_v]scale=960:540:force_original_aspect_ratio=decrease,pad=960:540:(ow-iw)/2:(oh-ih)/2:black[bottom_left_v]',
        '[front_v]scale=960:540:force_original_aspect_ratio=decrease,pad=960:540:(ow-iw)/2:(oh-ih)/2:black[bottom_right_v]',
        '[bottom_left_v][bottom_right_v]hstack=inputs=2[bottom_v]',
        '[top_v][bottom_v]vstack=inputs=2[layout_v]'
      ]
    }
    const leftRef = hasSide ? '[side_v]' : '[front_v]'
    return [
      '[front_v]scale=1920:540:force_original_aspect_ratio=decrease,pad=1920:540:(ow-iw)/2:(oh-ih)/2:black[top_v]',
      `${leftRef}scale=960:540:force_original_aspect_ratio=decrease,pad=960:540:(ow-iw)/2:(oh-ih)/2:black[bottom_left_v]`,
      '[back_v]scale=960:540:force_original_aspect_ratio=decrease,pad=960:540:(ow-iw)/2:(oh-ih)/2:black[bottom_right_v]',
      '[bottom_left_v][bottom_right_v]hstack=inputs=2[bottom_v]',
      '[top_v][bottom_v]vstack=inputs=2[layout_v]'
    ]
  }
  if (normalizedId === 'T3') {
    if (!hasBack) {
      return ['[front_v]scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black[layout_v]']
    }
    return [
      '[front_v]scale=960:1080:force_original_aspect_ratio=decrease,pad=960:1080:(ow-iw)/2:(oh-ih)/2:black[left_v]',
      '[back_v]scale=960:1080:force_original_aspect_ratio=decrease,pad=960:1080:(ow-iw)/2:(oh-ih)/2:black[right_v]',
      '[left_v][right_v]hstack=inputs=2[layout_v]'
    ]
  }
  if (normalizedId === 'T4') {
    if (!hasBack && !hasSide) {
      return [
        'color=c=black:s=1080x1920[canvas_v]',
        '[front_v]scale=1080:1920:force_original_aspect_ratio=decrease,pad=1080:1920:(ow-iw)/2:(oh-ih)/2:black[single_v]',
        '[canvas_v][single_v]overlay=0:0[layout_v]'
      ]
    }
    if (!hasBack) {
      return [
        'color=c=black:s=1080x1920[canvas_v]',
        '[side_v]scale=1080:640:force_original_aspect_ratio=decrease,pad=1080:640:(ow-iw)/2:(oh-ih)/2:black[top_v]',
        '[front_v]scale=1080:640:force_original_aspect_ratio=decrease,pad=1080:640:(ow-iw)/2:(oh-ih)/2:black[middle_v]',
        '[front_v]scale=1080:640:force_original_aspect_ratio=decrease,pad=1080:640:(ow-iw)/2:(oh-ih)/2:black[bottom_v]',
        '[canvas_v][top_v]overlay=0:0[layer1_v]',
        '[layer1_v][middle_v]overlay=0:640[layer2_v]',
        '[layer2_v][bottom_v]overlay=0:1280[layout_v]'
      ]
    }
    const topRef = hasSide ? '[side_v]' : '[front_v]'
    return [
      'color=c=black:s=1080x1920[canvas_v]',
      `${topRef}scale=1080:640:force_original_aspect_ratio=decrease,pad=1080:640:(ow-iw)/2:(oh-ih)/2:black[top_v]`,
      '[front_v]scale=1080:640:force_original_aspect_ratio=decrease,pad=1080:640:(ow-iw)/2:(oh-ih)/2:black[middle_v]',
      '[back_v]scale=1080:640:force_original_aspect_ratio=decrease,pad=1080:640:(ow-iw)/2:(oh-ih)/2:black[bottom_v]',
      '[canvas_v][top_v]overlay=0:0[layer1_v]',
      '[layer1_v][middle_v]overlay=0:640[layer2_v]',
      '[layer2_v][bottom_v]overlay=0:1280[layout_v]'
    ]
  }
  return ['[front_v]scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black[layout_v]']
}

function buildTemplateProfile(templateId: string, hasBack: boolean, hasSide: boolean): string {
  if (templateId === 'T1') {
    return hasBack ? 'pip(front+back)' : 'single(front)'
  }
  if (templateId === 'T2') {
    if (hasBack && hasSide) {
      return 'inverted-triangle(top-front,bottom-side+back)'
    }
    if (hasBack) {
      return 'inverted-triangle(top-front,bottom-front+back)'
    }
    if (hasSide) {
      return 'inverted-triangle(top-front,bottom-side+front)'
    }
    return 'single(front)'
  }
  if (templateId === 'T3') {
    return hasBack ? 'split(left-front,right-back)' : 'single(front)'
  }
  if (templateId === 'T4') {
    if (hasBack && hasSide) {
      return 'portrait-stack(top-side,middle-front,bottom-back)'
    }
    if (hasBack) {
      return 'portrait-stack(top-front,middle-front,bottom-back)'
    }
    if (hasSide) {
      return 'portrait-stack(top-side,middle-front,bottom-front)'
    }
    return 'portrait-single(front)'
  }
  return 'fallback(front)'
}

function buildPostVideoNode(speed: number, watermarkEnabled: boolean): string {
  const filters: Array<string> = []
  if (watermarkEnabled) {
    filters.push('drawbox=x=iw-300:y=ih-72:w=280:h=52:color=black@0.32:t=fill')
  }
  if (speed !== 1) {
    const normalized = Math.max(0.25, Math.min(speed, 16))
    filters.push(`setpts=PTS/${normalized}`)
  }
  if (filters.length === 0) {
    return '[layout_v]null[v]'
  }
  return `[layout_v]${filters.join(',')}[v]`
}

async function ensureParentDirectory(filePath: string): Promise<void> {
  const slashIndex = filePath.lastIndexOf('/')
  if (slashIndex <= 0) {
    return
  }
  const outputDir = filePath.slice(0, slashIndex)
  try {
    await fs.stat(outputDir)
  } catch (_) {
    try {
      await fs.mkdir(outputDir)
    } catch (mkdirError) {
      const message = mkdirError instanceof Error ? mkdirError.message : String(mkdirError)
      throw new Error(`创建输出目录失败：${message}`)
    }
  }
}

export async function extractFirstFrameByService(sourceUri: string, cacheDir: string, cacheKey: string): Promise<string> {
  if (!sourceUri || sourceUri.length === 0) {
    return ''
  }
  const inputPath = await resolveInputForFfmpeg(sourceUri)
  const safeKey = cacheKey.replace(/[^a-zA-Z0-9_-]/g, '_')
  const outputPath = `${cacheDir}/first_frame_${safeKey}.jpg`
  try {
    await fs.stat(outputPath)
    return outputPath
  } catch (_) {
  }
  await ensureParentDirectory(outputPath)
  try {
    await FFmpeg.execute([
      '-y',
      '-i', inputPath,
      '-frames:v', '1',
      '-q:v', '3',
      outputPath
    ])
    return outputPath
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    throw new Error(`提取首帧失败：${message}`)
  }
}

export async function executeFfmpegComposeByService(
  request: ExportComposeRequest,
  cacheDir: string,
  onLog: (message: string) => void,
  onProgress: (percent: number) => void,
  singleClipRetryUsed: boolean = false
): Promise<string> {
  const stagedPaths: Array<string> = []
  let frontPaths: Array<string> = []
  let inputIndex: number = 0
  for (const uri of request.frontUris) {
    const readablePath = await resolveInputForFfmpeg(uri)
    const stagedPath = readablePath.startsWith('/data/') ? readablePath : await copyForFfmpeg(readablePath, inputIndex++, cacheDir)
    if (stagedPath !== readablePath) {
      stagedPaths.push(stagedPath)
    }
    frontPaths.push(stagedPath)
  }
  let backPaths: Array<string> = []
  for (const uri of request.backUris) {
    const readablePath = await resolveInputForFfmpeg(uri)
    const stagedPath = readablePath.startsWith('/data/') ? readablePath : await copyForFfmpeg(readablePath, inputIndex++, cacheDir)
    if (stagedPath !== readablePath) {
      stagedPaths.push(stagedPath)
    }
    backPaths.push(stagedPath)
  }
  let sidePaths: Array<string> = []
  for (const uri of request.sideUris) {
    const readablePath = await resolveInputForFfmpeg(uri)
    const stagedPath = readablePath.startsWith('/data/') ? readablePath : await copyForFfmpeg(readablePath, inputIndex++, cacheDir)
    if (stagedPath !== readablePath) {
      stagedPaths.push(stagedPath)
    }
    sidePaths.push(stagedPath)
  }
  if (frontPaths.length === 0) {
    if (backPaths.length > 0) {
      onLog('未找到前路输入，回退使用后路作为主轨')
      frontPaths = backPaths
      backPaths = []
    } else if (sidePaths.length > 0) {
      onLog('未找到前路输入，回退使用侧路作为主轨')
      frontPaths = sidePaths
      sidePaths = []
    } else {
      throw new Error('导出失败：所有轨道都为空')
    }
  }
  const inputs: Array<string> = []
  frontPaths.forEach((path: string) => {
    inputs.push('-i')
    inputs.push(path)
  })
  backPaths.forEach((path: string) => {
    inputs.push('-i')
    inputs.push(path)
  })
  sidePaths.forEach((path: string) => {
    inputs.push('-i')
    inputs.push(path)
  })
  const hasBack: boolean = backPaths.length > 0
  const hasSide: boolean = sidePaths.length > 0
  const speed = parseSpeedValue(request.speedLabel)
  const muted = request.muted
  const atempoChain = buildAtempoChain(speed)
  const frontRefs = frontPaths.map((_, index: number) => `[${index}:v]`).join('')
  const backRefs = hasBack ? backPaths.map((_, index: number) => `[${frontPaths.length + index}:v]`).join('') : ''
  const sideRefs = hasSide ? sidePaths.map((_, index: number) => `[${frontPaths.length + backPaths.length + index}:v]`).join('') : ''
  const frontAudioRefs = frontPaths.map((_, index: number) => `[${index}:a]`).join('')
  const concatNodes: Array<string> = [
    `${frontRefs}concat=n=${frontPaths.length}:v=1:a=0[front_v]`
  ]
  if (hasBack) {
    concatNodes.push(`${backRefs}concat=n=${backPaths.length}:v=1:a=0[back_v]`)
  } else {
    concatNodes.push('[front_v]null[back_v]')
  }
  if (hasSide) {
    concatNodes.push(`${sideRefs}concat=n=${sidePaths.length}:v=1:a=0[side_v]`)
  } else {
    concatNodes.push('[front_v]null[side_v]')
  }
  const layoutNodes = buildTemplateLayoutNodes(request.templateId, hasBack, hasSide)
  const videoFilter = [...concatNodes, ...layoutNodes, buildPostVideoNode(speed, request.watermarkEnabled)].join(';')
  const audioFilter = frontAudioRefs.length > 0
    ? `${frontAudioRefs}concat=n=${frontPaths.length}:v=0:a=1,${atempoChain}[a]`
    : ''
  const filter = audioFilter.length > 0 ? `${videoFilter};${audioFilter}` : videoFilter
  const outputPath = toFfmpegPath(request.outputPath)
  await ensureParentDirectory(outputPath)
  const audioArgs = muted
    ? ['-an']
    : ['-map', '[a]', '-c:a', 'aac']
  const coreArgs: Array<string> = [
    '-y',
    ...inputs,
    '-filter_complex', filter,
    '-map', '[v]',
    '-c:v', 'mpeg4',
    '-pix_fmt', 'yuv420p',
    ...audioArgs,
    outputPath
  ]
  const fallbackArgs: Array<string> = [
    '-y',
    ...inputs,
    '-filter_complex', videoFilter,
    '-map', '[v]',
    ...(muted ? ['-an'] : ['-map', '0:a?', '-c:a', 'aac']),
    outputPath
  ]
  const frontBitrate = frontPaths.length > 0 ? await probeVideoBitrate(frontPaths[0]) : 0
  const backBitrate = backPaths.length > 0 ? await probeVideoBitrate(backPaths[0]) : 0
  const targetBitrate = frontBitrate + backBitrate
  if (targetBitrate > 0) {
    coreArgs.splice(coreArgs.length - 1, 0, '-b:v', `${targetBitrate}`)
    coreArgs.splice(coreArgs.length - 1, 0, '-maxrate', `${targetBitrate}`)
    coreArgs.splice(coreArgs.length - 1, 0, '-bufsize', `${targetBitrate * 2}`)
  }
  onLog(`FFmpeg模板参数 template=${request.templateId} profile=${buildTemplateProfile(request.templateId, hasBack, hasSide)} speed=${request.speedLabel} speedValue=${speed} atempo=${atempoChain} muted=${muted} watermark=${request.watermarkEnabled}`)
  onLog(`FFmpeg目标码率=${targetBitrate}`)
  onLog(`FFmpeg命令输入统计 Front=${frontPaths.length} Back=${backPaths.length} Side=${sidePaths.length} 输出=${outputPath}`)
  const parseProgressPercent = (msg: string): number => {
    const match = msg.match(/time=(\d{2}):(\d{2}):(\d{2}(?:\.\d+)?)/)
    if (!match) {
      return -1
    }
    const hours = Number(match[1] ?? '0')
    const minutes = Number(match[2] ?? '0')
    const seconds = Number(match[3] ?? '0')
    const currentSec = (hours * 3600) + (minutes * 60) + seconds
    const totalSec = request.expectedDurationSec > 0 ? request.expectedDurationSec : 0
    if (totalSec <= 0) {
      return -1
    }
    const percent = Math.max(0, Math.min(99, Math.floor((currentSec / totalSec) * 100)))
    return percent
  }
  const run = async (command: Array<string>): Promise<void> => {
    const controller = new FFAbortController()
    let lastProgressLogAt = 0
    let lastProgressPercent = -1
    const timeoutId = setTimeout(() => {
      onLog('FFmpeg执行超时，主动中止')
      controller.abort(new Error('FFmpeg执行超时'))
    }, 600000)
    try {
      await FFmpeg.execute(command, {
        progressCallback: (msg: string) => {
          const progress = parseProgressPercent(msg)
          if (progress >= 0 && progress > lastProgressPercent) {
            lastProgressPercent = progress
            onProgress(progress)
          }
          const now = Date.now()
          if (now - lastProgressLogAt > 5000) {
            lastProgressLogAt = now
            onLog(`FFmpeg进度消息=${msg}`)
          }
        },
        signal: controller.signal
      })
    } finally {
      clearTimeout(timeoutId)
    }
  }
  try {
    await run(coreArgs)
  } catch (errorA) {
    const messageA = errorA instanceof Error ? errorA.message : String(errorA)
    if (messageA.includes('Option not found') || messageA.includes('Invalid argument')) {
      onLog(`FFmpeg主命令失败(${messageA})，切换最小参数重试`)
      try {
        await run(fallbackArgs)
      } catch (errorB) {
        const messageB = errorB instanceof Error ? errorB.message : String(errorB)
        onLog(`FFmpeg最小参数重试失败：${messageB}`)
        const shouldSingleClipRetry = !singleClipRetryUsed &&
          (messageA.includes('Invalid argument') || messageB.includes('Invalid argument')) &&
          (frontPaths.length > 1 || backPaths.length > 1 || sidePaths.length > 1)
        if (shouldSingleClipRetry) {
          onLog('FFmpeg切换单片段保底重试')
          const degraded = new ExportComposeRequest()
          degraded.fileName = request.fileName
          degraded.outputPath = request.outputPath
          degraded.expectedDurationSec = Math.max(1, Math.min(request.expectedDurationSec, 60))
          degraded.hideSpeed = request.hideSpeed
          degraded.hideGps = request.hideGps
          degraded.hideVin = request.hideVin
          degraded.templateId = request.templateId
          degraded.speedLabel = request.speedLabel
          degraded.muted = request.muted
          degraded.watermarkEnabled = request.watermarkEnabled
          degraded.frontUris = request.frontUris.length > 0 ? [request.frontUris[0]] : []
          degraded.backUris = request.backUris.length > 0 ? [request.backUris[0]] : []
          degraded.sideUris = request.sideUris.length > 0 ? [request.sideUris[0]] : []
          return await executeFfmpegComposeByService(degraded, cacheDir, onLog, onProgress, true)
        }
        throw new Error(messageB)
      }
    } else {
      onLog(`FFmpeg执行失败，原因=${messageA}`)
      throw new Error(messageA)
    }
  } finally {
    for (const path of stagedPaths) {
      try {
        await fs.unlink(path)
      } catch (_) {
      }
    }
  }
  return outputPath
}
