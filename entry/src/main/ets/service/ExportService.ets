import { DvrMeta, ExportComposeRequest } from '../model/TripModels'
import smartdriveExporter from 'libsmartdrive_exporter.so'
import { ensureCoreApiContract } from './CoreApiContract'

class NativeComposeRequestResult {
  frontUris: Array<string> = []
  backUris: Array<string> = []
}

export function buildComposeRequestByService(
  clips: Array<DvrMeta>,
  fileName: string,
  outputPath: string,
  expectedDurationSec: number,
  hideSpeed: boolean,
  hideGps: boolean,
  hideVin: boolean
): ExportComposeRequest {
  ensureCoreApiContract()
  const request = new ExportComposeRequest()
  request.fileName = fileName
  request.outputPath = outputPath
  request.expectedDurationSec = expectedDurationSec
  request.hideSpeed = hideSpeed
  request.hideGps = hideGps
  request.hideVin = hideVin
  const nativeBuild = smartdriveExporter.buildComposeRequest as ((
    clipsCsv: string,
    fileName: string,
    outputPath: string,
    flags: string
  ) => NativeComposeRequestResult) | undefined
  if (typeof nativeBuild !== 'function') {
    throw new Error('smartdrive_exporter.buildComposeRequest 未实现')
  }
  const clipsCsv = clips.map((item: DvrMeta) => `${item.camera}@${item.timestamp}@${item.uri}`).join(',')
  const flags = `${hideSpeed ? 1 : 0},${hideGps ? 1 : 0},${hideVin ? 1 : 0}`
  const data = nativeBuild(clipsCsv, fileName, outputPath, flags)
  request.frontUris = data.frontUris ?? []
  request.backUris = data.backUris ?? []
  return request
}
