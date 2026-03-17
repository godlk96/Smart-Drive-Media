import { EditorStateModel, PreviewSlotModel } from '../model/AppState'
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
  controller: PingPongTrackController
}

@Component
export struct EditorPreviewArea {
  @Prop @Watch('onTemplateOrTripChanged') editorState: EditorStateModel
  @Prop @Watch('onTemplateOrTripChanged') tripSnapshot: TripSnapshot = new TripSnapshot()
  @Prop @Watch('onPlayingChanged') playing: boolean
  @Prop @Watch('onSeekTokenChanged') seekToken: number
  @Prop playheadMs: number
  @Prop @Watch('onMutedChanged') muted: boolean
  @Prop @Watch('onSpeedLabelChanged') speedLabel: string
  onPlayheadChanged?: (playheadMs: number) => void
  onPlaybackEnded?: () => void

  @State private trackItems: Array<TrackRenderItem> = []
  private manager?: GlobalTimelineManager
  private rebuildQueue: Promise<void> = Promise.resolve()
  private lastRebuildKey: string = ''

  aboutToAppear(): void {
    this.requestRebuild(true)
  }

  aboutToDisappear(): void {
    this.releaseAll()
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
    if (camera === 'FRONT') {
      return 'Front'
    }
    if (camera === 'REAR') {
      return 'Back'
    }
    if (camera === 'LEFT') {
      return 'Left'
    }
    if (camera === 'RIGHT') {
      return 'Right'
    }
    if (camera === 'LEFT_FRONT') {
      return 'LeftFront'
    }
    if (camera === 'RIGHT_FRONT') {
      return 'RightFront'
    }
    return camera
  }

  private resolveLayout(templateId: string): Array<LayoutSlotDefinition> {
    if (templateId === 'T1') {
      return [
        { id: 'top', camera: 'Front', x: 0, y: 0, width: 1, height: 0.5, zoomX: 1 },
        { id: 'bottom', camera: 'Back', x: 0, y: 0.5, width: 1, height: 0.5, zoomX: 1 }
      ]
    }
    if (templateId === 'T2') {
      return [
        { id: 'top', camera: 'Front', x: 0, y: 0, width: 1, height: 0.6667, zoomX: 1 },
        { id: 'bottomLeft', camera: 'Left', x: 0, y: 0.6667, width: 0.5, height: 0.3333, zoomX: 1 },
        { id: 'bottomRight', camera: 'Right', x: 0.5, y: 0.6667, width: 0.5, height: 0.3333, zoomX: 1 }
      ]
    }
    if (templateId === 'T3') {
      return [
        { id: 'left', camera: 'Left', x: 0, y: 0, width: 0.5, height: 1, zoomX: 1 },
        { id: 'right', camera: 'Right', x: 0.5, y: 0, width: 0.5, height: 1, zoomX: 1 }
      ]
    }
    if (templateId === 'T4') {
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
    if (templateId === 'T3') {
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
    return `${this.editorState.tripId}_${this.editorState.activeTemplateId}_${clips.length}_${firstTs}_${lastTs}`
  }

  private requestRebuild(force: boolean): void {
    const key = this.buildRebuildKey()
    if (!force && key === this.lastRebuildKey) {
      return
    }
    this.lastRebuildKey = key
    this.rebuild()
  }

  private rebuild(): void {
    this.rebuildQueue = this.rebuildQueue.then(async () => {
      await this.releaseAll()
      const snapshot = this.tripSnapshot
      const manager = new GlobalTimelineManager()
      manager.setDuration(this.editorState.totalDurationSec * 1000)
      manager.setCallbacks(
        (globalMs: number) => {
          if (this.onPlayheadChanged) {
            this.onPlayheadChanged(globalMs)
          }
        },
        undefined,
        () => {
          if (this.onPlaybackEnded) {
            this.onPlaybackEnded()
          }
        }
      )
      const definitions = this.resolveLayout(this.editorState.activeTemplateId)
      const renderItems: Array<TrackRenderItem> = []
      for (const definition of definitions) {
        const camera = this.resolveSlotCamera(definition)
        const trackSegments = snapshot.clips.length > 0 ? this.buildTrackSegments(snapshot, camera) : []
        const controller = new PingPongTrackController(
          `${this.editorState.tripId}_${this.editorState.activeTemplateId}_${definition.id}`,
          camera,
          this.isAudioMaster(this.editorState.activeTemplateId, camera)
        )
        controller.bindSegments(trackSegments)
        manager.registerTrack(controller)
        const hasSource = trackSegments.length > 0
        renderItems.push({
          key: `${this.editorState.activeTemplateId}_${definition.id}_${camera}`,
          camera,
          x: definition.x,
          y: definition.y,
          width: definition.width,
          height: definition.height,
          zoomX: definition.zoomX,
          hasSource,
          controller
        })
      }
      this.manager = manager
      this.trackItems = renderItems
      await manager.setMuted(this.muted)
      await manager.setPlaybackRate(this.parseSpeedLabel(this.speedLabel))
      await manager.seek(this.playheadMs)
      if (this.playing) {
        await manager.play()
      } else {
        await manager.pause()
      }
      debugLog('EditorPreviewArea', `rebuild done, template=${this.editorState.activeTemplateId}, tracks=${renderItems.length}`)
    }).catch((error: Object) => {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('EditorPreviewArea', `rebuild failed: ${message}`)
    })
  }

  private async releaseAll(): Promise<void> {
    if (this.manager) {
      await this.manager.release()
      this.manager = undefined
    }
    this.trackItems = []
  }

  private onTemplateOrTripChanged(): void {
    this.requestRebuild(false)
  }

  private onPlayingChanged(): void {
    if (!this.manager) {
      return
    }
    if (this.playing) {
      this.manager.play()
      return
    }
    this.manager.pause()
  }

  private onSeekTokenChanged(): void {
    if (!this.manager) {
      return
    }
    this.manager.seek(this.playheadMs)
  }

  private onMutedChanged(): void {
    if (!this.manager) {
      return
    }
    this.manager.setMuted(this.muted)
  }

  private onSpeedLabelChanged(): void {
    if (!this.manager) {
      return
    }
    this.manager.setPlaybackRate(this.parseSpeedLabel(this.speedLabel))
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      ForEach(this.trackItems, (item: TrackRenderItem) => {
        Stack({ alignContent: Alignment.Center }) {
          if (item.hasSource) {
            PingPongTrackView({ controller: item.controller })
              .width(item.zoomX > 1 ? `${item.zoomX * 100}%` : '100%')
              .height('100%')
          } else {
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor('#333333')
          }
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
