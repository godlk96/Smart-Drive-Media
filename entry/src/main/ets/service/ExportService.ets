import { DvrMeta, ExportComposeRequest } from '../model/TripModels'
import { ensureCoreApiContract } from './CoreApiContract'
import { resolveTemplateDefinition, toLegacyCamera } from '../model/Models'

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

function alignSideUrisByFront(
  clips: Array<DvrMeta>,
  frontUris: Array<string>,
  frontIndexes: Array<number>,
  preferredCameras: Array<string>
): Array<string> {
  const sideMetas = pickTrackMetas(clips, preferredCameras)
  if (sideMetas.length === 0 || frontUris.length === 0) {
    return []
  }
  const uris: Array<string> = []
  for (let i = 0; i < frontUris.length; i++) {
    const frontUri = frontUris[i]
    let frontMeta: DvrMeta | undefined = undefined
    const frontIndex = Math.floor(Number(frontIndexes[i] ?? -1))
    if (frontIndex >= 0 && frontIndex < clips.length) {
      frontMeta = clips[frontIndex]
    }
    if (!frontMeta) {
      frontMeta = findMetaByUri(clips, frontUri)
    }
    if (!frontMeta) {
      uris.push(sideMetas[0].uri)
      continue
    }
    const frontTimestamp = frontMeta.timestamp
    let best = sideMetas[0]
    let bestDelta = Math.abs(best.timestamp - frontTimestamp)
    sideMetas.forEach((meta: DvrMeta) => {
      const delta = Math.abs(meta.timestamp - frontTimestamp)
      if (delta < bestDelta) {
        best = meta
        bestDelta = delta
      }
    })
    uris.push(best.uri)
  }
  return uris
}

function resolveTemplateTracks(
  clips: Array<DvrMeta>,
  templateId: string,
  nativeFrontUris: Array<string>,
  nativeBackUris: Array<string>,
  nativeFrontIndexes: Array<number>
): TemplateTrackSelection {
  const selection = new TemplateTrackSelection()
  const definition = resolveTemplateDefinition(templateId)
  const ffmpegPolicy = definition.ffmpegPolicy
  const isT2Template = definition.templateId === 'T2'
  const frontCandidates = ffmpegPolicy.frontTrackCandidates.map((camera) => toLegacyCamera(camera))
  const backCandidates = ffmpegPolicy.backTrackCandidates.map((camera) => toLegacyCamera(camera))
  const sideCandidates = ffmpegPolicy.sideTrackCandidates.map((camera) => toLegacyCamera(camera))
  if (!ffmpegPolicy.ignoreNativeTrackSelection && nativeFrontUris.length > 0) {
    selection.frontUris = nativeFrontUris
  } else {
    selection.frontUris = pickTrackUris(clips, frontCandidates)
  }
  if (!ffmpegPolicy.ignoreNativeTrackSelection && !isT2Template && nativeBackUris.length > 0) {
    selection.backUris = nativeBackUris
  } else {
    selection.backUris = pickTrackUris(clips, backCandidates)
  }
  if (ffmpegPolicy.needSideTrack) {
    if (ffmpegPolicy.alignSideByFrontTimeline) {
      selection.sideUris = alignSideUrisByFront(clips, selection.frontUris, nativeFrontIndexes, sideCandidates)
    } else {
      selection.sideUris = pickTrackUris(clips, sideCandidates)
    }
  } else {
    selection.sideUris = []
  }
  return selection
}

export function buildComposeRequestByService(
  clips: Array<DvrMeta>,
  fileName: string,
  outputPath: string,
  expectedDurationSec: number,
  hideSpeed: boolean,
  hideGps: boolean,
  hideTime: boolean,
  hideVin: boolean,
  templateId: string,
  speedLabel: string,
  muted: boolean,
  watermarkEnabled: boolean,
  rangeStartMs: number = 0,
  rangeEndMs: number = 0
): ExportComposeRequest {
  ensureCoreApiContract()
  const request = new ExportComposeRequest()
  request.fileName = fileName
  request.outputPath = outputPath
  request.expectedDurationSec = expectedDurationSec
  request.rangeStartMs = rangeStartMs
  request.rangeEndMs = rangeEndMs
  request.hideSpeed = hideSpeed
  request.hideGps = hideGps
  request.hideTime = hideTime
  request.hideVin = hideVin
  request.templateId = templateId
  request.speedLabel = speedLabel
  request.muted = muted
  request.watermarkEnabled = watermarkEnabled
  const nativeFrontUris: Array<string> = []
  const nativeBackUris: Array<string> = []
  const nativeFrontIndexes: Array<number> = []
  clips.forEach((item: DvrMeta, index: number) => {
    if (item.camera === 'Front' && item.uri.length > 0) {
      nativeFrontUris.push(item.uri)
      nativeFrontIndexes.push(index)
    } else if (item.camera === 'Back' && item.uri.length > 0) {
      nativeBackUris.push(item.uri)
    }
  })

  const templateTracks = resolveTemplateTracks(clips, templateId, nativeFrontUris, nativeBackUris, nativeFrontIndexes)
  request.frontUris = templateTracks.frontUris
  request.backUris = templateTracks.backUris
  request.sideUris = templateTracks.sideUris
  return request
}
