import { DvrMeta, TripSnapshot } from './TripModels'

export enum CameraPosition {
  FRONT = 'FRONT',
  REAR = 'REAR',
  LEFT = 'LEFT',
  RIGHT = 'RIGHT',
  LEFT_FRONT = 'LEFT_FRONT',
  RIGHT_FRONT = 'RIGHT_FRONT'
}

export enum TemplateId {
  T1 = 'T1',
  T2 = 'T2',
  T3 = 'T3',
  T4 = 'T4',
  T5 = 'T5'
}

export interface ClipSegment {
  clipId: string
  camera: CameraPosition
  uri: string
  timestampMs: number
  durationSec: number
}

export interface CameraTrack {
  camera: CameraPosition
  segments: Array<ClipSegment>
}

export interface Trip {
  tripId: string
  title: string
  rangeText: string
  durationSec: number
  tracks: Record<CameraPosition, CameraTrack>
  startTs: number
  endTs: number
}

export interface TemplateSlotBinding {
  slotId: string
  camera: CameraPosition
}

export interface TemplatePreviewSlot {
  slotId: string
  x: number
  y: number
  width: number
  height: number
}

export interface TemplateFfmpegPolicy {
  needSideTrack: boolean
  disableFrontAudio: boolean
  frontTrackCandidates: Array<CameraPosition>
  backTrackCandidates: Array<CameraPosition>
  sideTrackCandidates: Array<CameraPosition>
  alignSideByFrontTimeline: boolean
  ignoreNativeTrackSelection: boolean
}

export interface TemplateDefinition {
  templateId: TemplateId
  title: string
  subtitle: string
  requiredCameras: Array<CameraPosition>
  optionalCameras: Array<CameraPosition>
  slotBindings: Array<TemplateSlotBinding>
  previewSlots: Array<TemplatePreviewSlot>
  ffmpegPolicy: TemplateFfmpegPolicy
}

export const DEFAULT_TEMPLATE_ID: TemplateId = TemplateId.T2

const TEMPLATE_DEFINITION_MAP: Record<TemplateId, TemplateDefinition> = {
  [TemplateId.T1]: {
    templateId: TemplateId.T1,
    title: '防追尾双录',
    subtitle: '上下堆叠',
    requiredCameras: [CameraPosition.FRONT, CameraPosition.REAR],
    optionalCameras: [CameraPosition.RIGHT, CameraPosition.LEFT, CameraPosition.LEFT_FRONT, CameraPosition.RIGHT_FRONT],
    slotBindings: [
      { slotId: 'top', camera: CameraPosition.FRONT },
      { slotId: 'bottom', camera: CameraPosition.REAR }
    ],
    previewSlots: [
      { slotId: 'top', x: 0, y: 0, width: 1, height: 0.5 },
      { slotId: 'bottom', x: 0, y: 0.5, width: 1, height: 0.5 }
    ],
    ffmpegPolicy: {
      needSideTrack: false,
      disableFrontAudio: false,
      frontTrackCandidates: [CameraPosition.FRONT, CameraPosition.LEFT_FRONT, CameraPosition.RIGHT_FRONT],
      backTrackCandidates: [CameraPosition.REAR, CameraPosition.RIGHT, CameraPosition.RIGHT_FRONT, CameraPosition.LEFT],
      sideTrackCandidates: [],
      alignSideByFrontTimeline: false,
      ignoreNativeTrackSelection: false
    }
  },
  [TemplateId.T2]: {
    templateId: TemplateId.T2,
    title: '避险防加塞',
    subtitle: '倒品字',
    requiredCameras: [CameraPosition.FRONT, CameraPosition.LEFT, CameraPosition.RIGHT],
    optionalCameras: [CameraPosition.REAR, CameraPosition.LEFT_FRONT, CameraPosition.RIGHT_FRONT],
    slotBindings: [
      { slotId: 'top', camera: CameraPosition.FRONT },
      { slotId: 'bottomLeft', camera: CameraPosition.LEFT },
      { slotId: 'bottomRight', camera: CameraPosition.RIGHT }
    ],
    previewSlots: [
      { slotId: 'top', x: 0, y: 0, width: 1, height: 0.6667 },
      { slotId: 'bottomLeft', x: 0, y: 0.6667, width: 0.5, height: 0.3333 },
      { slotId: 'bottomRight', x: 0.5, y: 0.6667, width: 0.5, height: 0.3333 }
    ],
    ffmpegPolicy: {
      needSideTrack: true,
      disableFrontAudio: false,
      frontTrackCandidates: [CameraPosition.FRONT, CameraPosition.LEFT_FRONT, CameraPosition.RIGHT_FRONT],
      backTrackCandidates: [CameraPosition.RIGHT, CameraPosition.RIGHT_FRONT, CameraPosition.REAR, CameraPosition.LEFT],
      sideTrackCandidates: [CameraPosition.LEFT, CameraPosition.LEFT_FRONT, CameraPosition.FRONT, CameraPosition.RIGHT],
      alignSideByFrontTimeline: true,
      ignoreNativeTrackSelection: false
    }
  },
  [TemplateId.T3]: {
    templateId: TemplateId.T3,
    title: '侧向防开门杀',
    subtitle: '左右分屏',
    requiredCameras: [CameraPosition.LEFT, CameraPosition.RIGHT],
    optionalCameras: [CameraPosition.LEFT_FRONT, CameraPosition.RIGHT_FRONT, CameraPosition.FRONT, CameraPosition.REAR],
    slotBindings: [
      { slotId: 'left', camera: CameraPosition.LEFT },
      { slotId: 'right', camera: CameraPosition.RIGHT }
    ],
    previewSlots: [
      { slotId: 'left', x: 0, y: 0, width: 0.5, height: 1 },
      { slotId: 'right', x: 0.5, y: 0, width: 0.5, height: 1 }
    ],
    ffmpegPolicy: {
      needSideTrack: false,
      disableFrontAudio: true,
      frontTrackCandidates: [CameraPosition.LEFT, CameraPosition.LEFT_FRONT, CameraPosition.FRONT],
      backTrackCandidates: [CameraPosition.RIGHT, CameraPosition.RIGHT_FRONT, CameraPosition.REAR],
      sideTrackCandidates: [],
      alignSideByFrontTimeline: false,
      ignoreNativeTrackSelection: true
    }
  },
  [TemplateId.T4]: {
    templateId: TemplateId.T4,
    title: '沉浸式旅拍',
    subtitle: '横向三分屏',
    requiredCameras: [CameraPosition.LEFT_FRONT, CameraPosition.FRONT, CameraPosition.RIGHT_FRONT],
    optionalCameras: [CameraPosition.LEFT, CameraPosition.RIGHT, CameraPosition.REAR],
    slotBindings: [
      { slotId: 'left', camera: CameraPosition.LEFT_FRONT },
      { slotId: 'center', camera: CameraPosition.FRONT },
      { slotId: 'right', camera: CameraPosition.RIGHT_FRONT }
    ],
    previewSlots: [
      { slotId: 'left', x: 0, y: 0, width: 0.3333, height: 1 },
      { slotId: 'center', x: 0.3333, y: 0, width: 0.3334, height: 1 },
      { slotId: 'right', x: 0.6667, y: 0, width: 0.3333, height: 1 }
    ],
    ffmpegPolicy: {
      needSideTrack: true,
      disableFrontAudio: false,
      frontTrackCandidates: [CameraPosition.FRONT, CameraPosition.LEFT_FRONT, CameraPosition.RIGHT_FRONT],
      backTrackCandidates: [CameraPosition.RIGHT_FRONT, CameraPosition.RIGHT, CameraPosition.REAR],
      sideTrackCandidates: [CameraPosition.LEFT_FRONT, CameraPosition.LEFT, CameraPosition.FRONT],
      alignSideByFrontTimeline: true,
      ignoreNativeTrackSelection: true
    }
  },
  [TemplateId.T5]: {
    templateId: TemplateId.T5,
    title: '单前视',
    subtitle: '固定前视',
    requiredCameras: [CameraPosition.FRONT],
    optionalCameras: [],
    slotBindings: [
      { slotId: 'top', camera: CameraPosition.FRONT }
    ],
    previewSlots: [
      { slotId: 'top', x: 0, y: 0, width: 1, height: 1 }
    ],
    ffmpegPolicy: {
      needSideTrack: false,
      disableFrontAudio: false,
      frontTrackCandidates: [CameraPosition.FRONT],
      backTrackCandidates: [CameraPosition.FRONT],
      sideTrackCandidates: [],
      alignSideByFrontTimeline: false,
      ignoreNativeTrackSelection: true
    }
  }
}

export function isTemplateId(value: string): boolean {
  return value === TemplateId.T1 || value === TemplateId.T2 || value === TemplateId.T3 || value === TemplateId.T4 || value === TemplateId.T5
}

export function normalizeTemplateIdValue(value: string): TemplateId {
  if (isTemplateId(value)) {
    return value as TemplateId
  }
  return DEFAULT_TEMPLATE_ID
}

export function resolveTemplateDefinition(value: string): TemplateDefinition {
  const templateId = normalizeTemplateIdValue(value)
  return TEMPLATE_DEFINITION_MAP[templateId]
}

export function listTemplateDefinitions(): Array<TemplateDefinition> {
  return [
    TEMPLATE_DEFINITION_MAP[TemplateId.T1],
    TEMPLATE_DEFINITION_MAP[TemplateId.T2],
    TEMPLATE_DEFINITION_MAP[TemplateId.T3],
    TEMPLATE_DEFINITION_MAP[TemplateId.T4],
    TEMPLATE_DEFINITION_MAP[TemplateId.T5]
  ]
}

export interface PlaybackState {
  playheadMs: number
  rangeStartMs: number
  rangeEndMs: number
  speedLabel: string
  muted: boolean
}

export interface PrivacyState {
  hideSpeed: boolean
  hideGps: boolean
  hideTime: boolean
  hideVin: boolean
}

export interface BrandState {
  watermarkEnabled: boolean
}

export interface EditorUiState {
  drawerExpanded: boolean
  exporting: boolean
  exportStatus: string
}

export interface EditorState {
  sessionId: string
  trip: Trip
  selectedTemplateId: TemplateId
  playback: PlaybackState
  privacy: PrivacyState
  brand: BrandState
  ui: EditorUiState
}

export interface ExportSnapshot {
  sessionId: string
  createdAt: number
  trip: Trip
  selectedTemplateId: TemplateId
  playback: PlaybackState
  privacy: PrivacyState
  brand: BrandState
}

function emptyTrack(camera: CameraPosition): CameraTrack {
  return { camera: camera, segments: [] }
}

export function toCameraPosition(camera: string): CameraPosition {
  if (camera === 'Front') {
    return CameraPosition.FRONT
  }
  if (camera === 'Back') {
    return CameraPosition.REAR
  }
  if (camera === 'Left') {
    return CameraPosition.LEFT
  }
  if (camera === 'Right') {
    return CameraPosition.RIGHT
  }
  if (camera === 'LeftFront') {
    return CameraPosition.LEFT_FRONT
  }
  if (camera === 'RightFront') {
    return CameraPosition.RIGHT_FRONT
  }
  return CameraPosition.FRONT
}

export function toLegacyCamera(camera: CameraPosition): string {
  if (camera === CameraPosition.FRONT) {
    return 'Front'
  }
  if (camera === CameraPosition.REAR) {
    return 'Back'
  }
  if (camera === CameraPosition.LEFT) {
    return 'Left'
  }
  if (camera === CameraPosition.RIGHT) {
    return 'Right'
  }
  if (camera === CameraPosition.LEFT_FRONT) {
    return 'LeftFront'
  }
  return 'RightFront'
}

function toTemplateId(value: string): TemplateId {
  return normalizeTemplateIdValue(value)
}

export function tripFromSnapshot(snapshot: TripSnapshot): Trip {
  const tracks: Record<CameraPosition, CameraTrack> = {
    [CameraPosition.FRONT]: emptyTrack(CameraPosition.FRONT),
    [CameraPosition.REAR]: emptyTrack(CameraPosition.REAR),
    [CameraPosition.LEFT]: emptyTrack(CameraPosition.LEFT),
    [CameraPosition.RIGHT]: emptyTrack(CameraPosition.RIGHT),
    [CameraPosition.LEFT_FRONT]: emptyTrack(CameraPosition.LEFT_FRONT),
    [CameraPosition.RIGHT_FRONT]: emptyTrack(CameraPosition.RIGHT_FRONT)
  }
  snapshot.clips
    .filter((clip: DvrMeta) => clip.uri.length > 0)
    .sort((a: DvrMeta, b: DvrMeta) => a.timestamp - b.timestamp)
    .forEach((clip: DvrMeta, index: number) => {
      const camera = toCameraPosition(clip.camera)
      const segment: ClipSegment = {
        clipId: `${snapshot.id}_${camera}_${clip.timestamp}_${index}`,
        camera: camera,
        uri: clip.uri,
        timestampMs: clip.timestamp,
        durationSec: 60
      }
      tracks[camera].segments.push(segment)
    })
  return {
    tripId: snapshot.id,
    title: snapshot.tripTitle,
    rangeText: snapshot.tripRange,
    durationSec: snapshot.durationSec,
    tracks: tracks,
    startTs: snapshot.startTs,
    endTs: snapshot.endTs
  }
}

export function createEditorStateFromSnapshot(
  snapshot: TripSnapshot,
  sessionId: string,
  templateId: string,
  speedLabel: string,
  muted: boolean,
  watermarkEnabled: boolean,
  hideSpeed: boolean,
  hideGps: boolean,
  hideVin: boolean,
  drawerExpanded: boolean,
  exportStatus: string
): EditorState {
  const trip = tripFromSnapshot(snapshot)
  const endMs = Math.max(0, trip.durationSec * 1000)
  return {
    sessionId: sessionId,
    trip: trip,
    selectedTemplateId: toTemplateId(templateId),
    playback: {
      playheadMs: 0,
      rangeStartMs: 0,
      rangeEndMs: endMs,
      speedLabel: speedLabel,
      muted: muted
    },
    privacy: {
      hideSpeed: hideSpeed,
      hideGps: hideGps,
      hideTime: hideGps,
      hideVin: hideVin
    },
    brand: {
      watermarkEnabled: watermarkEnabled
    },
    ui: {
      drawerExpanded: drawerExpanded,
      exporting: false,
      exportStatus: exportStatus
    }
  }
}

export function deepCloneExportSnapshot(state: EditorState): ExportSnapshot {
  const raw = JSON.parse(JSON.stringify({
    sessionId: state.sessionId,
    createdAt: Date.now(),
    trip: state.trip,
    selectedTemplateId: state.selectedTemplateId,
    playback: state.playback,
    privacy: state.privacy,
    brand: state.brand
  })) as ExportSnapshot
  return raw
}
