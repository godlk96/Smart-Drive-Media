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
  T4 = 'T4'
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

export interface TemplateDefinition {
  templateId: TemplateId
  requiredCameras: Array<CameraPosition>
  optionalCameras: Array<CameraPosition>
  slotBindings: Array<TemplateSlotBinding>
  ffmpegPolicy: string
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

export interface EditorAction {
  type: string
  payload?: Object
}

interface TextPayload {
  value: string
}

interface NumberPayload {
  value: number
}

interface BooleanPayload {
  value: boolean
}

function emptyTrack(camera: CameraPosition): CameraTrack {
  return { camera: camera, segments: [] }
}

function clonePlayback(source: PlaybackState): PlaybackState {
  return {
    playheadMs: source.playheadMs,
    rangeStartMs: source.rangeStartMs,
    rangeEndMs: source.rangeEndMs,
    speedLabel: source.speedLabel,
    muted: source.muted
  }
}

function clonePrivacy(source: PrivacyState): PrivacyState {
  return {
    hideSpeed: source.hideSpeed,
    hideGps: source.hideGps,
    hideVin: source.hideVin
  }
}

function cloneBrand(source: BrandState): BrandState {
  return {
    watermarkEnabled: source.watermarkEnabled
  }
}

function cloneUi(source: EditorUiState): EditorUiState {
  return {
    drawerExpanded: source.drawerExpanded,
    exporting: source.exporting,
    exportStatus: source.exportStatus
  }
}

function cloneEditorState(state: EditorState): EditorState {
  return {
    sessionId: state.sessionId,
    trip: state.trip,
    selectedTemplateId: state.selectedTemplateId,
    playback: clonePlayback(state.playback),
    privacy: clonePrivacy(state.privacy),
    brand: cloneBrand(state.brand),
    ui: cloneUi(state.ui)
  }
}

function toCameraPosition(camera: string): CameraPosition {
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

function toTemplateId(value: string): TemplateId {
  if (value === TemplateId.T1 || value === TemplateId.T2 || value === TemplateId.T3 || value === TemplateId.T4) {
    return value
  }
  return TemplateId.T2
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

export function reduceEditorState(state: EditorState, action: EditorAction): EditorState {
  const next = cloneEditorState(state)
  if (action.type === 'SET_TEMPLATE') {
    const payload = action.payload as TextPayload
    next.selectedTemplateId = toTemplateId(payload?.value ?? TemplateId.T2)
    return next
  }
  if (action.type === 'SET_PLAYHEAD') {
    const payload = action.payload as NumberPayload
    const playhead = Math.max(0, Math.min(payload?.value ?? 0, state.trip.durationSec * 1000))
    next.playback.playheadMs = playhead
    return next
  }
  if (action.type === 'SET_RANGE') {
    const payload = action.payload as Array<number>
    const max = state.trip.durationSec * 1000
    const rawStart = Math.max(0, Math.min(payload[0] ?? 0, max))
    const rawEnd = Math.max(0, Math.min(payload[1] ?? max, max))
    const start = Math.min(rawStart, rawEnd)
    const end = Math.max(rawStart, rawEnd)
    const playhead = Math.max(start, Math.min(state.playback.playheadMs, end))
    next.playback.rangeStartMs = start
    next.playback.rangeEndMs = end
    next.playback.playheadMs = playhead
    return next
  }
  if (action.type === 'SET_SPEED') {
    const payload = action.payload as TextPayload
    next.playback.speedLabel = payload?.value ?? '1.0X'
    return next
  }
  if (action.type === 'TOGGLE_MUTED') {
    next.playback.muted = !state.playback.muted
    return next
  }
  if (action.type === 'TOGGLE_WATERMARK') {
    next.brand.watermarkEnabled = !state.brand.watermarkEnabled
    return next
  }
  if (action.type === 'TOGGLE_PRIVACY') {
    const payload = action.payload as TextPayload
    const key = payload?.value ?? ''
    if (key === 'speed') {
      next.privacy.hideSpeed = !state.privacy.hideSpeed
      return next
    }
    if (key === 'gps') {
      next.privacy.hideGps = !state.privacy.hideGps
      return next
    }
    if (key === 'vin') {
      next.privacy.hideVin = !state.privacy.hideVin
      return next
    }
    return state
  }
  if (action.type === 'SET_EXPORT_STATUS') {
    const payload = action.payload as TextPayload
    next.ui.exportStatus = payload?.value ?? state.ui.exportStatus
    return next
  }
  if (action.type === 'SET_EXPORTING') {
    const payload = action.payload as BooleanPayload
    next.ui.exporting = payload?.value ?? state.ui.exporting
    return next
  }
  if (action.type === 'SET_DRAWER') {
    const payload = action.payload as BooleanPayload
    next.ui.drawerExpanded = payload?.value ?? state.ui.drawerExpanded
    return next
  }
  return state
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
