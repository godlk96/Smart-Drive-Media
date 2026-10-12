export interface NativeExportPipelineRequest {
  frontUris: Array<string>
  backUris: Array<string>
  sideUris: Array<string>
  templateId: string
  expectedDurationSec: number
  startMs: number
  endMs: number
  outputPath: string
  hideSpeed: boolean
  hideVin: boolean
  hideTime: boolean
}

export interface NativeExportPipelineResult {
  code: number
  message: string
  outputPath: string
}

export const runExportPipelineAsync: (payload: NativeExportPipelineRequest) => Promise<NativeExportPipelineResult>

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
