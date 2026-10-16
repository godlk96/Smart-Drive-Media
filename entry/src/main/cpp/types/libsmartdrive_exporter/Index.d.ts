export interface NativeExportSegment {
  startMs: number
  endMs: number
  speed?: number
  muted?: boolean
}

export interface NativeExportPipelineRequest {
  frontUris: Array<string>
  backUris: Array<string>
  sideUris: Array<string>
  /** T6 四机位专用第 4 路（右下 / 右后）。其余模板为空数组。 */
  side2Uris: Array<string>
  templateId: string
  expectedDurationSec: number
  startMs: number
  endMs: number
  outputPath: string
  segments?: Array<NativeExportSegment>
}

export interface NativeExportPipelineResult {
  code: number
  message: string
  outputPath: string
}

export interface NativeExportProgress {
  percent: number
  currentFrame: number
  totalFrames: number
  stage: number
}

export const runExportPipelineAsync: (payload: NativeExportPipelineRequest) => Promise<NativeExportPipelineResult>
export const getExportProgress: () => NativeExportProgress
export const cancelExport: () => boolean

export interface NativeDvrMeta {
  fileName: string
  uri: string
  date: string
  time: string
  camera: string
  timestamp: number
}

export interface NativeTimelineTrack {
  cameraPosition: string
  segmentCount: number
  degraded: boolean
}

export const getCoreApiVersion: () => string
export const parseDvrFileName: (name: string, uri: string) => NativeDvrMeta | null
export const buildTimeline: (camerasCsv: string) => Array<NativeTimelineTrack>
export const mergeTimeline: (timelineCsv: string) => Array<NativeTimelineTrack>
