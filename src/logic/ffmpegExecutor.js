function parseTimeToSeconds(text) {
  const match = /time=(\d{2}):(\d{2}):(\d{2}(?:\.\d+)?)/.exec(text)
  if (!match) {
    return null
  }
  const hour = Number(match[1])
  const minute = Number(match[2])
  const second = Number(match[3])
  if (!Number.isFinite(hour) || !Number.isFinite(minute) || !Number.isFinite(second)) {
    return null
  }
  return hour * 3600 + minute * 60 + second
}

export function parseFfmpegProgress(line, totalDurationSec) {
  const total = Number(totalDurationSec)
  if (!Number.isFinite(total) || total <= 0) {
    return null
  }
  const seconds = parseTimeToSeconds(String(line ?? ''))
  if (seconds === null) {
    return null
  }
  const progress = Math.floor((seconds / total) * 100)
  return Math.max(0, Math.min(progress, 100))
}

export function createNodeProcessRunner(ffmpegBinary = 'ffmpeg') {
  return async ({ args, onStdErrLine }) => {
    const { spawn } = await import('node:child_process')
    await new Promise((resolve, reject) => {
      const child = spawn(ffmpegBinary, args, { stdio: ['ignore', 'pipe', 'pipe'] })
      let stderrBuffer = ''
      child.stderr.on('data', chunk => {
        stderrBuffer += String(chunk)
        const lines = stderrBuffer.split(/\r?\n/)
        stderrBuffer = lines.pop() ?? ''
        lines.forEach(line => {
          onStdErrLine?.(line)
        })
      })
      child.on('error', reject)
      child.on('close', code => {
        if (stderrBuffer.length > 0) {
          onStdErrLine?.(stderrBuffer)
        }
        if (code === 0) {
          resolve()
          return
        }
        reject(new Error(`ffmpeg_exit_${code}`))
      })
    })
  }
}

export function createNodeConcatFileFactory() {
  return async content => {
    const { writeFile, mkdir } = await import('node:fs/promises')
    const { join } = await import('node:path')
    const dir = join(process.cwd(), '.tmp-export')
    await mkdir(dir, { recursive: true })
    const filePath = join(dir, `concat-${Date.now()}-${Math.random().toString(16).slice(2)}.txt`)
    await writeFile(filePath, content, 'utf8')
    return filePath
  }
}

export function createNodeRemoveFile() {
  return async filePath => {
    if (!filePath) {
      return
    }
    const { unlink } = await import('node:fs/promises')
    await unlink(filePath).catch(() => {})
  }
}

export class FfmpegExecutor {
  constructor({ runProcess, createConcatFile, removeFile } = {}) {
    this.runProcess = runProcess
    this.createConcatFile = createConcatFile
    this.removeFile = removeFile
  }

  async execute(command, { totalDurationSec = 0, onProgress, onLog } = {}) {
    if (!this.runProcess) {
      throw new Error('ffmpeg_runner_unavailable')
    }
    const concatFilePaths = []
    let args = [...(command?.args ?? [])]
    try {
      if (command?.type === 'stream_copy' && command.concatFileContent) {
        if (!this.createConcatFile) {
          throw new Error('concat_file_writer_unavailable')
        }
        const concatFilePath = await this.createConcatFile(command.concatFileContent)
        concatFilePaths.push(concatFilePath)
        args = args.map(item => (item === 'concat.txt' ? concatFilePath : item))
      }
      if (command?.concatFiles?.length) {
        if (!this.createConcatFile) {
          throw new Error('concat_file_writer_unavailable')
        }
        for (const file of command.concatFiles) {
          const concatPath = await this.createConcatFile(file.content)
          concatFilePaths.push(concatPath)
          args = args.map(item => (item === file.placeholder ? concatPath : item))
        }
      }
      onProgress?.(0)
      await this.runProcess({
        args,
        onStdErrLine: line => {
          onLog?.(line)
          const progress = parseFfmpegProgress(line, totalDurationSec)
          if (progress !== null) {
            onProgress?.(progress)
          }
        }
      })
      onProgress?.(100)
      return { ok: true }
    } finally {
      for (const path of concatFilePaths) {
        await this.removeFile?.(path)
      }
    }
  }
}
