import { DvrMeta, PreviewSource } from '../model/TripModels'
import smartdriveExporter from 'libsmartdrive_exporter.so'
import { tryEnsureCoreApiContract } from './CoreApiContract'

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
  if (normalized === 'front') {
    return 'Front'
  }
  if (normalized === 'back') {
    return 'Back'
  }
  if (normalized === 'left') {
    return 'Left'
  }
  if (normalized === 'right') {
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
  const pattern: RegExp = /^DVR_LoopRecording_(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-(\d{2})_([a-z_]+)_camera\.(mp4|mov|ts)$/i
  const match = name.match(pattern)
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
    return parseDvrFileNameByJs(name, uri)
  }
  const parse = smartdriveExporter.parseDvrFileName as ((name: string, uri: string) => NativeDvrMetaResult | null) | undefined
  if (typeof parse !== 'function') {
    return parseDvrFileNameByJs(name, uri)
  }
  const raw = parse(name, uri)
  if (!raw) {
    return null
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
