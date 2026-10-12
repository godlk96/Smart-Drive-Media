import hilog from '@ohos.hilog'
import fs from '@ohos.file.fs'

const LOG_DOMAIN: number = 0x3200
const LOG_TAG: string = '智驾影音'
let runtimeLogFile: string = ''
let runtimeLogReady: boolean = false

function nowText(): string {
  const date = new Date()
  const yyyy = String(date.getFullYear())
  const mm = String(date.getMonth() + 1).padStart(2, '0')
  const dd = String(date.getDate()).padStart(2, '0')
  const hh = String(date.getHours()).padStart(2, '0')
  const mi = String(date.getMinutes()).padStart(2, '0')
  const ss = String(date.getSeconds()).padStart(2, '0')
  const ms = String(date.getMilliseconds()).padStart(3, '0')
  return `${yyyy}-${mm}-${dd} ${hh}:${mi}:${ss}.${ms}`
}

async function ensureDir(path: string): Promise<boolean> {
  try {
    await fs.stat(path)
    return true
  } catch (_) {
  }
  try {
    await fs.mkdir(path)
    return true
  } catch (_) {
    return false
  }
}

const LOG_BUFFER_FLUSH_THRESHOLD: number = 20
const LOG_BUFFER_MAX_SIZE: number = 200
const logBuffer: Array<string> = []
let isFlushing: boolean = false
let flushTimer: number = -1

async function flushLogBuffer(): Promise<void> {
  if (isFlushing || logBuffer.length === 0 || !runtimeLogReady || runtimeLogFile.length === 0) {
    return
  }
  isFlushing = true
  const linesToWrite = logBuffer.splice(0, logBuffer.length)
  let fd: number = -1
  try {
    const file = await fs.open(runtimeLogFile, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND)
    fd = file.fd
    const content = linesToWrite.join('\n') + '\n'
    await fs.write(fd, content)
  } catch (_) {
  } finally {
    if (fd >= 0) {
      try {
        await fs.close(fd)
      } catch (_) {
      }
    }
    isFlushing = false
    if (logBuffer.length >= LOG_BUFFER_FLUSH_THRESHOLD) {
      void flushLogBuffer()
    }
  }
}

function scheduleLogFlush(): void {
  if (flushTimer >= 0) {
    return
  }
  flushTimer = setTimeout(() => {
    flushTimer = -1
    void flushLogBuffer()
  }, 1000) as unknown as number
}

export async function initRuntimeLog(baseDir: string): Promise<void> {
  if (runtimeLogReady && runtimeLogFile.length > 0) {
    return
  }
  if (baseDir.length === 0) {
    return
  }
  const logDir = `${baseDir}/logs`
  const ready = await ensureDir(logDir)
  if (!ready) {
    return
  }
  runtimeLogFile = `${logDir}/run_${Date.now()}.log`
  let fd: number = -1
  try {
    const file = await fs.open(runtimeLogFile, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE)
    fd = file.fd
    runtimeLogReady = true
  } catch (_) {
    runtimeLogReady = false
    runtimeLogFile = ''
    return
  } finally {
    if (fd >= 0) {
      try {
        await fs.close(fd)
      } catch (_) {
      }
    }
  }
  debugLog('系统', `日志文件初始化完成：${runtimeLogFile}`)
}

export function getRuntimeLogPath(): string {
  return runtimeLogFile
}

export function debugLog(scope: string, message: string): void {
  const text = `【${scope}】${message}`
  hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', text)
  if (!runtimeLogReady || runtimeLogFile.length === 0) {
    return
  }
  if (logBuffer.length < LOG_BUFFER_MAX_SIZE) {
    logBuffer.push(`${nowText()} ${text}`)
  }
  if (logBuffer.length >= LOG_BUFFER_FLUSH_THRESHOLD) {
    void flushLogBuffer()
  } else {
    scheduleLogFlush()
  }
}
