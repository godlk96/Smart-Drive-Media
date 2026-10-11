export interface NativeExportPipelineRequest {
  frontUris: Array<string>
  backUris: Array<string>
  sideUris: Array<string>
  templateId: string
  expectedDurationSec: number
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

export const runExportPipeline: (payload: NativeExportPipelineRequest) => NativeExportPipelineResult
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

export interface NativeComposeRequest {
  frontUris: Array<string>
  backUris: Array<string>
  frontIndexes: Array<number>
}

export const getCoreApiVersion: () => string
export const parseDvrFileName: (name: string, uri: string) => NativeDvrMeta | null
export const buildTimeline: (camerasCsv: string) => Array<NativeTimelineTrack>
export const mergeTimeline: (timelineCsv: string) => Array<NativeTimelineTrack>
export const buildComposeRequest: (clipsCsv: string, fileName: string, outputPath: string, flags: string) => NativeComposeRequest
