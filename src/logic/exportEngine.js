/**
 * (出口总管) 决定导出模式。它会判断：如果不含隐私信息，就走“极速模式”；否则走“转码模式”。
 */
import { buildPrivacyPlan } from './privacyConfig.js'
import { buildStreamCopyCommand, buildTranscodeCommand } from './ffmpegBuilder.js'

export const ExportMode = Object.freeze({
  STREAM_COPY: 'stream_copy',
  TRANSCODE: 'transcode'
})

export function selectExportMode({
  trackCount,
  hasPrivacyMask,
  hasVisualEffects
}) {
  if (trackCount === 1 && !hasPrivacyMask && !hasVisualEffects) {
    return ExportMode.STREAM_COPY
  }
  return ExportMode.TRANSCODE
}

export class ExportEngine {
  createPlan({
    inputFiles,
    secondaryInputFiles = [],
    outputPath,
    trackCount,
    privacyConfig,
    hasVisualEffects = false,
    socialShareMode = false,
    layoutMode = 'single_track'
  }) {
    const privacyPlan = buildPrivacyPlan(privacyConfig)
    const hasPrivacyMask = privacyPlan.hideSpeed || privacyPlan.hideVin || privacyPlan.hideGps
    const mode = selectExportMode({ trackCount, hasPrivacyMask, hasVisualEffects })

    if (mode === ExportMode.STREAM_COPY) {
      return buildStreamCopyCommand(inputFiles, outputPath)
    }
    return buildTranscodeCommand({
      inputFiles,
      secondaryInputFiles,
      outputPath,
      privacyPlan,
      socialShareMode,
      layoutMode
    })
  }
}
