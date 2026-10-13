/**
 * GlobalTimelineManager —— 预览页的**协调器**（不是"第二个时间源"）。
 *
 * 旧版的根本问题（docs/预览播放器简化重构方案.md 二.1）：它自己又维护了一份
 * globalPlayheadMs / playbackState，于是同一个"当前播放时间"有三个写者，
 * 只能靠 epoch、seekRequestGate、isBarrierSwitching、settle 窗口互相打补丁。
 *
 * 新版只做三件事：
 *   1. 持有时钟（TimelineClock）—— 时间的**唯一**权威；
 *   2. 把时钟状态翻译成每个轨的 DesiredState，交给幂等对账器；
 *   3. 处理时钟推不动的两种情形：所有轨都没素材的时刻（跳过），以及播到尽头（结束）。
 *
 * 于是这一层不再有 epoch / 队列 / barrier / 超时 / 静默丢弃：
 *   - 主轨进度 → clock.advanceFromMaster()（只前进，倒退只能来自 seek）；
 *   - 段边界 → 时钟推进到该段末尾，然后统一对账（该换段就换段，到尽头就结束）；
 *   - 用户 seek → clock.seek() 一次，之后对账；
 *   - 拖动期间**完全不碰 player**，松手只 seek 一次。
 */

import { DesiredState, SingleTrackController } from './SingleTrackController'
import { ClockSnapshot, TimelineClock } from './TimelineClock'
import {
  SegmentKind,
  SegmentSpan,
  SegmentTarget,
  isCoveredMs,
  nextCoveredMs,
  segmentAt
} from './TimelineMath'
import { debugLog } from '../utils/Logger'

export type TimelinePlaybackState = 'playing' | 'paused' | 'buffering'

export class GlobalTimelineManager {
  private tracks: Array<SingleTrackController> = []
  private clock: TimelineClock = new TimelineClock()
  private clockMasterTrackId: string = ''
  private muted: boolean = false
  private playbackRate: number = 1
  private endedEmitted: boolean = false
  private released: boolean = false

  private onPlayheadChanged?: (globalMs: number) => void
  private onPlaybackStateChanged?: (state: TimelinePlaybackState) => void
  private onEnded?: () => void

  private unsubscribeClock?: () => void

  // 对账循环：不是队列，不丢操作。运行中收到新触发只标记 dirty，
  // 本轮结束后用**最新**的时钟状态再跑一遍（latest-wins）。
  private passRunning: boolean = false
  private passDirty: boolean = false
  private passLoop: Promise<void> = Promise.resolve()
  private lastSeekGeneration: number = -1

  // ------------------------------------------------------------------
  // 对外 API（保持与旧版兼容，EditorPreviewArea 无需改调用方式）
  // ------------------------------------------------------------------

  setDuration(durationMs: number): void {
    this.clock.setDuration(Math.max(0, Math.floor(durationMs)))
    this.kick()
  }

  getGlobalDurationMs(): number {
    return this.clock.getDurationMs()
  }

  getGlobalPlayheadMs(): number {
    return this.clock.getPlayheadMs()
  }

  getPlaybackState(): TimelinePlaybackState {
    return this.clock.isPlaying() ? 'playing' : 'paused'
  }

  setCallbacks(
    onPlayheadChanged?: (globalMs: number) => void,
    onPlaybackStateChanged?: (state: TimelinePlaybackState) => void,
    onEnded?: () => void
  ): void {
    this.onPlayheadChanged = onPlayheadChanged
    this.onPlaybackStateChanged = onPlaybackStateChanged
    this.onEnded = onEnded
    if (this.unsubscribeClock) {
      this.unsubscribeClock()
      this.unsubscribeClock = undefined
    }
    this.unsubscribeClock = this.clock.subscribe((snapshot: ClockSnapshot) => {
      if (this.onPlayheadChanged) {
        this.onPlayheadChanged(snapshot.playheadMs)
      }
      if (this.onPlaybackStateChanged) {
        this.onPlaybackStateChanged(snapshot.playing ? 'playing' : 'paused')
      }
      this.kick()
    })
  }

  registerTrack(track: SingleTrackController): void {
    const exists = this.tracks.some((item: SingleTrackController) => item.getId() === track.getId())
    if (exists) {
      return
    }
    if (this.clockMasterTrackId.length === 0) {
      this.clockMasterTrackId = track.getId()
    } else {
      const currentMaster = this.tracks.find((item: SingleTrackController) => item.getId() === this.clockMasterTrackId)
      const currentMasterFront = currentMaster ? currentMaster.getCamera() === 'Front' : false
      if (!currentMasterFront && track.getCamera() === 'Front') {
        this.clockMasterTrackId = track.getId()
      }
    }

    track.setCallbacks(
      (globalMs: number) => {
        this.handleTrackProgress(track, globalMs)
      },
      (segmentEndMs: number) => {
        this.handleTrackBoundary(track, segmentEndMs)
      }
    )

    this.tracks.push(track)
    debugLog('GlobalTimeline', `registerTrack ${track.getId()} camera=${track.getCamera()}`)
  }

  updateClockMaster(): void {
    const nextMaster = this.resolveClockMasterTrackId()
    if (nextMaster !== this.clockMasterTrackId) {
      this.clockMasterTrackId = nextMaster
      debugLog('GlobalTimeline', `clockMasterTrackId updated to: ${this.clockMasterTrackId}`)
    }
    this.kick()
  }

  async setMuted(muted: boolean): Promise<void> {
    this.muted = muted
    await Promise.all(this.tracks.map((item: SingleTrackController) => item.setGlobalMuted(muted)))
  }

  async setPlaybackRate(rate: number): Promise<void> {
    this.playbackRate = Math.max(0.75, Math.min(2, rate))
    this.clock.setRate(this.playbackRate)
    await Promise.all(this.tracks.map((item: SingleTrackController) => item.setPlaybackRate(this.playbackRate)))
    this.kick()
    await this.passLoop
  }

  async play(): Promise<void> {
    const durationMs = this.clock.getDurationMs()
    if (durationMs > 0 && this.clock.getPlayheadMs() >= durationMs) {
      // 已播到尽头：从头开始，否则按 play 毫无反应。
      this.clock.seek(0)
    }
    this.endedEmitted = false
    this.clock.setPlaying(true)
    this.kick()
    await this.passLoop
  }

  async pause(): Promise<void> {
    this.clock.setPlaying(false)
    this.kick()
    await this.passLoop
  }

  /**
   * 唯一的跳转入口。时钟的 seek() 会结束拖动、设置真实值并自增 seekGeneration，
   * 协调器据此对全部轨做一次**强制**重定位。
   */
  async seek(globalMs: number): Promise<void> {
    this.endedEmitted = false
    this.clock.seek(globalMs)
    this.kick()
    await this.passLoop
  }

  async release(): Promise<void> {
    this.released = true
    if (this.unsubscribeClock) {
      this.unsubscribeClock()
      this.unsubscribeClock = undefined
    }
    this.clock.release()
    await Promise.all(this.tracks.map((item: SingleTrackController) => item.release()))
    this.tracks = []
    this.clockMasterTrackId = ''
    this.endedEmitted = false
  }

  // ------------------------------------------------------------------
  // 内部：轨道回调
  // ------------------------------------------------------------------

  /**
   * 只有**主轨**的进度能推进时钟；但当主轨在当前时刻本来就没素材（空洞）时，
   * 任何正在播放内容的轨都可以推进，否则播放头会在空洞里永久停住。
   */
  private handleTrackProgress(track: SingleTrackController, globalMs: number): void {
    if (this.released) {
      return
    }
    const isMaster = track.getId() === this.clockMasterTrackId
    if (!isMaster && this.masterHasContentAt(this.clock.getPlayheadMs())) {
      return
    }
    this.clock.advanceFromMaster(globalMs)
  }

  /**
   * 某轨一段播完。主轨的段边界意味着"这一分钟真的过去了"：
   * 把时钟推进到该段末尾，再统一对账 —— 该换段就换段，到尽头就结束。
   * 这里**不**做任何跨轨同步（旧的 barrier 换段就是在藏这个空档，而藏的过程才是 bug 源）。
   */
  private handleTrackBoundary(track: SingleTrackController, segmentEndMs: number): void {
    if (this.released) {
      return
    }
    const isMaster = track.getId() === this.clockMasterTrackId
    // 段边界是"进度条会不会停一下"的唯一周期点：主轨 completed 后时钟被推到段末，
    // 随后所有轨都要 reset+prepare 新段，这段时间内没有任何轨上报进度。
    debugLog(
      'GlobalTimeline',
      `boundary track=${track.getId()} master=${isMaster} end=${segmentEndMs} clock=${this.clock.getPlayheadMs()}`
    )
    if (isMaster && segmentEndMs > this.clock.getPlayheadMs()) {
      this.clock.seek(segmentEndMs)
    }
    this.kick()
  }

  private masterHasContentAt(globalMs: number): boolean {
    const master = this.tracks.find((item: SingleTrackController) => item.getId() === this.clockMasterTrackId)
    if (!master) {
      return false
    }
    const target: SegmentTarget = segmentAt(master.getSegments(), globalMs)
    return target.kind === SegmentKind.CONTENT
  }

  private resolveClockMasterTrackId(): string {
    if (this.tracks.length === 0) {
      return ''
    }
    const frontTrack = this.tracks.find((item: SingleTrackController) => item.getCamera() === 'Front')
    if (frontTrack) {
      return frontTrack.getId()
    }
    return this.tracks[0].getId()
  }

  // ------------------------------------------------------------------
  // 内部：对账循环
  // ------------------------------------------------------------------

  private kick(): void {
    this.passDirty = true
    if (!this.passRunning) {
      this.passLoop = this.runPasses()
    }
  }

  private async runPasses(): Promise<void> {
    this.passRunning = true
    try {
      do {
        this.passDirty = false
        await this.runOnePass()
      } while (this.passDirty && !this.released)
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      debugLog('GlobalTimeline', `reconcile pass error: ${message}`)
    } finally {
      this.passRunning = false
    }
  }

  private async runOnePass(): Promise<void> {
    if (this.released || this.tracks.length === 0) {
      return
    }

    // 拖动期间不碰 player：时钟不推进（advanceFromMaster 已忽略拖动），
    // 松手时统一 seek 一次即可。
    if (this.clock.isDragging()) {
      return
    }

    const durationMs = this.clock.getDurationMs()
    if (this.clock.isPlaying()) {
      const playheadMs = this.clock.getPlayheadMs()
      const trackSpans = this.collectTrackSpans()
      if (!isCoveredMs(trackSpans, playheadMs)) {
        // 当前时刻没有任何轨有素材 —— 没有任何轨能推进时钟。
        // 向前跳到下一个有素材的时刻；没有下一个则播放结束。
        const nextMs = nextCoveredMs(trackSpans, playheadMs, durationMs)
        if (nextMs >= durationMs) {
          await this.finishPlayback()
          return
        }
        debugLog('GlobalTimeline', `skip uncovered range ${playheadMs} -> ${nextMs}`)
        this.clock.seek(nextMs)
      }
    }

    const desired = new DesiredState()
    desired.globalMs = this.clock.getPlayheadMs()
    desired.playing = this.clock.isPlaying()
    desired.rate = this.clock.getRate()

    const generation = this.clock.getSeekGeneration()
    const forceSeek = generation !== this.lastSeekGeneration
    this.lastSeekGeneration = generation

    await Promise.all(this.tracks.map((item: SingleTrackController) => item.reconcile(desired, forceSeek)))
  }

  private async finishPlayback(): Promise<void> {
    if (this.endedEmitted) {
      return
    }
    this.endedEmitted = true
    debugLog('GlobalTimeline', 'playback finished')
    this.clock.seek(this.clock.getDurationMs())
    this.clock.setPlaying(false)
    if (this.onEnded) {
      this.onEnded()
    }
  }

  private collectTrackSpans(): Array<Array<SegmentSpan>> {
    const result: Array<Array<SegmentSpan>> = []
    for (let i = 0; i < this.tracks.length; i++) {
      result.push(this.tracks[i].getSegments())
    }
    return result
  }
}
