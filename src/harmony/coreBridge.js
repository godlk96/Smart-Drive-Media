import { TripRepository } from '../model/tripRepository.js'
import { TaskRunner } from '../logic/taskRunner.js'
import { ScannerService } from '../logic/scannerService.js'
import { PassiveImportController } from '../logic/passiveImportController.js'
import { TripLibraryViewModel } from '../viewmodel/tripLibraryViewModel.js'
import { MultiTrackEditorSession } from '../logic/multiTrackEditorSession.js'
import { ExportStatusViewModel } from '../viewmodel/exportStatusViewModel.js'
import { ExportJobState } from '../logic/exportJobState.js'
import { createDefaultPrivacyConfig } from '../logic/privacyConfig.js'
import { ExportEngine } from '../logic/exportEngine.js'
import {
  FfmpegExecutor,
  createNodeConcatFileFactory,
  createNodeProcessRunner,
  createNodeRemoveFile
} from '../logic/ffmpegExecutor.js'
import { runSecurityAudit } from '../logic/securityAudit.js'
import { ScreenRouter } from '../ui/screenRouter.js'
import { TripLibraryScreenAdapter } from '../ui/tripLibraryScreenAdapter.js'
import { EditorScreenAdapter } from '../ui/editorScreenAdapter.js'
import { bindLibraryScreen, bindEditorScreen } from '../ui/screenBindings.js'

const REQUIRED_PERMISSIONS = ['ohos.permission.READ_MEDIA', 'ohos.permission.READ_IMAGEVIDEO']

function buildPermissionGuide(grantedPermissions = []) {
  const granted = new Set(grantedPermissions)
  const missing = REQUIRED_PERMISSIONS.filter(name => !granted.has(name))
  return {
    missing,
    message:
      missing.length === 0
        ? ''
        : `缺少权限：${missing.join('、')}，请在系统设置中开启后重试。`
  }
}

function createEmptyLibraryState(message) {
  return {
    title: '行程库',
    cards: [],
    empty: true,
    emptyText: message,
    scanMode: 'passive'
  }
}

function createDefaultFileSource() {
  return {
    async listFiles() {
      return []
    }
  }
}

export class HarmonyCoreBridge {
  constructor({ fileSource, processingMode = 'local_only', exportExecutor } = {}) {
    this.processingMode = processingMode
    this.fileSource = fileSource ?? createDefaultFileSource()
    this.repository = new TripRepository()
    this.taskRunner = new TaskRunner()
    this.scannerService = new ScannerService({
      repository: this.repository,
      taskRunner: this.taskRunner
    })
    this.passiveImportController = new PassiveImportController({
      scannerService: this.scannerService,
      fileSource: this.fileSource
    })
    this.router = new ScreenRouter()
    this.libraryScreen = bindLibraryScreen(
      new TripLibraryScreenAdapter({
        viewModel: new TripLibraryViewModel({
          passiveImportController: this.passiveImportController
        }),
        router: this.router
      })
    )
    this.editorSession = new MultiTrackEditorSession()
    this.exportStatusViewModel = new ExportStatusViewModel({
      exportJobState: new ExportJobState()
    })
    this.editorScreen = bindEditorScreen(
      new EditorScreenAdapter({
        editorSession: this.editorSession,
        exportStatusViewModel: this.exportStatusViewModel,
        router: this.router
      })
    )
    this.exportEngine = new ExportEngine()
    this.exportExecutor =
      exportExecutor ??
      new FfmpegExecutor({
        runProcess: createNodeProcessRunner(),
        createConcatFile: createNodeConcatFileFactory(),
        removeFile: createNodeRemoveFile()
      })
    this.tripMap = new Map()
    this.privacyConfig = createDefaultPrivacyConfig()
  }

  getRequiredPermissions() {
    return [...REQUIRED_PERMISSIONS]
  }

  getRouteState() {
    return this.router.getState()
  }

  async initializeLibrary({ grantedPermissions = [] } = {}) {
    const audit = runSecurityAudit({
      processingMode: this.processingMode,
      requestedPermissions: grantedPermissions,
      privacyConfig: this.privacyConfig
    })
    if (!audit.passed) {
      const guide = buildPermissionGuide(grantedPermissions)
      return {
        ok: false,
        reason: 'permission_denied',
        audit,
        permissionGuide: guide,
        state: createEmptyLibraryState(guide.message)
      }
    }

    try {
      const state = await this.libraryScreen.initialize()
      this.tripMap = new Map(this.repository.getAllDesc().map(item => [item.id, item]))
      return {
        ok: true,
        reason: 'ready',
        audit,
        permissionGuide: buildPermissionGuide(grantedPermissions),
        state
      }
    } catch (error) {
      return {
        ok: false,
        reason: 'scan_failed',
        audit,
        permissionGuide: buildPermissionGuide(grantedPermissions),
        errorMessage: error instanceof Error ? error.message : String(error),
        state: createEmptyLibraryState('扫描失败，请稍后重试')
      }
    }
  }

  openTrip(tripId) {
    const state = this.libraryScreen.openTrip(tripId)
    const selectedTrip = this.tripMap.get(tripId)
    return {
      ok: Boolean(selectedTrip),
      routeState: state.route,
      trip: selectedTrip ?? null
    }
  }

  loadEditor(tripId) {
    const trip = this.tripMap.get(tripId)
    if (!trip) {
      return {
        ok: false,
        reason: 'trip_not_found',
        state: this.editorScreen.getState()
      }
    }
    return {
      ok: true,
      reason: 'ready',
      state: this.editorScreen.loadTrip(trip)
    }
  }

  setPrivacyConfig(nextConfig) {
    this.privacyConfig = {
      ...this.privacyConfig,
      ...nextConfig
    }
    return { ...this.privacyConfig }
  }

  seekTimeline(positionMs) {
    return this.editorScreen.seekTo(positionMs)
  }

  createExportPlan({ tripId, outputPath, hasVisualEffects = false, socialShareMode = false }) {
    const trip = this.tripMap.get(tripId)
    if (!trip) {
      return {
        ok: false,
        reason: 'trip_not_found',
        command: null
      }
    }
    const frontTrack = trip.videoTracks.find(track => track.cameraPosition === 'Front')
    const backTrack = trip.videoTracks.find(track => track.cameraPosition === 'Back')
    const frontInputFiles = frontTrack?.segments?.map(item => item.filePath) ?? []
    const backInputFiles = backTrack?.segments?.map(item => item.filePath) ?? []
    const primaryTrack = frontTrack ?? trip.videoTracks[0]
    const primaryInputFiles = primaryTrack?.segments?.map(item => item.filePath) ?? []
    const useFrontBackStack = frontInputFiles.length > 0 && backInputFiles.length > 0
    const inputFiles = useFrontBackStack ? frontInputFiles : primaryInputFiles
    if (inputFiles.length === 0) {
      return {
        ok: false,
        reason: 'empty_track',
        command: null
      }
    }
    const totalDurationSec = Math.max(
      1,
      Math.round(
        inputFiles.reduce((acc, _, index) => {
          const segmentDuration = Number(primaryTrack?.segments?.[index]?.duration ?? 60)
          return acc + (Number.isFinite(segmentDuration) ? segmentDuration : 60)
        }, 0)
      )
    )
    return {
      ok: true,
      reason: 'ready',
      totalDurationSec,
      command: this.exportEngine.createPlan({
        inputFiles,
        secondaryInputFiles: useFrontBackStack ? backInputFiles : [],
        outputPath,
        trackCount: trip.videoTracks.length,
        privacyConfig: this.privacyConfig,
        hasVisualEffects,
        socialShareMode,
        layoutMode: useFrontBackStack ? 'front_back_stack' : 'single_track'
      })
    }
  }

  async executeExport({ tripId, outputPath, hasVisualEffects = false, socialShareMode = false }) {
    const plan = this.createExportPlan({
      tripId,
      outputPath,
      hasVisualEffects,
      socialShareMode
    })
    if (!plan.ok || !plan.command) {
      return {
        ok: false,
        reason: plan.reason,
        state: this.editorScreen.getState()
      }
    }
    this.editorScreen.startExport(outputPath)
    try {
      await this.exportExecutor.execute(plan.command, {
        totalDurationSec: plan.totalDurationSec,
        onProgress: progress => {
          this.editorScreen.updateExportProgress(progress)
        },
        onLog: () => {}
      })
      return {
        ok: true,
        reason: 'success',
        state: this.editorScreen.finishExportSuccess()
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      return {
        ok: false,
        reason: 'execute_failed',
        errorMessage: message,
        state: this.editorScreen.finishExportFail(message)
      }
    }
  }
}
