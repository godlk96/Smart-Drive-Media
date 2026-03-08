import { TimelineTrackModel } from './AppState'

export const CAMERA_ORDER: Array<string> = ['Front', 'Back', 'Left', 'Right', 'LeftFront', 'RightFront']

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
  previewCamera: string = ''
  clips: Array<DvrMeta> = []
  timeline: Array<TimelineTrackModel> = []
  startTs: number = 0
  endTs: number = 0
}

export class PreviewSource {
  uri: string = ''
  camera: string = ''
}

export class ExportComposeRequest {
  fileName: string = ''
  outputPath: string = ''
  preferredMode: string = 'A_FFMPEG'
  frontUris: Array<string> = []
  backUris: Array<string> = []
  expectedDurationSec: number = 0
  hideSpeed: boolean = true
  hideGps: boolean = true
  hideVin: boolean = true
}
