/**
 * (入口) 统一导出所有模块，相当于对外暴露的 API 列表。
 */
export { TripRepository } from './model/tripRepository.js'
export { ScanTarget, getDefaultScanTargets } from './model/scanTargets.js'
export { CameraPosition, normalizeCameraPosition } from './model/types.js'
export { parseDvrFile, isDvrCandidate } from './logic/fileParser.js'
export { aggregateTrips, DEFAULT_GAP_THRESHOLD_MS } from './logic/tripAggregator.js'
export { VirtualClip, assembleVirtualClip } from './logic/virtualTimeline.js'
export { TaskRunner } from './logic/taskRunner.js'
export { ScannerService } from './logic/scannerService.js'
export { PassiveImportController } from './logic/passiveImportController.js'
export { MultiTrackEditorSession, SYNC_DRIFT_THRESHOLD_MS } from './logic/multiTrackEditorSession.js'
export { Orientation, getEditorLayout } from './logic/editorLayout.js'
export { TripLibraryViewModel } from './viewmodel/tripLibraryViewModel.js'
export { createDefaultPrivacyConfig, buildPrivacyPlan } from './logic/privacyConfig.js'
export { buildStreamCopyCommand, buildTranscodeCommand } from './logic/ffmpegBuilder.js'
export {
  FfmpegExecutor,
  parseFfmpegProgress,
  createNodeProcessRunner,
  createNodeConcatFileFactory,
  createNodeRemoveFile
} from './logic/ffmpegExecutor.js'
export { ExportMode, selectExportMode, ExportEngine } from './logic/exportEngine.js'
export { ExportJobState } from './logic/exportJobState.js'
export { MetricsTracker } from './logic/metricsTracker.js'
export { CrashReporter } from './logic/crashReporter.js'
export { StorageGuard } from './logic/storageGuard.js'
export { buildTrackFallbackPlan } from './logic/trackFallbackPlanner.js'
export { ExportStatusViewModel } from './viewmodel/exportStatusViewModel.js'
export { runDesignAudit } from './logic/designAudit.js'
export { runSecurityAudit } from './logic/securityAudit.js'
export { ScreenRouter } from './ui/screenRouter.js'
export { TripLibraryScreenAdapter } from './ui/tripLibraryScreenAdapter.js'
export { EditorScreenAdapter } from './ui/editorScreenAdapter.js'
export { bindLibraryScreen, bindEditorScreen } from './ui/screenBindings.js'
export { HarmonyCoreBridge } from './harmony/coreBridge.js'
