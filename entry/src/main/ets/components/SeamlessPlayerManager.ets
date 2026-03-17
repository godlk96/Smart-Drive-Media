import media from '@ohos.multimedia.media'
import audio from '@ohos.multimedia.audio'
import fs from '@ohos.file.fs'
import { debugLog } from '../utils/Logger'

type SlotName = 'A' | 'B'

interface PlayerSlot {
  name: SlotName
  player?: media.AVPlayer
  surfaceId: string
  sourceUri: string
  prepared: boolean
  pendingSeekMs: number
  loadToken: number
}

export interface SeamlessSwapEvent {
  activeSlot: SlotName
  currentUri: string
}

export class SeamlessPlayerManager {
  private slotA: PlayerSlot = this.createSlot('A')
  private slotB: PlayerSlot = this.createSlot('B')
  private activeSlot: SlotName = 'A'
  private currentUri: string = ''
  private nextUri: string = ''
  private muted: boolean = false
  private playbackRate: number = 1
  private swapping: boolean = false
  private shouldPlay: boolean = false
  private ready: boolean = false
  private destroyed: boolean = false
  private queue: Promise<void> = Promise.resolve()
  private onSwapCallback?: (event: SeamlessSwapEvent) => void
  private onEndedCallback?: () => void
  private onErrorCallback?: (message: string) => void

  private createSlot(name: SlotName): PlayerSlot {
    return {
      name,
      surfaceId: '',
      sourceUri: '',
      prepared: false,
      pendingSeekMs: -1,
      loadToken: 0
    }
  }

  private getSlot(name: SlotName): PlayerSlot {
    return name === 'A' ? this.slotA : this.slotB
  }

  private getActiveSlot(): PlayerSlot {
    return this.getSlot(this.activeSlot)
  }

  private getStandbySlot(): PlayerSlot {
    return this.getSlot(this.activeSlot === 'A' ? 'B' : 'A')
  }

  private enqueue(operation: () => Promise<void>): Promise<void> {
    this.queue = this.queue.then(operation).catch((error: Object) => {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('SeamlessManager', `operation failed: ${message}`)
      if (this.onErrorCallback) {
        this.onErrorCallback(message)
      }
    })
    return this.queue
  }

  setCallbacks(
    onSwap?: (event: SeamlessSwapEvent) => void,
    onEnded?: () => void,
    onError?: (message: string) => void
  ): void {
    this.onSwapCallback = onSwap
    this.onEndedCallback = onEnded
    this.onErrorCallback = onError
  }

  async attachSurfaces(surfaceA: string, surfaceB: string): Promise<void> {
    this.slotA.surfaceId = surfaceA
    this.slotB.surfaceId = surfaceB
    await this.ensurePlayers()
    this.ready = true
  }

  async updateWindow(currentUri: string, nextUri: string, startMs: number): Promise<void> {
    this.currentUri = currentUri
    this.nextUri = nextUri
    await this.enqueue(async () => {
      if (this.destroyed || !this.ready) {
        return
      }
      const active = this.getActiveSlot()
      if (active.sourceUri !== currentUri) {
        await this.loadSlot(active, currentUri, startMs)
      } else if (startMs >= 0) {
        active.pendingSeekMs = startMs
        this.applyPendingSeek(active)
      }
      await this.preloadStandby()
      if (this.shouldPlay) {
        this.playActiveNow()
      }
    })
  }

  async play(): Promise<void> {
    this.shouldPlay = true
    await this.enqueue(async () => {
      if (this.destroyed || !this.ready) {
        return
      }
      this.playActiveNow()
    })
  }

  async pause(): Promise<void> {
    this.shouldPlay = false
    await this.enqueue(async () => {
      if (this.destroyed) {
        return
      }
      await this.pauseSlot(this.slotA)
      await this.pauseSlot(this.slotB)
    })
  }

  async seek(ms: number): Promise<void> {
    const clampedMs = Math.max(0, ms)
    await this.enqueue(async () => {
      if (this.destroyed || !this.ready) {
        return
      }
      const active = this.getActiveSlot()
      active.pendingSeekMs = clampedMs
      this.applyPendingSeek(active)
    })
  }

  async setMuted(muted: boolean): Promise<void> {
    this.muted = muted
    await this.enqueue(async () => {
      if (this.destroyed) {
        return
      }
      await this.applyVolumes()
    })
  }

  async setPlaybackRate(rate: number): Promise<void> {
    this.playbackRate = Math.max(0.75, Math.min(2, rate))
    await this.enqueue(async () => {
      if (this.destroyed) {
        return
      }
      await this.applySpeed(this.slotA)
      await this.applySpeed(this.slotB)
    })
  }

  async release(): Promise<void> {
    this.destroyed = true
    await this.enqueue(async () => {
      await this.releaseSlot(this.slotA)
      await this.releaseSlot(this.slotB)
      this.ready = false
    })
  }

  private async ensurePlayers(): Promise<void> {
    await this.ensureSlotPlayer(this.slotA)
    await this.ensureSlotPlayer(this.slotB)
  }

  private async ensureSlotPlayer(slot: PlayerSlot): Promise<void> {
    if (slot.player) {
      return
    }
    slot.player = await media.createAVPlayer()
    slot.player.audioInterruptMode = audio.InterruptMode.INDEPENDENT_MODE
    this.bindListeners(slot)
  }

  private bindListeners(slot: PlayerSlot): void {
    if (!slot.player) {
      return
    }
    const playerRef = slot.player
    slot.player.on('stateChange', async (state: media.AVPlayerState) => {
      if (!slot.player || slot.player !== playerRef || this.destroyed) {
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
        this.applyPendingSeek(slot)
        await this.applySpeed(slot)
        await this.applyVolumes()
        if (this.shouldPlay && slot.name === this.activeSlot) {
          this.playActiveNow()
        }
        return
      }
      if (state === 'completed') {
        if (slot.name === this.activeSlot) {
          if (!this.trySwapNow()) {
            if (this.onEndedCallback) {
              this.onEndedCallback()
            }
          }
        }
        return
      }
      if (state === 'error') {
        if (this.onErrorCallback) {
          this.onErrorCallback(`slot ${slot.name} error`)
        }
      }
    })
    slot.player.on('timeUpdate', (timeMs: number) => {
      if (this.destroyed || slot.name !== this.activeSlot || this.swapping) {
        return
      }
      if (timeMs >= 59800) {
        this.trySwapNow()
      }
    })
  }

  private async setSlotSource(slot: PlayerSlot, uri: string): Promise<void> {
    if (!slot.player) {
      return
    }
    if (uri.length === 0) {
      slot.sourceUri = ''
      slot.prepared = false
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

  private async loadSlot(slot: PlayerSlot, uri: string, seekMs: number): Promise<void> {
    if (!slot.player) {
      return
    }
    slot.loadToken += 1
    slot.prepared = false
    slot.pendingSeekMs = seekMs
    try {
      await slot.player.reset()
    } catch (_) {}
    await this.setSlotSource(slot, uri)
  }

  private async preloadStandby(): Promise<void> {
    const standby = this.getStandbySlot()
    if (this.nextUri.length === 0 || this.nextUri === this.currentUri) {
      return
    }
    if (standby.sourceUri === this.nextUri && standby.prepared) {
      return
    }
    await this.loadSlot(standby, this.nextUri, 0)
  }

  private playActiveNow(): void {
    const active = this.getActiveSlot()
    if (!active.player || !active.prepared) {
      return
    }
    try {
      active.player.play()
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      if (this.onErrorCallback) {
        this.onErrorCallback(message)
      }
    }
  }

  private trySwapNow(): boolean {
    if (this.swapping) {
      return false
    }
    const standby = this.getStandbySlot()
    if (!standby.player || !standby.prepared || standby.sourceUri.length === 0) {
      return false
    }
    this.swapping = true
    const oldActive = this.getActiveSlot()
    this.activeSlot = standby.name
    this.currentUri = standby.sourceUri
    this.nextUri = ''
    try {
      standby.player.play()
    } catch (error) {
      this.swapping = false
      const message = error instanceof Error ? error.message : String(error)
      if (this.onErrorCallback) {
        this.onErrorCallback(message)
      }
      return false
    }
    this.pauseSlot(oldActive)
    this.swapping = false
    if (this.onSwapCallback) {
      this.onSwapCallback({
        activeSlot: this.activeSlot,
        currentUri: this.currentUri
      })
    }
    return true
  }

  private async pauseSlot(slot: PlayerSlot): Promise<void> {
    if (!slot.player || !slot.prepared) {
      return
    }
    try {
      slot.player.pause()
    } catch (_) {}
  }

  private applyPendingSeek(slot: PlayerSlot): void {
    if (!slot.player || !slot.prepared || slot.pendingSeekMs < 0) {
      return
    }
    try {
      slot.player.seek(slot.pendingSeekMs, media.SeekMode.SEEK_PREV_SYNC)
    } catch (_) {}
    slot.pendingSeekMs = -1
  }

  private async applyVolumes(): Promise<void> {
    await this.applyVolume(this.slotA)
    await this.applyVolume(this.slotB)
  }

  private async applyVolume(slot: PlayerSlot): Promise<void> {
    if (!slot.player || !slot.prepared) {
      return
    }
    const volume = slot.name === this.activeSlot ? (this.muted ? 0 : 1) : 0
    try {
      await slot.player.setVolume(volume)
    } catch (_) {}
  }

  private async applySpeed(slot: PlayerSlot): Promise<void> {
    if (!slot.player || !slot.prepared) {
      return
    }
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
    try {
      slot.player.setSpeed(speed)
    } catch (_) {}
  }

  private async releaseSlot(slot: PlayerSlot): Promise<void> {
    slot.prepared = false
    slot.sourceUri = ''
    if (!slot.player) {
      return
    }
    try {
      await slot.player.release()
    } catch (_) {}
    slot.player = undefined
  }
}
