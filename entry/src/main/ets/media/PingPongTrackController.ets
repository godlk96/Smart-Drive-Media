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
  callbackTaskVersion: number
  preparedResolve?: () => void
  pendingSeekTaskVersion: number
  pendingSeekResolve?: () => void
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
  }

  async init(surfaceA: string, surfaceB: string): Promise<void> {
    await this.enqueue(async () => {
      if (this.disposed) {
        return
      }
      const sameSurface = this.attached && this.slotA.surfaceId === surfaceA && this.slotB.surfaceId === surfaceB
      if (sameSurface) {
        await this.applyMutedAndActiveVolume()
        await this.applyPlaybackRate()
        return
      }
      this.slotA.surfaceId = surfaceA
      this.slotB.surfaceId = surfaceB
      await this.ensureSlot(this.slotA)
      await this.ensureSlot(this.slotB)
      this.attached = true
      await this.seekInternal(this.pendingGlobalSeekMs)
      await this.applyMutedAndActiveVolume()
      await this.applyPlaybackRate()
    })
  }

  async play(): Promise<void> {
    this.shouldPlay = true
    await this.enqueue(async () => {
      if (this.disposed) {
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
    await this.enqueue(async () => {
      await this.pauseInternal()
    })
  }

  async seekTo(globalMs: number): Promise<void> {
    this.pendingGlobalSeekMs = Math.max(0, Math.floor(globalMs))
    await this.enqueue(async () => {
      await this.seekInternal(this.pendingGlobalSeekMs)
    })
  }

  async setGlobalMuted(muted: boolean): Promise<void> {
    this.globalMuted = muted
    await this.enqueue(async () => {
      await this.applyMutedAndActiveVolume()
    })
  }

  async setPlaybackRate(rate: number): Promise<void> {
    this.playbackRate = Math.max(0.75, Math.min(2, rate))
    await this.enqueue(async () => {
      await this.applyPlaybackRate()
    })
  }

  async release(): Promise<void> {
    this.disposed = true
    this.shouldPlay = false
    await this.enqueue(async () => {
      await this.releaseSlot(this.slotA)
      await this.releaseSlot(this.slotB)
      this.attached = false
    })
  }

  private createSlot(name: ActiveLayer): PlayerSlot {
    return {
      name,
      prepared: false,
      sourceUri: '',
      surfaceId: '',
      callbackTaskVersion: 0,
      pendingSeekTaskVersion: -1
    }
  }

  private bumpSlotTaskVersion(slot: PlayerSlot): void {
    slot.callbackTaskVersion = slot.callbackTaskVersion + 1
  }

  private isExpiredSlotTask(slot: PlayerSlot, taskVersion: number): boolean {
    return taskVersion !== slot.callbackTaskVersion
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
    slot.player = await media.createAVPlayer()
    this.bindSlotEvents(slot)
  }

  private async seekInternal(globalMs: number): Promise<void> {
    if (this.disposed || !this.attached) {
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
    await this.loadSlot(active, targetSegment.uri)
    await this.waitPrepared(active)
    await this.seekSlot(active, target.offsetMs)
    this.lastReportedGlobalMs = globalMs
    if (this.onProgressChanged) {
      this.onProgressChanged(globalMs)
    }
    await this.prepareStandbyForNext(standby, target.segmentIndex + 1)
    if (this.shouldPlay) {
      active.player?.play()
    }
    await this.applyMutedAndActiveVolume()
  }

  private bindSlotEvents(slot: PlayerSlot): void {
    const playerRef = slot.player
    if (!playerRef) {
      return
    }
    playerRef.on('stateChange', (state: media.AVPlayerState) => {
      const taskVersion = slot.callbackTaskVersion
      if (!slot.player || slot.player !== playerRef || this.disposed || this.isExpiredSlotTask(slot, taskVersion)) {
        return
      }
      if (state === 'initialized') {
        if (this.isExpiredSlotTask(slot, taskVersion)) {
          return
        }
        if (slot.surfaceId.length > 0) {
          slot.player.surfaceId = slot.surfaceId
        }
        slot.player.prepare()
        return
      }
      if (state === 'prepared') {
        if (this.isExpiredSlotTask(slot, taskVersion)) {
          return
        }
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
        if (this.isExpiredSlotTask(slot, taskVersion)) {
          return
        }
        this.handleActiveCompleted()
      }
    })
    playerRef.on('seekDone', () => {
      const taskVersion = slot.callbackTaskVersion
      if (!slot.player || slot.player !== playerRef || this.disposed || this.isExpiredSlotTask(slot, taskVersion)) {
        return
      }
      if (slot.pendingSeekTaskVersion !== taskVersion) {
        return
      }
      if (slot.pendingSeekResolve) {
        slot.pendingSeekResolve()
        slot.pendingSeekResolve = undefined
        slot.pendingSeekTaskVersion = -1
      }
    })
    playerRef.on('timeUpdate', (timeMs: number) => {
      const taskVersion = slot.callbackTaskVersion
      if (slot.name !== this.activeLayer || this.disposed || this.activeSegmentIndex < 0 || this.isExpiredSlotTask(slot, taskVersion)) {
        return
      }
      const segment = this.segments[this.activeSegmentIndex]
      if (!segment) {
        return
      }
      const globalMs = segment.startMs + Math.max(0, timeMs)
      this.lastReportedGlobalMs = globalMs
      if (this.onProgressChanged) {
        this.onProgressChanged(globalMs)
      }
      const remaining = segment.durationMs - Math.max(0, timeMs)
      if (remaining < 1000) {
        this.enqueue(async () => {
          if (this.isExpiredSlotTask(slot, taskVersion)) {
            return
          }
          const standby = this.getStandbySlot()
          await this.prepareStandbyForNext(standby, this.activeSegmentIndex + 1)
        })
      }
      if (remaining <= 20) {
        this.enqueue(async () => {
          if (this.isExpiredSlotTask(slot, taskVersion)) {
            return
          }
          await this.tryHandoff()
        })
      }
    })
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
    this.bumpSlotTaskVersion(slot)
    slot.prepared = false
    slot.sourceUri = ''
    slot.pendingSeekTaskVersion = -1
    if (slot.pendingSeekResolve) {
      slot.pendingSeekResolve()
      slot.pendingSeekResolve = undefined
    }
    try {
      await slot.player.reset()
    } catch (_) {}
    if (uri.length === 0) {
      return
    }
    if (uri.startsWith('file://')) {
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY)
      slot.player.fdSrc = { fd: file.fd }
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
      slot.pendingSeekTaskVersion = slot.callbackTaskVersion
      slot.pendingSeekResolve = resolve
      try {
        player.seek(Math.max(0, Math.floor(offsetMs)), media.SeekMode.SEEK_PREV_SYNC)
      } catch (_) {
        slot.pendingSeekTaskVersion = -1
        slot.pendingSeekResolve = undefined
        resolve()
      }
    })
  }

  private async prepareStandbyForNext(standby: PlayerSlot, nextSegmentIndex: number): Promise<void> {
    if (nextSegmentIndex < 0 || nextSegmentIndex >= this.segments.length) {
      return
    }
    if (this.standbyPreparedSegmentIndex === nextSegmentIndex && standby.prepared) {
      return
    }
    const nextSegment = this.segments[nextSegmentIndex]
    if (standby.sourceUri !== nextSegment.uri || !standby.prepared) {
      await this.loadSlot(standby, nextSegment.uri)
      await this.waitPrepared(standby)
      await this.seekSlot(standby, 0)
    }
    this.standbyPreparedSegmentIndex = nextSegmentIndex
  }

  private async tryHandoff(): Promise<void> {
    const standby = this.getStandbySlot()
    if (!standby.player || !standby.prepared || this.standbyPreparedSegmentIndex !== this.activeSegmentIndex + 1) {
      return
    }
    await this.handoffToStandby()
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
    this.applyMutedAndActiveVolume()
    if (this.shouldPlay) {
      standby.player.play()
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
    await this.tryHandoff()
    if (this.activeSegmentIndex >= this.segments.length - 1) {
      if (this.onTrackEnded) {
        this.onTrackEnded()
      }
    }
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
    this.bumpSlotTaskVersion(slot)
    slot.prepared = false
    slot.sourceUri = ''
    slot.preparedResolve = undefined
    slot.pendingSeekTaskVersion = -1
    if (slot.pendingSeekResolve) {
      slot.pendingSeekResolve()
      slot.pendingSeekResolve = undefined
    }
    if (!slot.player) {
      return
    }
    try {
      await slot.player.release()
    } catch (_) {}
    slot.player = undefined
  }
}
