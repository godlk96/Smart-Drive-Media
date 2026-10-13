import { TimelineTrackModel } from './AppState'



export class DvrMeta {
  fileName: string = ''
  uri: string = ''
  date: string = ''
  time: string = ''
  camera: string = ''
  timestamp: number = 0
}

export class TripSnapshot {
  id: string = ''
  title: string = ''
  subtitle: string = ''
  durationSec: number = 60
  tripTitle: string = ''
  tripRange: string = ''
  previewUri: string = ''
  previewFrameUri: string = ''
  previewCamera: string = ''
  clips: Array<DvrMeta> = []
  timeline: Array<TimelineTrackModel> = []
  startTs: number = 0
  endTs: number = 0
}

export class PreviewSource {
  uri: string = ''
  frameUri: string = ''
  camera: string = ''
}

export class ExportComposeRequest {
  fileName: string = ''
  outputPath: string = ''
  preferredMode: string = 'A_FFMPEG'
  frontUris: Array<string> = []
  backUris: Array<string> = []
  sideUris: Array<string> = []
  expectedDurationSec: number = 0
  rangeStartMs: number = 0
  rangeEndMs: number = 0
  templateId: string = 'T2'
  speedLabel: string = '1.0X'
  muted: boolean = false
  watermarkEnabled: boolean = true
}
