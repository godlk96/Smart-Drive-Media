import { EditorStateModel, PreviewSlotModel } from '../model/AppState'
import { normalizeCameraNameById } from '../constants/AppConstants'
import { TemplateId } from '../model/Models'
import { DvrMeta, TripSnapshot } from '../model/TripModels'
import { GlobalTimelineManager } from '../media/GlobalTimelineManager'
import { PingPongTrackController, TrackSegmentSource } from '../media/PingPongTrackController'
import { PingPongTrackView } from './PingPongTrackView'
import { debugLog } from '../utils/Logger'

interface LayoutSlotDefinition {
  id: string
  camera: string
  x: number
  y: number
  width: number
  height: number
  zoomX: number
}

interface TrackRenderItem {
  key: string
  camera: string
  x: number
  y: number
  width: number
  height: number
  zoomX: number
  hasSource: boolean
  privacyMasks: Array<PreviewMaskRect>
  controller: PingPongTrackController
}

interface PreviewMaskRect {
  key: string
  x: number
  y: number
  width: number
  height: number
}

@Component
export struct EditorPreviewArea {
  @Prop @Watch('onTemplateOrTripChanged') editorState: EditorStateModel
  @Prop @Watch('onTemplateOrTripChanged') tripSnapshot: TripSnapshot = new TripSnapshot()
  @Prop @Watch('onTemplateSwitchingChanged') isTemplateSwitching: boolean = false
  @Prop renderVersion: number = 0
  @Prop @Watch('onPlayingChanged') playing: boolean
  @Prop @Watch('onSeekTokenChanged') seekToken: number
  @Prop @Watch('onSwitchTaskIdChanged') switchTaskId: number
  @Prop playheadMs: number
  @Prop seekBlocked: boolean = false
  @Prop @Watch('onMutedChanged') muted: boolean
  @Prop @Watch('onSpeedLabelChanged') speedLabel: string
  onPlayheadChanged?: (playheadMs: number) => void
  onPlaybackEnded?: () => void
  onTemplateSwitchStageReady?: (taskId: number, stage: string) => void
  onRebuildReady?: (version: number) => void

  @State private trackItems: Array<TrackRenderItem> = []
  private manager?: GlobalTimelineManager
  private rebuildQueue: Promise<void> = Promise.resolve()
  private rebuildScheduled: boolean = false
  private rebuildPending: boolean = false
  private lastRebuildKey: string = ''
  private rebuildEpoch: number = 0
  private disposed: boolean = false
  private pendingSurfaceTrackKeys: Array<string> = []
  private readySurfaceTrackKeys: Array<string> = []
  private surfaceReadyResolve?: () => void
  private surfaceReadyTimer: number = -1

  private readonly sourceAspectRatio: number = 16 / 9
  private readonly autoSeekToleranceMs: number = 1000

  aboutToAppear(): void {
    this.disposed = false
    this.requestRebuild(true)
  }

  aboutToDisappear(): void {
    this.disposed = true
    this.rebuildEpoch += 1
    this.rebuildPending = false
    this.rebuildScheduled = false
    this.enqueueManagerTask(async () => {
      await this.releaseAll()
    })
  }

  private toPercent(value: number): string {
    const percent = Math.max(0, Math.min(100, value * 100))
    return `${percent}%`
  }

  private parseSpeedLabel(label: string): number {
    const parsed = Number(label.replace('X', ''))
    if (parsed >= 0.75 && parsed <= 2) {
      return parsed
    }
    return 1
  }

  private normalizeCameraName(camera: string): string {
    return normalizeCameraNameById(camera)
  }

  private resolveLayout(templateId: string): Array<LayoutSlotDefinition> {
    if (templateId === TemplateId.T1) {
      return [
        { id: 'top', camera: 'Front', x: 0, y: 0, width: 1, height: 0.5, zoomX: 1 },
        { id: 'bottom', camera: 'Back', x: 0, y: 0.5, width: 1, height: 0.5, zoomX: 1 }
      ]
    }
    if (templateId === TemplateId.T2) {
      return [
        { id: 'top', camera: 'Front', x: 0, y: 0, width: 1, height: 0.6667, zoomX: 1 },
        { id: 'bottomLeft', camera: 'Left', x: 0, y: 0.6667, width: 0.5, height: 0.3333, zoomX: 1 },
        { id: 'bottomRight', camera: 'Right', x: 0.5, y: 0.6667, width: 0.5, height: 0.3333, zoomX: 1 }
      ]
    }
    if (templateId === TemplateId.T3) {
      return [
        { id: 'left', camera: 'Left', x: 0, y: 0, width: 0.5, height: 1, zoomX: 1 },
        { id: 'right', camera: 'Right', x: 0.5, y: 0, width: 0.5, height: 1, zoomX: 1 }
      ]
    }
    if (templateId === TemplateId.T4) {
      return [
        { id: 'left', camera: 'LeftFront', x: 0, y: 0, width: 0.3333, height: 1, zoomX: 1.35 },
        { id: 'center', camera: 'Front', x: 0.3333, y: 0, width: 0.3334, height: 1, zoomX: 1 },
        { id: 'right', camera: 'RightFront', x: 0.6667, y: 0, width: 0.3333, height: 1, zoomX: 1.35 }
      ]
    }
    return [
      { id: 'top', camera: 'Front', x: 0, y: 0, width: 1, height: 1, zoomX: 1 }
    ]
  }

  private resolveSlotCamera(definition: LayoutSlotDefinition): string {
    const matched = this.editorState.previewSlots.find((slot: PreviewSlotModel) => slot.id === definition.id)
    if (!matched) {
      return definition.camera
    }
    return this.normalizeCameraName(matched.camera)
  }

  private isAudioMaster(templateId: string, camera: string): boolean {
    if (templateId === TemplateId.T3) {
      return false
    }
    return camera === 'Front'
  }

  private getSnapshotBaseTimestamp(snapshot: TripSnapshot): number {
    if (snapshot.startTs > 0) {
      return snapshot.startTs
    }
    const timestamps = snapshot.clips.map((item: DvrMeta) => item.timestamp).filter((value: number) => value > 0)
    if (timestamps.length === 0) {
      return 0
    }
    return Math.min(...timestamps)
  }

  private buildFrontPrivacyMasksBySlot(slotWidth: number, slotHeight: number): Array<PreviewMaskRect> {
    if (slotWidth <= 0 || slotHeight <= 0) {
      return []
    }
    const masks: Array<PreviewMaskRect> = []
    if (this.editorState.hideSpeed) {
      masks.push({ key: 'speed', x: 0.05, y: 0.9, width: 0.12, height: 0.08 })
    }
    if (this.editorState.hideVin) {
      masks.push({ key: 'vin', x: 0.28, y: 0.9, width: 0.24, height: 0.08 })
    }
    if (this.editorState.hideTime ?? this.editorState.hideGps) {
      masks.push({ key: 'time', x: 0.58, y: 0.9, width: 0.34, height: 0.08 })
    }
    if (masks.length === 0) {
      return []
    }
    const containerAspect = slotWidth / slotHeight
    let contentWidth = 1
    let contentHeight = 1
    let contentOffsetX = 0
    let contentOffsetY = 0
    if (containerAspect > this.sourceAspectRatio) {
      contentWidth = this.sourceAspectRatio / containerAspect
      contentOffsetX = (1 - contentWidth) / 2
    } else if (containerAspect < this.sourceAspectRatio) {
      contentHeight = containerAspect / this.sourceAspectRatio
      contentOffsetY = (1 - contentHeight) / 2
    }
    return masks.map((mask: PreviewMaskRect) => {
      const mappedX = contentOffsetX + mask.x * contentWidth
      const mappedY = contentOffsetY + mask.y * contentHeight
      const mappedWidth = mask.width * contentWidth
      const mappedHeight = mask.height * contentHeight
      const mappedMask: PreviewMaskRect = {
        key: mask.key,
        x: Math.max(0, Math.min(1, mappedX)),
        y: Math.max(0, Math.min(1, mappedY)),
        width: Math.max(0, Math.min(1, mappedWidth)),
        height: Math.max(0, Math.min(1, mappedHeight))
      }
      return mappedMask
    })
  }

  private buildTrackSegments(snapshot: TripSnapshot, camera: string): Array<TrackSegmentSource> {
    const normalized = this.normalizeCameraName(camera)
    const clips = snapshot.clips
      .filter((item: DvrMeta) => this.normalizeCameraName(item.camera) === normalized && item.uri.length > 0)
      .sort((a: DvrMeta, b: DvrMeta) => a.timestamp - b.timestamp)
    if (clips.length === 0) {
      return []
    }
    const baseTs = this.getSnapshotBaseTimestamp(snapshot)
    const totalMs = Math.max(0, this.editorState.totalDurationSec * 1000)
    const segments: Array<TrackSegmentSource> = []
    for (let i = 0; i < clips.length; i++) {
      const current = clips[i]
      const next = i + 1 < clips.length ? clips[i + 1] : undefined
      const startMs = Math.max(0, current.timestamp - baseTs)
      let durationMs = 60000
      if (next) {
        durationMs = Math.max(1000, next.timestamp - current.timestamp)
      } else if (totalMs > startMs) {
        durationMs = Math.max(1000, totalMs - startMs)
      }
      segments.push({
        uri: current.uri,
        startMs,
        durationMs
      })
    }
    return segments
  }

  private buildRebuildKey(): string {
    const clips = this.tripSnapshot.clips
    const firstTs = clips.length > 0 ? clips[0].timestamp : 0
    const lastTs = clips.length > 0 ? clips[clips.length - 1].timestamp : 0
    return `${this.editorState.tripId}_${this.editorState.activeTemplateId}_${this.switchTaskId}_${clips.length}_${firstTs}_${lastTs}`
  }

  private enqueueManagerTask(task: () => Promise<void>, contextTaskId: number = this.switchTaskId): void {
    this.rebuildQueue = this.rebuildQueue.then(task).catch((error: Object) => {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('EditorPreviewArea', `manager task failed: ${message}`)
      if (contextTaskId > 0 && this.switchTaskId === contextTaskId && this.onTemplateSwitchStageReady) {
        this.onTemplateSwitchStageReady(contextTaskId, 'failed')
      }
    })
  }

  private requestRebuild(force: boolean): void {
    const key = this.buildRebuildKey()
    if (!force && key === this.lastRebuildKey) {
      return
    }
    this.lastRebuildKey = key
    this.rebuildEpoch += 1
    this.rebuildPending = true
    this.rebuild()
  }

  private rebuild(): void {
    const currentTaskId = this.switchTaskId
    this.enqueueManagerTask(async () => {
      if (this.disposed) {
        await this.releaseAll()
        return
      }
      this.rebuildEpoch += 1
      const currentEpoch = this.rebuildEpoch
      await this.releaseAll()
      if (this.disposed || currentEpoch !== this.rebuildEpoch) {
        return
      }
      const snapshot = this.tripSnapshot
      const manager = new GlobalTimelineManager()
      manager.setDuration(this.editorState.totalDurationSec * 1000)
      manager.setCallbacks(
        (globalMs: number) => {
          if (this.disposed || currentEpoch !== this.rebuildEpoch || !this.onPlayheadChanged) {
            return
          }
          this.onPlayheadChanged(globalMs)
        },
        undefined,
        () => {
          if (this.disposed || currentEpoch !== this.rebuildEpoch || !this.onPlaybackEnded) {
            return
          }
          this.onPlaybackEnded()
        }
      )
      const definitions = this.resolveLayout(this.editorState.activeTemplateId)
      const renderItems: Array<TrackRenderItem> = []
      for (const definition of definitions) {
        if (this.disposed || currentEpoch !== this.rebuildEpoch) {
          await manager.release()
          return
        }
        const camera = this.resolveSlotCamera(definition)
        const trackSegments = snapshot.clips.length > 0 ? this.buildTrackSegments(snapshot, camera) : []
        const controller = new PingPongTrackController(
          `${this.editorState.tripId}_${this.editorState.activeTemplateId}_${this.switchTaskId}_${definition.id}`,
          camera,
          this.isAudioMaster(this.editorState.activeTemplateId, camera)
        )
        controller.bindSegments(trackSegments)
        manager.registerTrack(controller)
        const hasSource = trackSegments.length > 0
        renderItems.push({
          key: `${this.editorState.activeTemplateId}_${this.switchTaskId}_${definition.id}_${camera}`,
          camera,
          x: definition.x,
          y: definition.y,
          width: definition.width,
          height: definition.height,
          zoomX: definition.zoomX,
          hasSource,
          privacyMasks: hasSource && camera === 'Front'
            ? this.buildFrontPrivacyMasksBySlot(definition.width, definition.height)
            : [],
          controller
        })
      }
      if (this.disposed || currentEpoch !== this.rebuildEpoch) {
        await manager.release()
        return
      }
      this.manager = manager
      this.trackItems = renderItems
      this.startSurfaceHandshake(renderItems)
      await this.waitSurfaceHandshake(1800)
      if (this.disposed || currentEpoch !== this.rebuildEpoch) {
        return
      }
      await manager.setMuted(this.muted)
      await manager.setPlaybackRate(this.parseSpeedLabel(this.speedLabel))
      await manager.seek(this.playheadMs)
      if (this.playing) {
        await manager.play()
        this.notifyTemplateSwitchStageReady(currentTaskId, 'playing')
      } else {
        await manager.pause()
        this.notifyTemplateSwitchStageReady(currentTaskId, 'prepared')
      }
      if (this.onRebuildReady) {
        this.onRebuildReady(this.renderVersion)
      }
      debugLog('EditorPreviewArea', `rebuild done, template=${this.editorState.activeTemplateId}, tracks=${renderItems.length}`)
    }, currentTaskId)
  }

  private notifyTemplateSwitchStageReady(taskId: number, stage: string): void {
    if (taskId <= 0 || taskId !== this.switchTaskId || !this.onTemplateSwitchStageReady) {
      return
    }
    this.onTemplateSwitchStageReady(taskId, stage)
  }

  private clearSurfaceReadyTimer(): void {
    if (this.surfaceReadyTimer < 0) {
      return
    }
    clearTimeout(this.surfaceReadyTimer)
    this.surfaceReadyTimer = -1
  }

  private startSurfaceHandshake(renderItems: Array<TrackRenderItem>): void {
    this.clearSurfaceReadyTimer()
    this.pendingSurfaceTrackKeys = renderItems.filter((item: TrackRenderItem) => item.hasSource).map((item: TrackRenderItem) => item.key)
    this.readySurfaceTrackKeys = []
    this.surfaceReadyResolve = undefined
  }

  private isAllSurfaceReady(): boolean {
    return this.pendingSurfaceTrackKeys.length === this.readySurfaceTrackKeys.length
  }

  private markTrackSurfaceReady(trackKey: string): void {
    if (!this.pendingSurfaceTrackKeys.some((item: string) => item === trackKey)) {
      return
    }
    if (this.readySurfaceTrackKeys.some((item: string) => item === trackKey)) {
      return
    }
    this.readySurfaceTrackKeys.push(trackKey)
    if (!this.surfaceReadyResolve || !this.isAllSurfaceReady()) {
      return
    }
    const resolve = this.surfaceReadyResolve
    this.surfaceReadyResolve = undefined
    this.clearSurfaceReadyTimer()
    resolve()
  }

  private waitSurfaceHandshake(timeoutMs: number): Promise<void> {
    if (this.pendingSurfaceTrackKeys.length === 0 || this.isAllSurfaceReady()) {
      return Promise.resolve()
    }
    return new Promise((resolve) => {
      this.surfaceReadyResolve = resolve
      this.clearSurfaceReadyTimer()
      this.surfaceReadyTimer = setTimeout(() => {
        if (!this.surfaceReadyResolve) {
          return
        }
        const done = this.surfaceReadyResolve
        this.surfaceReadyResolve = undefined
        this.surfaceReadyTimer = -1
        done()
      }, timeoutMs)
    })
  }

  private async releaseAll(): Promise<void> {
    this.clearSurfaceReadyTimer()
    this.pendingSurfaceTrackKeys = []
    this.readySurfaceTrackKeys = []
    this.surfaceReadyResolve = undefined
    if (this.manager) {
      await this.manager.release()
      this.manager = undefined
    }
    this.trackItems = []
  }

  private onTemplateOrTripChanged(): void {
    this.requestRebuild(false)
  }

  private onTemplateSwitchingChanged(): void {
    if (!this.isTemplateSwitching) {
      return
    }
    const currentTaskId = this.switchTaskId
    this.enqueueManagerTask(async () => {
      if (this.disposed) {
        return
      }
      if (this.manager) {
        await this.manager.pause()
      }
      await this.releaseAll()
      this.notifyTemplateSwitchStageReady(currentTaskId, 'released')
    }, currentTaskId)
  }

  private onSwitchTaskIdChanged(): void {
    if (this.switchTaskId <= 0 || this.isTemplateSwitching) {
      return
    }
    this.requestRebuild(false)
  }

  private onPlayingChanged(): void {
    const currentTaskId = this.switchTaskId
    this.enqueueManagerTask(async () => {
      if (this.disposed || currentTaskId !== this.switchTaskId || !this.manager) {
        return
      }
      if (this.playing) {
        await this.manager.play()
        return
      }
      await this.manager.pause()
    })
  }

  private onSeekTokenChanged(): void {
    const currentTaskId = this.switchTaskId
    this.enqueueManagerTask(async () => {
      if (this.disposed || currentTaskId !== this.switchTaskId || !this.manager) {
        return
      }
      if (this.seekBlocked) {
        return
      }
      if (this.manager.getPlaybackState() === 'playing') {
        const driftMs = Math.abs(this.playheadMs - this.manager.getGlobalPlayheadMs())
        if (driftMs < this.autoSeekToleranceMs) {
          return
        }
      }
      await this.manager.seek(this.playheadMs)
    })
  }

  private onMutedChanged(): void {
    const currentTaskId = this.switchTaskId
    this.enqueueManagerTask(async () => {
      if (this.disposed || currentTaskId !== this.switchTaskId || !this.manager) {
        return
      }
      await this.manager.setMuted(this.muted)
    })
  }

  private onSpeedLabelChanged(): void {
    const currentTaskId = this.switchTaskId
    this.enqueueManagerTask(async () => {
      if (this.disposed || currentTaskId !== this.switchTaskId || !this.manager) {
        return
      }
      await this.manager.setPlaybackRate(this.parseSpeedLabel(this.speedLabel))
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      ForEach(this.trackItems, (item: TrackRenderItem) => {
        Stack({ alignContent: Alignment.Center }) {
          if (item.hasSource) {
            PingPongTrackView({
              controller: item.controller,
              onSurfaceReady: () => this.markTrackSurfaceReady(item.key)
            })
              .width(item.zoomX > 1 ? `${item.zoomX * 100}%` : '100%')
              .height('100%')
          } else {
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor('#333333')
          }
          ForEach(item.privacyMasks, (mask: PreviewMaskRect) => {
            Column()
              .width(this.toPercent(mask.width))
              .height(this.toPercent(mask.height))
              .position({ x: this.toPercent(mask.x), y: this.toPercent(mask.y) })
              .backgroundColor('#000000')
          }, (mask: PreviewMaskRect) => `${item.key}_${mask.key}`)
        }
          .clip(true)
          .width(this.toPercent(item.width))
          .height(this.toPercent(item.height))
          .position({ x: this.toPercent(item.x), y: this.toPercent(item.y) })
      }, (item: TrackRenderItem) => item.key)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }
}
