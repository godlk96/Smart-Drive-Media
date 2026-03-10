/**
 * (出口总管) 决定导出模式。它会判断：如果不含隐私信息，就走“极速模式”；否则走“转码模式”。
 */
import { buildPrivacyPlan } from './privacyConfig.js'
import { buildStreamCopyCommand, buildTranscodeCommand } from './ffmpegBuilder.js'

function parseSpeedValue(speedLabel) {
  const speed = Number.parseFloat(String(speedLabel ?? '1.0X').replace(/x$/i, ''))
  if (!Number.isFinite(speed) || speed <= 0) {
    return 1
  }
  return speed
}

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
    trackInputs = {},
    outputPath,
    trackCount,
    privacyConfig,
    exportControls = {},
    hasVisualEffects = false,
    socialShareMode = false,
    layoutMode = 'single_track',
    templateId = 'T2'
  }) {
    const privacyPlan = buildPrivacyPlan(privacyConfig)
    const hasPrivacyMask = privacyPlan.hideSpeed || privacyPlan.hideVin || privacyPlan.hideGps
    const hasTemplateLayout = layoutMode === 'scenario_template'
    const speedValue = parseSpeedValue(exportControls.speed)
    const hasCinematicCrop = privacyPlan.cinematicCrop
    const hasTailmark = Boolean(exportControls.watermarkEnabled)
    const hasAdvancedControls = speedValue > 1 || hasTailmark || hasCinematicCrop
    const mode = selectExportMode({
      trackCount,
      hasPrivacyMask,
      hasVisualEffects: hasVisualEffects || hasTemplateLayout || hasAdvancedControls
    })

    if (mode === ExportMode.STREAM_COPY) {
      return buildStreamCopyCommand(inputFiles, outputPath)
    }
    return buildTranscodeCommand({
      inputFiles,
      secondaryInputFiles,
      outputPath,
      privacyPlan,
      exportControls,
      socialShareMode,
      layoutMode,
      templateId,
      trackInputs
    })
  }
}
