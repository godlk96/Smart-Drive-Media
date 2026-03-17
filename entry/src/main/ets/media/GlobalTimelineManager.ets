import { PingPongTrackController } from './PingPongTrackController'

export type TimelinePlaybackState = 'playing' | 'paused' | 'buffering'

export class GlobalTimelineManager {
  private tracks: Array<PingPongTrackController> = []
  private clockMasterTrackId: string = ''
  private trackEndedFlags: Map<string, boolean> = new Map()
  private endedEmitted: boolean = false
  private globalDurationMs: number = 0
  private globalPlayheadMs: number = 0
  private playbackState: TimelinePlaybackState = 'paused'
  private isSeeking: boolean = false
  private seekingInFlight: boolean = false
  private pendingSeekMs: number = -1
  private ignoreProgressUntilMs: number = 0
  private seekEpoch: number = 0
  private muted: boolean = false
  private playbackRate: number = 1
  private onPlayheadChanged?: (globalMs: number) => void
  private onPlaybackStateChanged?: (state: TimelinePlaybackState) => void
  private onEnded?: () => void

  setDuration(durationMs: number): void {
    this.globalDurationMs = Math.max(0, Math.floor(durationMs))
  }

  getGlobalDurationMs(): number {
    return this.globalDurationMs
  }

  getGlobalPlayheadMs(): number {
    return this.globalPlayheadMs
  }

  getPlaybackState(): TimelinePlaybackState {
    return this.playbackState
  }

  setCallbacks(
    onPlayheadChanged?: (globalMs: number) => void,
    onPlaybackStateChanged?: (state: TimelinePlaybackState) => void,
    onEnded?: () => void
  ): void {
    this.onPlayheadChanged = onPlayheadChanged
    this.onPlaybackStateChanged = onPlaybackStateChanged
    this.onEnded = onEnded
  }

  registerTrack(track: PingPongTrackController): void {
    const exists = this.tracks.some((item) => item.getId() === track.getId())
    if (exists) {
      return
    }
    if (this.clockMasterTrackId.length === 0) {
      this.clockMasterTrackId = track.getId()
    } else {
      const currentMaster = this.tracks.find((item) => item.getId() === this.clockMasterTrackId)
      const currentMasterFront = currentMaster ? currentMaster.getCamera() === 'Front' : false
      if (!currentMasterFront && track.getCamera() === 'Front') {
        this.clockMasterTrackId = track.getId()
      }
    }
    this.trackEndedFlags.set(track.getId(), false)
    track.setProgressChangedCallback((globalMs: number) => {
      if (track.getId() !== this.clockMasterTrackId) {
        return
      }
      if (this.isSeeking) {
        return
      }
      if (this.playbackState !== 'playing' && Date.now() < this.ignoreProgressUntilMs) {
        return
      }
      this.globalPlayheadMs = Math.max(0, Math.min(globalMs, this.globalDurationMs))
      if (this.onPlayheadChanged) {
        this.onPlayheadChanged(this.globalPlayheadMs)
      }
    })
    track.setTrackEndedCallback(() => {
      this.trackEndedFlags.set(track.getId(), true)
      this.emitEndedWhenAllTracksCompleted()
    })
    this.tracks.push(track)
  }

  unregisterTrack(trackId: string): void {
    this.tracks = this.tracks.filter((item) => item.getId() !== trackId)
    this.trackEndedFlags.delete(trackId)
    if (trackId === this.clockMasterTrackId) {
      this.clockMasterTrackId = this.tracks.length > 0 ? this.tracks[0].getId() : ''
    }
  }

  async setMuted(muted: boolean): Promise<void> {
    this.muted = muted
    await Promise.all(this.tracks.map((item) => item.setGlobalMuted(this.muted)))
  }

  async setPlaybackRate(rate: number): Promise<void> {
    this.playbackRate = Math.max(0.75, Math.min(2, rate))
    await Promise.all(this.tracks.map((item) => item.setPlaybackRate(this.playbackRate)))
  }

  async play(): Promise<void> {
    this.resetEndedFlags()
    this.updatePlaybackState('playing')
    await Promise.all(this.tracks.map((item) => item.play()))
  }

  async pause(): Promise<void> {
    await Promise.all(this.tracks.map((item) => item.pause()))
    this.updatePlaybackState('paused')
  }

  async seek(globalMs: number): Promise<void> {
    const targetMs = Math.max(0, Math.min(Math.floor(globalMs), this.globalDurationMs))
    if (this.seekingInFlight) {
      this.pendingSeekMs = targetMs
      return
    }
    this.seekingInFlight = true
    const shouldResume = this.playbackState === 'playing'
    try {
      let currentTargetMs = targetMs
      while (true) {
        this.pendingSeekMs = -1
        this.isSeeking = true
        this.seekEpoch += 1
        const currentEpoch = this.seekEpoch
        this.resetEndedFlags()
        this.updatePlaybackState('buffering')
        await Promise.all(this.tracks.map((item) => item.pause()))
        await Promise.all(this.tracks.map((item) => item.seekTo(currentTargetMs)))
        if (currentEpoch === this.seekEpoch) {
          this.globalPlayheadMs = currentTargetMs
          if (this.onPlayheadChanged) {
            this.onPlayheadChanged(currentTargetMs)
          }
          this.ignoreProgressUntilMs = Date.now() + 260
          this.updatePlaybackState('paused')
        }
        this.isSeeking = false
        if (this.pendingSeekMs < 0 || this.pendingSeekMs === currentTargetMs) {
          break
        }
        currentTargetMs = this.pendingSeekMs
      }
      if (shouldResume) {
        await this.play()
      }
    } finally {
      this.isSeeking = false
      this.seekingInFlight = false
    }
  }

  async release(): Promise<void> {
    await Promise.all(this.tracks.map((item) => item.release()))
    this.tracks = []
    this.trackEndedFlags.clear()
    this.clockMasterTrackId = ''
    this.endedEmitted = false
    this.updatePlaybackState('paused')
  }

  private resetEndedFlags(): void {
    this.endedEmitted = false
    for (const track of this.tracks) {
      this.trackEndedFlags.set(track.getId(), false)
    }
  }

  private emitEndedWhenAllTracksCompleted(): void {
    if (this.playbackState !== 'playing' || this.endedEmitted || this.tracks.length === 0) {
      return
    }
    const allEnded = this.tracks.every((item) => this.trackEndedFlags.get(item.getId()) === true)
    if (!allEnded) {
      return
    }
    this.endedEmitted = true
    this.updatePlaybackState('paused')
    if (this.onEnded) {
      this.onEnded()
    }
  }

  private updatePlaybackState(state: TimelinePlaybackState): void {
    this.playbackState = state
    if (this.onPlaybackStateChanged) {
      this.onPlaybackStateChanged(state)
    }
  }
}
