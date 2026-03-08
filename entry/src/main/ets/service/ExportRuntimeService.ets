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
      'ffprobe',
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

export async function executeFfmpegComposeByService(
  request: ExportComposeRequest,
  cacheDir: string,
  onLog: (message: string) => void,
  onProgress: (percent: number) => void
): Promise<string> {
  const stagedPaths: Array<string> = []
  const frontPaths: Array<string> = []
  let inputIndex: number = 0
  for (const uri of request.frontUris) {
    const readablePath = await resolveInputForFfmpeg(uri)
    const stagedPath = readablePath.startsWith('/data/') ? readablePath : await copyForFfmpeg(readablePath, inputIndex++, cacheDir)
    if (stagedPath !== readablePath) {
      stagedPaths.push(stagedPath)
    }
    frontPaths.push(stagedPath)
  }
  const backPaths: Array<string> = []
  for (const uri of request.backUris) {
    const readablePath = await resolveInputForFfmpeg(uri)
    const stagedPath = readablePath.startsWith('/data/') ? readablePath : await copyForFfmpeg(readablePath, inputIndex++, cacheDir)
    if (stagedPath !== readablePath) {
      stagedPaths.push(stagedPath)
    }
    backPaths.push(stagedPath)
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
  const frontRefs = frontPaths.map((_, index: number) => `[${index}:v]`).join('')
  const backRefs = backPaths.map((_, index: number) => `[${frontPaths.length + index}:v]`).join('')
  const frontAudioRefs = frontPaths.map((_, index: number) => `[${index}:a]`).join('')
  const videoFilter = `${frontRefs}concat=n=${frontPaths.length}:v=1:a=0[top];${backRefs}concat=n=${backPaths.length}:v=1:a=0[bottom];[top][bottom]vstack=inputs=2[v]`
  const audioFilter = `${frontAudioRefs}concat=n=${frontPaths.length}:v=0:a=1[a]`
  const filter = `${videoFilter};${audioFilter}`
  const outputPath = toFfmpegPath(request.outputPath)
  const slashIndex = outputPath.lastIndexOf('/')
  if (slashIndex > 0) {
    const outputDir = outputPath.slice(0, slashIndex)
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
  const coreArgs: Array<string> = [
    'ffmpeg',
    '-y',
    ...inputs,
    '-filter_complex', filter,
    '-map', '[v]',
    '-map', '[a]',
    '-c:v', 'mpeg4',
    '-c:a', 'aac',
    '-pix_fmt', 'yuv420p',
    outputPath
  ]
  const fallbackArgs: Array<string> = [
    'ffmpeg',
    '-y',
    ...inputs,
    '-filter_complex', videoFilter,
    '-map', '[v]',
    '-map', '0:a?',
    '-c:a', 'aac',
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
  onLog(`FFmpeg目标码率=${targetBitrate}`)
  onLog(`FFmpeg命令输入统计 Front=${frontPaths.length} Back=${backPaths.length} 输出=${outputPath}`)
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
    if (messageA.includes('Option not found')) {
      onLog('FFmpeg参数不兼容，切换最小参数重试')
      await run(fallbackArgs)
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
