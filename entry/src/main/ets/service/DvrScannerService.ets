import { DvrMeta, PreviewSource } from '../model/TripModels'
import smartdriveExporter from 'libsmartdrive_exporter.so'
import { ensureCoreApiContract } from './CoreApiContract'

class NativeDvrMetaResult {
  fileName: string = ''
  uri: string = ''
  date: string = ''
  time: string = ''
  camera: string = ''
  timestamp: number = 0
}

export function parseDvrFileName(name: string, uri: string): DvrMeta | null {
  if (name.length === 0 || uri.length === 0) {
    return null
  }
  ensureCoreApiContract()
  const parse = smartdriveExporter.parseDvrFileName as ((name: string, uri: string) => NativeDvrMetaResult | null) | undefined
  if (typeof parse !== 'function') {
    throw new Error('smartdrive_exporter.parseDvrFileName 未实现')
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
