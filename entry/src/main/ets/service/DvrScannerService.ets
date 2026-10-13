import { DvrMeta, PreviewSource } from '../model/TripModels'
import smartdriveExporter from 'libsmartdrive_exporter.so'
import { tryEnsureCoreApiContract } from './CoreApiContract'
import { debugLog } from '../utils/Logger'

class NativeDvrMetaResult {
  fileName: string = ''
  uri: string = ''
  date: string = ''
  time: string = ''
  camera: string = ''
  timestamp: number = 0
}

function normalizeCamera(cameraRaw: string): string {
  const normalized = cameraRaw.toLowerCase()
  if (normalized === 'front' || normalized === 'ft') {
    return 'Front'
  }
  if (normalized === 'back' || normalized === 'rear' || normalized === 'rr') {
    return 'Back'
  }
  if (normalized === 'left' || normalized === 'left_rear' || normalized === 'lt') {
    return 'Left'
  }
  if (normalized === 'right' || normalized === 'right_rear' || normalized === 'rt') {
    return 'Right'
  }
  if (normalized === 'left_front') {
    return 'LeftFront'
  }
  if (normalized === 'right_front') {
    return 'RightFront'
  }
  return cameraRaw
}

function parseDvrFileNameByJs(name: string, uri: string): DvrMeta | null {
  const loopPattern: RegExp = /^(?:.+_)?DVR_LoopRecording_(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-(\d{2})_([a-z_]+)_camera\.(mp4|mov|ts)$/i
  let match = name.match(loopPattern)
  if (!match) {
    const sentryPattern: RegExp = /^(?:.+_)?Sentry_(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-(\d{2})_([a-z]+)\.(mp4|mov|ts)$/i
    match = name.match(sentryPattern)
  }
  if (!match) {
    return null
  }
  const date = String(match[1] ?? '')
  const hh = String(match[2] ?? '')
  const mm = String(match[3] ?? '')
  const ss = String(match[4] ?? '')
  const cameraRaw = String(match[5] ?? '')
  const isoText = `${date}T${hh}:${mm}:${ss}`
  const parsedDate = new Date(isoText)
  const timestamp = parsedDate.getTime()
  if (!Number.isFinite(timestamp) || timestamp <= 0) {
    return null
  }
  const meta = new DvrMeta()
  meta.fileName = name
  meta.uri = uri
  meta.date = date
  meta.time = `${hh}:${mm}:${ss}`
  meta.camera = normalizeCamera(cameraRaw)
  meta.timestamp = Math.floor(timestamp)
  return meta
}

export function parseDvrFileName(name: string, uri: string): DvrMeta | null {
  if (name.length === 0 || uri.length === 0) {
    return null
  }
  if (!tryEnsureCoreApiContract()) {
    debugLog('扫描诊断', `解析降级：CoreApiContract不可用，使用JS解析，文件=${name}`)
    return parseDvrFileNameByJs(name, uri)
  }
  const parse = smartdriveExporter.parseDvrFileName as ((name: string, uri: string) => NativeDvrMetaResult | null) | undefined
  if (typeof parse !== 'function') {
    debugLog('扫描诊断', `解析降级：Native parseDvrFileName缺失，使用JS解析，文件=${name}`)
    return parseDvrFileNameByJs(name, uri)
  }
  const raw = parse(name, uri)
  if (!raw) {
    const fallbackMeta = parseDvrFileNameByJs(name, uri)
    if (fallbackMeta !== null) {
      debugLog('扫描诊断', `解析降级：Native解析失败，JS解析兜底成功，文件=${name}`)
    } else {
      debugLog('扫描诊断', `解析失败：Native与JS均无法解析，文件=${name}`)
    }
    return fallbackMeta
  }
  const meta = new DvrMeta()
  meta.fileName = String(raw.fileName ?? '')
  meta.uri = String(raw.uri ?? '')
  meta.date = String(raw.date ?? '')
  meta.time = String(raw.time ?? '')
  meta.camera = String(raw.camera ?? '')
  meta.timestamp = Number(raw.timestamp ?? 0)
  if (meta.camera.length === 0 || meta.timestamp <= 0) {
    return null
  }
  return meta
}

export function pickPreviewSource(metas: Array<DvrMeta>): PreviewSource {
  const preview = new PreviewSource()
  const front = metas.find((item: DvrMeta) => item.camera === 'Front' && item.uri.length > 0)
  if (front) {
    preview.uri = front.uri
    preview.frameUri = front.uri
    preview.camera = 'Front'
    return preview
  }
  const first = metas.find((item: DvrMeta) => item.uri.length > 0)
  if (first) {
    preview.uri = first.uri
    preview.frameUri = first.uri
    preview.camera = first.camera
  }
  return preview
}
