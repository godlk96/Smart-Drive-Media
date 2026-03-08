export interface TripCardModel {
  id: string
  title: string
  subtitle: string
  durationText: string
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

export interface EditorStateModel {
  tripId: string
  tripTitle: string
  timeRange: string
  previewUri: string
  previewCamera: string
  canPlayPrev: boolean
  canPlayNext: boolean
  currentClipIndex: number
  currentClipTotal: number
  playheadText: string
  totalDurationSec: number
  timeline: Array<TimelineTrackModel>
  hideSpeed: boolean
  hideGps: boolean
  hideVin: boolean
  exportStatusText: string
}
