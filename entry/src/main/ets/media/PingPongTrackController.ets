import media from '@ohos.multimedia.media'
import fs from '@ohos.file.fs'
import { debugLog } from '../utils/Logger'

export type ActiveLayer = 'A' | 'B'

export interface TrackSegmentSource {
  uri: string
  startMs: number
  durationMs: number
}

interface PlayerSlot {
  name: ActiveLayer
  player?: media.AVPlayer
  prepared: boolean
  sourceUri: string
  surfaceId: string
  preparedResolve?: () => void
  pendingSeekResolve?: () => void
  stateChangeHandler?: (state: media.AVPlayerState) => void
  seekDoneHandler?: () => void
  timeUpdateHandler?: (timeMs: number) => void
  errorHandler?: (error: Object) => void
}

interface SegmentSeekTarget {
  segmentIndex: number
  offsetMs: number
}

export class PingPongTrackController {
  private readonly trackId: string
  private readonly camera: string
  private readonly isAudioMaster: boolean
  private slotA: PlayerSlot = this.createSlot('A')
  private slotB: PlayerSlot = this.createSlot('B')
  private activeLayer: ActiveLayer = 'A'
  private segments: Array<TrackSegmentSource> = []
  private activeSegmentIndex: number = -1
  private standbyPreparedSegmentIndex: number = -1
  private shouldPlay: boolean = false
  private globalMuted: boolean = false
  private playbackRate: number = 1
  private attached: boolean = false
  private disposed: boolean = false
  private queue: Promise<void> = Promise.resolve()
  private lastReportedGlobalMs: number = 0
  private pendingGlobalSeekMs: number = 0
  private onLayerChanged?: (layer: ActiveLayer) => void
  private onProgressChanged?: (globalMs: number) => void
  private onTrackEnded?: () => void
  private recoveringPlayer: boolean = false
  private lifecycleEpoch: number = 0
  private handoffTriggerSegmentIndex: number = -1
  private handoffInFlight: boolean = false
  private readonly standbyPrepareLeadMs: number = 1000
  private readonly handoffLeadMs: number = 20

  constructor(trackId: string, camera: string, isAudioMaster: boolean) {
    this.trackId = trackId
    this.camera = camera
    this.isAudioMaster = isAudioMaster
  }

  getId(): string {
    return this.trackId
  }

  getCamera(): string {
    return this.camera
  }

  getActiveLayer(): ActiveLayer {
    return this.activeLayer
  }

  setCallbacks(
    onLayerChanged?: (layer: ActiveLayer) => void,
    onProgressChanged?: (globalMs: number) => void,
    onTrackEnded?: () => void
  ): void {
    this.setLayerChangedCallback(onLayerChanged)
    this.setProgressChangedCallback(onProgressChanged)
    this.setTrackEndedCallback(onTrackEnded)
  }

  setLayerChangedCallback(onLayerChanged?: (layer: ActiveLayer) => void): void {
    this.onLayerChanged = onLayerChanged
  }

  setProgressChangedCallback(onProgressChanged?: (globalMs: number) => void): void {
    this.onProgressChanged = onProgressChanged
  }

  setTrackEndedCallback(onTrackEnded?: () => void): void {
    this.onTrackEnded = onTrackEnded
  }

  bindSegments(segments: Array<TrackSegmentSource>): void {
    this.segments = [...segments].sort((a, b) => a.startMs - b.startMs)
    this.activeSegmentIndex = -1
    this.standbyPreparedSegmentIndex = -1
    this.lastReportedGlobalMs = 0
    this.handoffTriggerSegmentIndex = -1
    this.handoffInFlight = false
  }

  async init(surfaceA: string, surfaceB: string): Promise<void> {
    const requestEpoch = this.lifecycleEpoch
    await this.enqueue(async () => {
      if (await this.releaseIfExpired(requestEpoch)) {
        return
      }
      this.slotA.surfaceId = surfaceA
      this.slotB.surfaceId = surfaceB
      await this.ensureSlot(this.slotA)
      await this.ensureSlot(this.slotB)
      if (await this.releaseIfExpired(requestEpoch)) {
        return
      }
      this.attached = true
      await this.seekInternal(this.pendingGlobalSeekMs, requestEpoch)
      if (await this.releaseIfExpired(requestEpoch)) {
        return
      }
      await this.applyMutedAndActiveVolume()
      await this.applyPlaybackRate()
    })
  }

  async play(): Promise<void> {
    this.shouldPlay = true
    const requestEpoch = this.lifecycleEpoch
    await this.enqueue(async () => {
      if (await this.releaseIfExpired(requestEpoch)) {
        return
      }
      const active = this.getActiveSlot()
      if (!active.player || !active.prepared) {
        return
      }
      active.player.play()
    })
  }

  async pause(): Promise<void> {
    this.shouldPlay = false
    const requestEpoch = this.lifecycleEpoch
    await this.enqueue(async () => {
      if (await this.releaseIfExpired(requestEpoch)) {
        return
      }
      await this.pauseInternal()
    })
  }

  async seekTo(globalMs: number): Promise<void> {
    this.pendingGlobalSeekMs = Math.max(0, Math.floor(globalMs))
    const requestEpoch = this.lifecycleEpoch
    await this.enqueue(async () => {
      if (await this.releaseIfExpired(requestEpoch)) {
        return
      }
      await this.seekInternal(this.pendingGlobalSeekMs, requestEpoch)
    })
  }

  async setGlobalMuted(muted: boolean): Promise<void> {
    this.globalMuted = muted
    const requestEpoch = this.lifecycleEpoch
    await this.enqueue(async () => {
      if (await this.releaseIfExpired(requestEpoch)) {
        return
      }
      await this.applyMutedAndActiveVolume()
    })
  }

  async setPlaybackRate(rate: number): Promise<void> {
    this.playbackRate = Math.max(0.75, Math.min(2, rate))
    const requestEpoch = this.lifecycleEpoch
    await this.enqueue(async () => {
      if (await this.releaseIfExpired(requestEpoch)) {
        return
      }
      await this.applyPlaybackRate()
    })
  }

  async release(): Promise<void> {
    this.lifecycleEpoch += 1
    const requestEpoch = this.lifecycleEpoch
    this.disposed = true
    this.shouldPlay = false
    this.resolveSlotPendingPromises(this.slotA)
    this.resolveSlotPendingPromises(this.slotB)
    this.onLayerChanged = undefined
    this.onProgressChanged = undefined
    this.onTrackEnded = undefined
    await this.enqueue(async () => {
      if (requestEpoch !== this.lifecycleEpoch) {
        return
      }
      await this.releaseAllSlots()
    })
  }

  private createSlot(name: ActiveLayer): PlayerSlot {
    return {
      name,
      prepared: false,
      sourceUri: '',
      surfaceId: ''
    }
  }

  private getSlot(name: ActiveLayer): PlayerSlot {
    return name === 'A' ? this.slotA : this.slotB
  }

  private getActiveSlot(): PlayerSlot {
    return this.getSlot(this.activeLayer)
  }

  private getStandbySlot(): PlayerSlot {
    return this.getSlot(this.activeLayer === 'A' ? 'B' : 'A')
  }

  private enqueue(operation: () => Promise<void>): Promise<void> {
    this.queue = this.queue.then(operation).catch((error: Object) => {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('PingPongTrack', `${this.trackId} failed: ${message}`)
    })
    return this.queue
  }

  private resolveSegment(globalMs: number): SegmentSeekTarget | undefined {
    const clamped = Math.max(0, globalMs)
    for (let i = 0; i < this.segments.length; i++) {
      const segment = this.segments[i]
      const start = segment.startMs
      const end = segment.startMs + segment.durationMs
      if (clamped >= start && clamped < end) {
        const target: SegmentSeekTarget = { segmentIndex: i, offsetMs: clamped - start }
        return target
      }
    }
    if (this.segments.length === 0) {
      return undefined
    }
    const lastIndex = this.segments.length - 1
    const last = this.segments[lastIndex]
    if (clamped >= last.startMs + last.durationMs) {
      const target: SegmentSeekTarget = { segmentIndex: lastIndex, offsetMs: Math.max(0, last.durationMs - 1) }
      return target
    }
    const fallback: SegmentSeekTarget = { segmentIndex: 0, offsetMs: 0 }
    return fallback
  }

  private async ensureSlot(slot: PlayerSlot): Promise<void> {
    if (slot.player) {
      return
    }
    try {
      slot.player = await media.createAVPlayer()
    } catch (_) {
      slot.player = undefined
      return
    }
    slot.prepared = false
    slot.sourceUri = ''
    slot.preparedResolve = undefined
    slot.pendingSeekResolve = undefined
    this.bindSlotEvents(slot)
  }

  private async seekInternal(globalMs: number, requestEpoch: number): Promise<void> {
    if (await this.releaseIfExpired(requestEpoch) || !this.attached) {
      return
    }
    const target = this.resolveSegment(globalMs)
    if (!target) {
      await this.pauseInternal()
      return
    }
    const targetSegment = this.segments[target.segmentIndex]
    const active = this.getActiveSlot()
    const standby = this.getStandbySlot()
    this.activeSegmentIndex = target.segmentIndex
    this.standbyPreparedSegmentIndex = -1
    this.handoffTriggerSegmentIndex = -1
    this.handoffInFlight = false
    await this.loadSlot(active, targetSegment.uri)
    if (await this.releaseIfExpired(requestEpoch)) {
      return
    }
    await this.waitPrepared(active)
    if (await this.releaseIfExpired(requestEpoch)) {
      return
    }
    await this.seekSlot(active, target.offsetMs)
    if (await this.releaseIfExpired(requestEpoch)) {
      return
    }
    this.lastReportedGlobalMs = globalMs
    if (this.onProgressChanged) {
      this.onProgressChanged(globalMs)
    }
    await this.prepareStandbyForNext(standby, target.segmentIndex + 1, requestEpoch)
    if (await this.releaseIfExpired(requestEpoch)) {
      return
    }
    if (this.shouldPlay) {
      try {
        active.player?.play()
      } catch (_) {}
    }
    await this.applyMutedAndActiveVolume()
  }

  private bindSlotEvents(slot: PlayerSlot): void {
    const playerRef = slot.player
    if (!playerRef) {
      return
    }
    slot.stateChangeHandler = (state: media.AVPlayerState) => {
      if (!slot.player || slot.player !== playerRef || this.disposed) {
        return
      }
      if (state === 'error') {
        this.enqueue(async () => {
          await this.recoverFromPlayerError(slot, 'state_error')
        })
        return
      }
      if (state === 'initialized') {
        if (slot.surfaceId.length > 0) {
          slot.player.surfaceId = slot.surfaceId
        }
        slot.player.prepare()
        return
      }
      if (state === 'prepared') {
        slot.prepared = true
        if (slot.preparedResolve) {
          slot.preparedResolve()
          slot.preparedResolve = undefined
        }
        this.applyMutedAndActiveVolume()
        this.applyPlaybackRate()
        if (this.shouldPlay && slot.name === this.activeLayer) {
          slot.player.play()
        }
        return
      }
      if (state === 'completed' && slot.name === this.activeLayer) {
        this.handleActiveCompleted()
      }
    }
    slot.seekDoneHandler = () => {
      if (slot.pendingSeekResolve) {
        slot.pendingSeekResolve()
        slot.pendingSeekResolve = undefined
      }
    }
    slot.timeUpdateHandler = (timeMs: number) => {
      if (slot.name !== this.activeLayer || this.disposed || this.activeSegmentIndex < 0) {
        return
      }
      const segment = this.segments[this.activeSegmentIndex]
      if (!segment) {
        return
      }
      const playerTimeMs = this.normalizePlayerTimeMs(timeMs, segment.durationMs)
      const globalMs = segment.startMs + playerTimeMs
      this.lastReportedGlobalMs = globalMs
      if (this.onProgressChanged) {
        this.onProgressChanged(globalMs)
      }
      const remainingMs = segment.durationMs - playerTimeMs
      if (remainingMs < this.standbyPrepareLeadMs) {
        this.enqueue(async () => {
          const standby = this.getStandbySlot()
          await this.prepareStandbyForNext(standby, this.activeSegmentIndex + 1, this.lifecycleEpoch)
        })
      }
      if (remainingMs <= this.handoffLeadMs && this.handoffTriggerSegmentIndex !== this.activeSegmentIndex) {
        this.handoffTriggerSegmentIndex = this.activeSegmentIndex
        this.enqueue(async () => {
          await this.tryHandoff(false)
        })
      }
    }
    slot.errorHandler = (error: Object) => {
      const message = error instanceof Error ? error.message : String(error)
      this.enqueue(async () => {
        await this.recoverFromPlayerError(slot, `event_error:${message}`)
      })
    }
    playerRef.on('stateChange', slot.stateChangeHandler)
    playerRef.on('seekDone', slot.seekDoneHandler)
    playerRef.on('timeUpdate', slot.timeUpdateHandler)
    playerRef.on('error', slot.errorHandler)
  }

  private unbindSlotEvents(slot: PlayerSlot): void {
    if (!slot.player) {
      slot.stateChangeHandler = undefined
      slot.seekDoneHandler = undefined
      slot.timeUpdateHandler = undefined
      slot.errorHandler = undefined
      return
    }
    if (slot.stateChangeHandler) {
      try {
        slot.player.off('stateChange', slot.stateChangeHandler)
      } catch (_) {}
      slot.stateChangeHandler = undefined
    }
    if (slot.seekDoneHandler) {
      try {
        slot.player.off('seekDone', slot.seekDoneHandler)
      } catch (_) {}
      slot.seekDoneHandler = undefined
    }
    if (slot.timeUpdateHandler) {
      try {
        slot.player.off('timeUpdate', slot.timeUpdateHandler)
      } catch (_) {}
      slot.timeUpdateHandler = undefined
    }
    if (slot.errorHandler) {
      try {
        slot.player.off('error', slot.errorHandler)
      } catch (_) {}
      slot.errorHandler = undefined
    }
  }

  private async recoverFromPlayerError(slot: PlayerSlot, reason: string): Promise<void> {
    if (this.disposed || !this.attached || this.recoveringPlayer) {
      return
    }
    this.recoveringPlayer = true
    const targetMs = Math.max(0, this.lastReportedGlobalMs)
    this.pendingGlobalSeekMs = targetMs
    debugLog('PingPongTrack', `${this.trackId} recover player error: ${reason}, seek=${targetMs}`)
    try {
      await this.releaseSlot(slot)
      await this.ensureSlot(slot)
      await this.seekInternal(this.pendingGlobalSeekMs, this.lifecycleEpoch)
      if (this.shouldPlay) {
        const active = this.getActiveSlot()
        try {
          active.player?.play()
        } catch (_) {}
      }
    } finally {
      this.recoveringPlayer = false
    }
  }

  private async pauseInternal(): Promise<void> {
    const slots = [this.slotA, this.slotB]
    for (const slot of slots) {
      if (!slot.player || !slot.prepared) {
        continue
      }
      try {
        slot.player.pause()
      } catch (_) {}
    }
  }

  private async loadSlot(slot: PlayerSlot, uri: string): Promise<void> {
    if (!slot.player) {
      return
    }
    slot.prepared = false
    slot.sourceUri = ''
    try {
      await slot.player.reset()
    } catch (_) {}
    if (uri.length === 0) {
      return
    }
    if (uri.startsWith('file://')) {
      try {
        const file = fs.openSync(uri, fs.OpenMode.READ_ONLY)
        slot.player.fdSrc = { fd: file.fd }
      } catch (_) {
        slot.sourceUri = ''
        return
      }
    } else {
      slot.player.url = uri
    }
    slot.sourceUri = uri
  }

  private waitPrepared(slot: PlayerSlot): Promise<void> {
    if (slot.prepared) {
      return Promise.resolve()
    }
    return new Promise((resolve) => {
      slot.preparedResolve = resolve
    })
  }

  private seekSlot(slot: PlayerSlot, offsetMs: number): Promise<void> {
    if (!slot.player || !slot.prepared) {
      return Promise.resolve()
    }
    const player = slot.player
    return new Promise((resolve) => {
      slot.pendingSeekResolve = resolve
      try {
        player.seek(Math.max(0, Math.floor(offsetMs)), media.SeekMode.SEEK_PREV_SYNC)
      } catch (_) {
        slot.pendingSeekResolve = undefined
        resolve()
      }
    })
  }

  private async prepareStandbyForNext(standby: PlayerSlot, nextSegmentIndex: number, requestEpoch: number): Promise<void> {
    if (await this.releaseIfExpired(requestEpoch)) {
      return
    }
    if (nextSegmentIndex < 0 || nextSegmentIndex >= this.segments.length) {
      return
    }
    if (this.standbyPreparedSegmentIndex === nextSegmentIndex && standby.prepared) {
      return
    }
    const nextSegment = this.segments[nextSegmentIndex]
    if (standby.sourceUri !== nextSegment.uri || !standby.prepared) {
      await this.loadSlot(standby, nextSegment.uri)
      if (await this.releaseIfExpired(requestEpoch)) {
        return
      }
      await this.waitPrepared(standby)
      if (await this.releaseIfExpired(requestEpoch)) {
        return
      }
      await this.seekSlot(standby, 0)
      if (await this.releaseIfExpired(requestEpoch)) {
        return
      }
    }
    this.standbyPreparedSegmentIndex = nextSegmentIndex
  }

  private async tryHandoff(force: boolean): Promise<void> {
    if (this.handoffInFlight) {
      return
    }
    const standby = this.getStandbySlot()
    if (!standby.player || !standby.prepared || this.standbyPreparedSegmentIndex !== this.activeSegmentIndex + 1) {
      if (force) {
        this.handoffTriggerSegmentIndex = -1
      }
      return
    }
    this.handoffInFlight = true
    try {
      await this.handoffToStandby()
    } finally {
      this.handoffInFlight = false
    }
  }

  private async handoffToStandby(): Promise<void> {
    const oldActive = this.getActiveSlot()
    const standby = this.getStandbySlot()
    if (!standby.player) {
      return
    }
    this.activeLayer = standby.name
    this.activeSegmentIndex = this.activeSegmentIndex + 1
    this.standbyPreparedSegmentIndex = -1
    this.handoffTriggerSegmentIndex = -1
    this.applyMutedAndActiveVolume()
    if (this.shouldPlay) {
      try {
        standby.player.play()
      } catch (_) {}
    }
    try {
      await oldActive.player?.reset()
    } catch (_) {}
    oldActive.prepared = false
    oldActive.sourceUri = ''
    if (this.onLayerChanged) {
      this.onLayerChanged(this.activeLayer)
    }
  }

  private async handleActiveCompleted(): Promise<void> {
    await this.tryHandoff(true)
    if (this.activeSegmentIndex >= this.segments.length - 1) {
      if (this.onTrackEnded) {
        this.onTrackEnded()
      }
    }
  }

  private normalizePlayerTimeMs(rawTime: number, segmentDurationMs: number): number {
    const safeRaw = Math.max(0, Math.floor(rawTime))
    if (segmentDurationMs <= 0) {
      return safeRaw
    }
    if (safeRaw > segmentDurationMs + 2000) {
      const scaledFromUs = Math.floor(safeRaw / 1000)
      if (scaledFromUs <= segmentDurationMs + 2000) {
        return scaledFromUs
      }
    }
    const scaledFromSec = safeRaw * 1000
    if (safeRaw <= Math.ceil(segmentDurationMs / 1000) + 2 && scaledFromSec <= segmentDurationMs + 2000) {
      return scaledFromSec
    }
    return safeRaw
  }

  private async applyMutedAndActiveVolume(): Promise<void> {
    const slots = [this.slotA, this.slotB]
    for (const slot of slots) {
      if (!slot.player || !slot.prepared) {
        continue
      }
      const active = slot.name === this.activeLayer
      const allowAudio = this.isAudioMaster && !this.globalMuted && active
      const volume = allowAudio ? 1 : 0
      try {
        await slot.player.setVolume(volume)
      } catch (_) {}
    }
  }

  private async applyPlaybackRate(): Promise<void> {
    const slots = [this.slotA, this.slotB]
    let speed = media.PlaybackSpeed.SPEED_FORWARD_1_00_X
    if (this.playbackRate <= 0.75) {
      speed = media.PlaybackSpeed.SPEED_FORWARD_0_75_X
    } else if (this.playbackRate <= 1) {
      speed = media.PlaybackSpeed.SPEED_FORWARD_1_00_X
    } else if (this.playbackRate <= 1.25) {
      speed = media.PlaybackSpeed.SPEED_FORWARD_1_25_X
    } else if (this.playbackRate <= 1.75) {
      speed = media.PlaybackSpeed.SPEED_FORWARD_1_75_X
    } else {
      speed = media.PlaybackSpeed.SPEED_FORWARD_2_00_X
    }
    for (const slot of slots) {
      if (!slot.player || !slot.prepared) {
        continue
      }
      try {
        slot.player.setSpeed(speed)
      } catch (_) {}
    }
  }

  private async releaseSlot(slot: PlayerSlot): Promise<void> {
    this.unbindSlotEvents(slot)
    slot.prepared = false
    slot.sourceUri = ''
    this.resolveSlotPendingPromises(slot)
    if (!slot.player) {
      return
    }
    try {
      await slot.player.release()
    } catch (_) {}
    slot.player = undefined
  }

  private resolveSlotPendingPromises(slot: PlayerSlot): void {
    if (slot.preparedResolve) {
      slot.preparedResolve()
      slot.preparedResolve = undefined
    }
    if (slot.pendingSeekResolve) {
      slot.pendingSeekResolve()
      slot.pendingSeekResolve = undefined
    }
  }

  private async releaseAllSlots(): Promise<void> {
    await this.releaseSlot(this.slotA)
    await this.releaseSlot(this.slotB)
    this.attached = false
  }

  private async releaseIfExpired(requestEpoch: number): Promise<boolean> {
    if (!this.disposed && requestEpoch === this.lifecycleEpoch) {
      return false
    }
    await this.releaseAllSlots()
    return true
  }
}
