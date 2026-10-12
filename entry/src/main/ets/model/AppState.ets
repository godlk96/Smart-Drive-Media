export interface TripCardModel {
  id: string
  title: string
  subtitle: string
  durationText: string
  durationSec: number
  previewUri: string
  previewFrameUri: string
  previewCamera: string
}

export interface LibraryStateModel {
  title: string
  cards: Array<TripCardModel>
  empty: boolean
  emptyText: string
  permissionTip: string
}

export interface TimelineTrackModel {
  cameraPosition: string
  segmentCount: number
  degraded: boolean
}

export interface EditorLayerModel {
  name: string
  heightRatio: number
}

export interface TimelineMarkerModel {
  positionSec: number
  style: string
}

export interface TemplateCardModel {
  id: string
  title: string
  subtitle: string
}

export interface PreviewSlotModel {
  id: string
  camera: string
  uri: string
  nextUri?: string // Added for seamless double-buffering
  x: number
  y: number
  width: number
  height: number
}

export interface EditorStateModel {
  tripId: string
  tripTitle: string
  timeRange: string
  previewUri: string
  previewCamera: string
  playheadSec: number
  canPlayPrev: boolean
  canPlayNext: boolean
  currentClipIndex: number
  currentClipTotal: number
  playheadText: string
  totalDurationSec: number
  timeline: Array<TimelineTrackModel>
  layers: Array<EditorLayerModel>
  selectionStartSec: number
  selectionEndSec: number
  boundaryMarkers: Array<TimelineMarkerModel>
  templateCards: Array<TemplateCardModel>
  previewSlots: Array<PreviewSlotModel>
  activeTemplateId: string
  drawerExpanded: boolean
  speedLabel: string
  muted: boolean
  watermarkEnabled: boolean
  hideSpeed: boolean
  hideGps: boolean
  hideTime: boolean
  hideVin: boolean
  exportStatusText: string
}
