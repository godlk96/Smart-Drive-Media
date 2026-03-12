import { DvrMeta, ExportComposeRequest } from '../model/TripModels'
import smartdriveExporter from 'libsmartdrive_exporter.so'
import { ensureCoreApiContract } from './CoreApiContract'

class NativeComposeRequestResult {
  frontUris: Array<string> = []
  backUris: Array<string> = []
}

class TemplateTrackSelection {
  frontUris: Array<string> = []
  backUris: Array<string> = []
  sideUris: Array<string> = []
}

function pickTrackUris(clips: Array<DvrMeta>, preferredCameras: Array<string>): Array<string> {
  for (const camera of preferredCameras) {
    const uris = clips
      .filter((item: DvrMeta) => item.camera === camera && item.uri.length > 0)
      .sort((a: DvrMeta, b: DvrMeta) => a.timestamp - b.timestamp)
      .map((item: DvrMeta) => item.uri)
    if (uris.length > 0) {
      return uris
    }
  }
  return []
}

function findMetaByUri(clips: Array<DvrMeta>, uri: string): DvrMeta | undefined {
  return clips.find((item: DvrMeta) => item.uri === uri)
}

function pickTrackMetas(clips: Array<DvrMeta>, preferredCameras: Array<string>): Array<DvrMeta> {
  for (const camera of preferredCameras) {
    const metas = clips
      .filter((item: DvrMeta) => item.camera === camera && item.uri.length > 0)
      .sort((a: DvrMeta, b: DvrMeta) => a.timestamp - b.timestamp)
    if (metas.length > 0) {
      return metas
    }
  }
  return []
}

function alignSideUrisByFront(clips: Array<DvrMeta>, frontUris: Array<string>, preferredCameras: Array<string>): Array<string> {
  const sideMetas = pickTrackMetas(clips, preferredCameras)
  if (sideMetas.length === 0 || frontUris.length === 0) {
    return []
  }
  const uris: Array<string> = []
  for (const frontUri of frontUris) {
    const frontMeta = findMetaByUri(clips, frontUri)
    if (!frontMeta) {
      uris.push(sideMetas[0].uri)
      continue
    }
    let best = sideMetas[0]
    let bestDelta = Math.abs(best.timestamp - frontMeta.timestamp)
    sideMetas.forEach((meta: DvrMeta) => {
      const delta = Math.abs(meta.timestamp - frontMeta.timestamp)
      if (delta < bestDelta) {
        best = meta
        bestDelta = delta
      }
    })
    uris.push(best.uri)
  }
  return uris
}

function resolveTemplateTracks(clips: Array<DvrMeta>, templateId: string, nativeFrontUris: Array<string>, nativeBackUris: Array<string>): TemplateTrackSelection {
  const selection = new TemplateTrackSelection()
  const normalized = templateId === 'T1' || templateId === 'T2' || templateId === 'T3' || templateId === 'T4' ? templateId : 'T2'
  selection.frontUris = nativeFrontUris
  selection.backUris = nativeBackUris
  if (normalized === 'T1') {
    if (selection.frontUris.length === 0) {
      selection.frontUris = pickTrackUris(clips, ['Front', 'LeftFront', 'RightFront'])
    }
    if (selection.backUris.length === 0) {
      selection.backUris = pickTrackUris(clips, ['Back', 'Right', 'Left'])
    }
    return selection
  }
  if (normalized === 'T2') {
    if (selection.frontUris.length === 0) {
      selection.frontUris = pickTrackUris(clips, ['Front', 'LeftFront', 'RightFront'])
    }
    if (selection.backUris.length === 0) {
      selection.backUris = pickTrackUris(clips, ['Back', 'Right', 'Left'])
    }
    selection.sideUris = alignSideUrisByFront(clips, selection.frontUris, ['Left', 'Right', 'LeftFront', 'RightFront'])
    return selection
  }
  if (normalized === 'T3') {
    selection.frontUris = pickTrackUris(clips, ['Left', 'LeftFront', 'Front'])
    selection.backUris = pickTrackUris(clips, ['Right', 'RightFront', 'Back'])
    return selection
  }
  if (selection.frontUris.length === 0) {
    selection.frontUris = pickTrackUris(clips, ['Front', 'LeftFront', 'RightFront'])
  }
  if (selection.backUris.length === 0) {
    selection.backUris = pickTrackUris(clips, ['RightFront', 'Right', 'Back'])
  }
  selection.sideUris = alignSideUrisByFront(clips, selection.frontUris, ['LeftFront', 'Left', 'Front'])
  return selection
}

export function buildComposeRequestByService(
  clips: Array<DvrMeta>,
  fileName: string,
  outputPath: string,
  expectedDurationSec: number,
  hideSpeed: boolean,
  hideGps: boolean,
  hideVin: boolean,
  templateId: string,
  speedLabel: string,
  muted: boolean,
  watermarkEnabled: boolean
): ExportComposeRequest {
  ensureCoreApiContract()
  const request = new ExportComposeRequest()
  request.fileName = fileName
  request.outputPath = outputPath
  request.expectedDurationSec = expectedDurationSec
  request.hideSpeed = hideSpeed
  request.hideGps = hideGps
  request.hideVin = hideVin
  request.templateId = templateId
  request.speedLabel = speedLabel
  request.muted = muted
  request.watermarkEnabled = watermarkEnabled
  const nativeBuild = smartdriveExporter.buildComposeRequest as ((
    clipsCsv: string,
    fileName: string,
    outputPath: string,
    flags: string
  ) => NativeComposeRequestResult) | undefined
  if (typeof nativeBuild !== 'function') {
    throw new Error('smartdrive_exporter.buildComposeRequest 未实现')
  }
  const clipsCsv = clips.map((item: DvrMeta) => `${item.camera}@${item.timestamp}@${item.uri}`).join(',')
  const flags = `${hideSpeed ? 1 : 0},${hideGps ? 1 : 0},${hideVin ? 1 : 0}`
  const data = nativeBuild(clipsCsv, fileName, outputPath, flags)
  const templateTracks = resolveTemplateTracks(clips, templateId, data.frontUris ?? [], data.backUris ?? [])
  request.frontUris = templateTracks.frontUris
  request.backUris = templateTracks.backUris
  request.sideUris = templateTracks.sideUris
  return request
}
