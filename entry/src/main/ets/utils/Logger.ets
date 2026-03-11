import hilog from '@ohos.hilog'
import fs from '@ohos.file.fs'

const LOG_DOMAIN: number = 0x3200
const LOG_TAG: string = '智驾影音'
let runtimeLogFile: string = ''
let runtimeLogReady: boolean = false
let runtimeLogChain: Promise<void> = Promise.resolve()

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

async function appendRuntimeLog(line: string): Promise<void> {
  if (!runtimeLogReady || runtimeLogFile.length === 0) {
    return
  }
  let fd: number = -1
  try {
    const file = await fs.open(runtimeLogFile, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND)
    fd = file.fd
    await fs.write(fd, `${line}\n`)
  } catch (_) {
  } finally {
    if (fd >= 0) {
      try {
        await fs.close(fd)
      } catch (_) {
      }
    }
  }
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
  await appendRuntimeLog(`${nowText()} [系统] 日志文件=${runtimeLogFile}`)
}

export function getRuntimeLogPath(): string {
  return runtimeLogFile
}

export function debugLog(scope: string, message: string): void {
  const text = `【${scope}】${message}`
  hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', text)
  console.info(text)
  const line = `${nowText()} ${text}`
  runtimeLogChain = runtimeLogChain
    .then(() => appendRuntimeLog(line))
    .catch(() => {
    })
}
