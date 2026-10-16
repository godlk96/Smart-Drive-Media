/**
 * SingleTrackController —— 一条逻辑轨（= 一个机位 = 一个 AVPlayer）的**幂等对账器**。
 *
 * 与旧版的根本区别（旧版见 git 历史与 docs/预览播放器简化重构方案.md 第二节）：
 *   旧：调用方"指挥"播放器（init/play/seek/switchSegment 各是一个动作序列），
 *       靠 epoch + 串行队列 + 三个超时 + 单槽 Promise 去猜"现在到底该播哪儿"；
 *       事件回调里还会自己换段，于是同一状态有两个写者。
 *   新：调用方只给一个**目标状态** DesiredState（全局时间 + 是否播放 + 速率），
 *       控制器自己算出"该装哪个文件、该 seek 到哪一毫秒、该播还是该停"。
 *       对账是幂等的 —— 同一个 Desired 执行一百次和执行一次结果相同，
 *       所以重复 seek / 重复播放 / 迟到的回调都天然无害，不需要任何"丢弃"机制。
 *
 * 三条由此成立的不变式：
 *   1. 只有 reconcile() 会碰播放器；事件回调（prepared/completed/seekDone）只**重新触发一次对账**，
 *      自己不做任何决定。
 *   2. 没有 setTimeout。等待就绪不是"等一个超时"，而是"事件到了就再对账一次"。
 *   3. 没有 epoch、没有队列、没有静默 return。并发靠 **latest-wins 合并**：
 *      运行中收到新 Desired 就只标记 dirty，本轮结束后用**最新**的 Desired 再跑一次。
 *
 * 本文件不依赖 ArkUI，但依赖 @ohos.multimedia.media / @ohos.file.fs，
 * 因此不在离线单测覆盖范围内；它的**决策逻辑**全部下沉到 TimelineMath.ets（纯函数，有单测）。
 */

import media from '@ohos.multimedia.media'
import fs from '@ohos.file.fs'
import { debugLog } from '../utils/Logger'
import { speedEnumForRate } from '../model/SegmentModel'
import {
  SegmentKind,
  SegmentSpan,
  SegmentTarget,
  checkSeek,
  gapHoldIndex,
  segmentAt
} from './TimelineMath'

/**
 * 播放链路追踪开关：**只增日志，不改任何行为**。
 *
 * 为什么需要它（见 docs 的诊断记录）：真机上反馈"声音断断续续 + 进度条卡顿"，
 * 而本机没有设备（`hdc list targets` 为空），无法复现。
 * 播放链路里**唯一**能周期性造成"静音 + 进度冻结"的地方是跨段换源：
 * 旧实现（PingPongTrackController）提前 1000ms 在备用播放器上预载下一段、
 * 差 20ms 时交接，因此换段无感；新实现删掉了预载，改成在**正在播放的**播放器上
 * 执行 reset() + fdSrc + prepare()，这段耗时就是实打实的静音时长。
 *
 * 打开后每次换段会输出 prepare 耗时与"载入→首个 timeUpdate"的总时长，
 * 这就是判断根因的直接证据。确认后把本开关置 false 即可（或直接删掉这些日志）。
 */
const PLAYBACK_TRACE: boolean = true

/**
 * R1 探针：用 API 26 的 AVPlayer **播放列表**代替 reset()+prepare() 换段。
 *
 * 为什么需要它：换段静音的根因是"换源必须 reset() 回 idle"（官方唯一记录的换源路径），
 * 而 reset() 会释放播放引擎。API 26 给 AVPlayer 加了播放列表
 * （addPlaybackMediaSource / advanceToNextMediaSource / onPlaybackContentChanged），
 * 官方示例里换段**不调用 reset()** —— 若它真的无缝，就是本项目的正解，
 * 且仍然是"每槽 1 个 AVPlayer"（不回到 PingPong）。
 *
 * 但"换条目是否无缝"是平台行为，只能真机验证，所以先做成开关。
 *
 * **真机结论（2026-10-13 第七份日志，见 docs/预览播放器-声音断续与进度卡顿-根因诊断.md 1.7）：**
 *   - 换条**确实快**：播放器会**自动接续**，日志为
 *     `★播放列表换条 ... 距请求=-1ms 距末次上报=61ms`；
 *     对比 reset 路径的 320~377ms，**快约 5 倍** —— "播放列表能免掉重建解码链"这个判断成立；
 *   - 但**这一版实现不可用**：同一次会话里，播放列表路径触发了 3 次
 *     `Unsupported Format: DEM_FMT_ERR-unsupport interface, unsupport container format type, hevc-`
 *     （启动时 slot_1/slot_2 的 prepare 失败各一次 + 交界处唯一仍在用播放列表的 slot_0 advance 失败一次），
 *     而**同一会话里 reset 路径 0 次**。即：**换条很快，但换过去之后解复用器起不来。**
 *   - 因此开关**默认关回 false**，线上保持已验证的 reset 路径。
 *     探针代码保留（含状态守卫与失败回落），方便日后平台修复后重新验证。
 *
 * 已知取舍（探针阶段刻意不处理，真机验证通过后再做）：
 *   - 每个条目需要一个独立 fd（官方明确同一 fd 不可交给多个播放器），这里一次加满，
 *     fd 数量 = 该机位切片数；验证通过后再改成"窗口懒加载"。
 *   - 空洞（该机位缺某一分钟）未处理：列表会连续播过去，因此本探针只用于量换条耗时。
 *   - 探针路径没有 reset 路径的 `endedUri === wantedUri` 守卫（"该段已播完就保持末帧"）。
 *     行程播到尽头时协调器会把 playing 置 false，因此正常情况下看不到差异；
 *     若日志里出现"播完又自己从头开始"，那是这条守卫缺失，不是换条本身的问题。
 *   - 探针路径沿用 7.1 的既有缺陷（刚 prepared 的第一次对账不 seek），
 *     所以"模板切换后先出约 0.7s 错位画面"在探针下同样存在，别误判成探针引入的。
 */
const USE_PLAYLIST_PROBE: boolean = false

/** 构建标记：日志里能直接看出"装的是哪一版"，避免再出现"改了没生效/没重装"的来回。 */
const BUILD_STAMP: string = 'surface1-2026-10-13'

/**
 * seek 看门狗阈值。正常 seek 在本项目数据上是 ~100ms 量级；
 * 超过这个时间说明 `seekDone` 不会来了（被拒/丢失），必须主动解卡。
 */
const SEEK_STUCK_MS: number = 1500

/** 播放列表 advance 连续失败多少次就放弃探针、退回 reset 路径。 */
const PLAYLIST_ADVANCE_FAIL_LIMIT: number = 3

/**
 * 等待视频 surface 的上限。
 * surface 必须在 prepare() 之前绑定才渲染（见 applyDesired），所以没 surface 就先不载入；
 * 但必须有上限 —— 万一某个槽位永远拿不到 surface（例如 XComponent 的 onLoad 拿到的 id 是 '0'），
 * 宁可"只有声音没有画面"，也不能整轨不载入。
 */
const SURFACE_WAIT_MAX_MS: number = 2000

/** 对账目标：调用方唯一需要表达的东西。 */
export class DesiredState {
  /** 全局播放头位置（毫秒，相对行程起点）。 */
  globalMs: number = 0
  /** 是否应当正在播放。 */
  playing: boolean = false
  /** 播放速率。 */
  rate: number = 1
}

interface PlaybackStrategyOptions {
  showFirstFrameOnPrepare?: boolean
  /** PlaylistLoopMode：4 = PLAYLIST_LOOP_MODE_NONE（仅 R1 探针使用）。 */
  playlistLoopMode?: number
}

// seek 的容差与确认窗口是**纯策略**，放在 TimelineMath.ets 里（有离线单测）：
// 这里曾经用"上次 seek 的目标"当偏差基准，而目标会被播放甩在身后，
// 于是每积累一个容差就 seek 一次 —— 播放中约 3~5 次/秒的 seek 风暴。
// 见 TimelineMath.checkSeek()。

export class SingleTrackController {
  private readonly trackId: string
  private camera: string

  private player?: media.AVPlayer
  private surfaceId: string = ''
  /** "等视频 surface，暂不载入"只打一次，避免对账循环刷屏。 */
  private surfaceWaitLogged: boolean = false
  /** surface 等待截止时刻；0 = 还没开始等。 */
  private surfaceWaitDeadlineMs: number = 0
  private spans: Array<SegmentSpan> = []
  private openedFd?: number

  private disposed: boolean = false
  private prepared: boolean = false
  /** 播放器里当前**已就绪**的 uri；'' 表示没有。 */
  private loadedUri: string = ''
  /** 正在载入的 uri；'' 表示没有载入在进行。 */
  private loadingUri: string = ''
  /**
   * 播放器**实际**报告的段内偏移（来自 timeUpdate）。
   * 这是"要不要 seek"的唯一基准。绝不能用"上次 seek 的目标"当基准：
   * 目标会被播放甩在身后，偏差于是**恒定增长**，每积累一个容差就 seek 一次。
   */
  private observedOffsetMs: number = 0
  /** 偏差已连续超容差的毫秒数；由 checkSeek() 维护。 */
  private driftHeldMs: number = 0
  /** 上一次 seek 决策的墙钟时刻；0 表示还没检查过（第一轮 elapsed 记 0）。 */
  private lastSeekCheckAtMs: number = 0
  /** 是否有 seek 在飞。 */
  private seekInFlight: boolean = false
  /**
   * 发出 seek 的墙钟时刻。用于看门狗：seek 被播放器拒绝时 `seekDone` 永远不会来，
   * `seekInFlight` 会永久为 true，而所有对账入口都会在 `if (seekInFlight) return` 处返回
   * —— 整轨（含主轨）就此死锁，表现为"完全卡死、没有任何播放进度"。
   * 真机已复现过一次（见 docs/预览播放器-声音断续与进度卡顿-根因诊断.md 7.7）。
   */
  private seekIssuedAtMs: number = 0
  /** 已播到末尾的 uri：此时保持末帧等时钟越过边界，不要回头重播。 */
  private endedUri: string = ''
  /** 播放器当前是否处于 play 状态（避免重复调 play/pause）。 */
  private playing: boolean = false

  private globalMuted: boolean = false
  private playbackRate: number = 1

  private desired: DesiredState = new DesiredState()

  // ------------------------------------------------------------------
  // 播放链路追踪（仅日志，不参与任何判断）
  // ------------------------------------------------------------------
  /** 本次换段开始（reset 之前）的墙钟时刻。 */
  private traceLoadStartedAtMs: number = 0
  /** 本次换段进入 prepared 的墙钟时刻；0 表示还没到。 */
  private tracePreparedAtMs: number = 0
  /** 本次换段后**真正调用 play()** 的墙钟时刻；0 表示还没 play。 */
  private tracePlayRequestedAtMs: number = 0
  /** 是否还在等"换段后的第一个 timeUpdate"（用它算出静音总时长）。 */
  private traceAwaitingFirstReport: boolean = false
  /** 上一个被采纳的 timeUpdate 时刻，用于统计上报节奏。 */
  private traceLastReportAtMs: number = 0
  private traceReportCount: number = 0
  private traceIntervalSumMs: number = 0
  private traceIntervalMaxMs: number = 0
  /** 最近一次 checkSeek 算出的偏差，仅用于日志。 */
  private traceLastDriftMs: number = 0
  // 会话级累计（不随换段清零）：用来回答"这次播放到底有没有异常"，
  // 对"偶尔才出现、现在又没了"的间歇性问题尤其重要。
  private traceLoadCount: number = 0
  private traceSeekForceCount: number = 0
  private traceSeekDriftCount: number = 0
  /** 整场播放里两次上报之间的**最大**间隔（毫秒）——声音断/进度卡都会让它变大。 */
  private traceWorstReportGapMs: number = 0

  // ------------------------------------------------------------------
  // R1 探针状态（USE_PLAYLIST_PROBE 为 true 时才使用）
  // ------------------------------------------------------------------
  /** 播放列表条目 ID，与 playlistSpanIndex 平行。 */
  private playlistIds: Array<string> = []
  /** 条目 → spans 下标。 */
  private playlistSpanIndex: Array<number> = []
  /** 每个条目对应的已打开 fd（播放器持有着，必须保持打开）。 */
  private playlistFds: Array<number> = []
  /** 列表是否已建好。 */
  private playlistReady: boolean = false
  /** 建列表失败（条目为 0）→ 回落走原来的 reset 路径，避免这一轨直接没画面没声音。 */
  private playlistFailed: boolean = false
  /** 建列表期间抑制 'initialized' 里的自动 prepare（要等全部条目加完）。 */
  private playlistBuilding: boolean = false
  /** 建列表期间收到了 'initialized'，需要由 ensurePlaylist 补一次 prepare。 */
  private playlistPreparePending: boolean = false
  /** 当前正在播放的条目对应的 spans 下标；-1 = 未知。 */
  private playlistIndex: number = -1
  /** 上一次 advanceToMediaSource 请求的墙钟时刻。 */
  private playlistAdvanceRequestedAtMs: number = 0
  /** 最近一次 timeUpdate 的墙钟时刻（用于算换条静音）。 */
  private playlistLastReportAtMs: number = 0
  /**
   * 连续失败次数。播放器拒绝 advance（典型："current state is not prepared"）时会立刻
   * 被对账循环重试，形成风暴；连续失败若干次就直接放弃播放列表、退回 reset 路径，
   * 保证探针最坏情况下也只是"没量到数字"，不会把预览跑成死机。
   */
  private playlistAdvanceFailCount: number = 0

  // latest-wins 合并：不做队列、不丢操作，只保证"最后一次 Desired 一定被执行"。
  private reconcileRunning: boolean = false
  private reconcileDirty: boolean = false
  private reconcileForceSeek: boolean = false
  private reconcileLoop: Promise<void> = Promise.resolve()

  private onProgress?: (globalMs: number) => void
  /** 段播完时上报该段的**全局结束毫秒**，由协调器决定下一步（本类不做任何决定）。 */
  private onBoundary?: (segmentEndMs: number) => void

  constructor(trackId: string, camera: string) {
    this.trackId = trackId
    this.camera = camera
    debugLog(
      'SingleTrack',
      `${this.trackId} 构建标记 版本=${BUILD_STAMP} 探针=${USE_PLAYLIST_PROBE ? 'ON' : 'OFF'} 打点=${PLAYBACK_TRACE ? 'ON' : 'OFF'}`
    )
  }

  /**
   * 该轨是否应该出声。
   *
   * **不能再按槽位下标判断**（曾经是 `new SingleTrackController(..., i === 0)`）：
   * 槽位下标与机位不是一回事。真实数据里**只有 front 文件带音轨**，而 T4 的槽位顺序是
   * `LeftFront / Front / RightFront` —— 按 `i === 0` 就会把唯一有声音的 Front 轨静音、
   * 给没有音轨的 LeftFront 开音量 ⇒ **T4 预览没声音**（缺陷 7.2）。
   *
   * 改为按机位判断：只有 Front 轨出声。T3 的槽位里没有 Front，
   * 而它的导出策略本来就是 `disableFrontAudio: true` ⇒ 静音与导出一致，不算缺陷。
   */
  private isAudioOutputTrack(): boolean {
    return this.camera === 'Front'
  }

  /**
   * surface 还没到就先不要载入（返回 true = 继续等）。
   *
   * 为什么必须等：真机表现是 **prepare() 之后再设 surfaceId 不渲染** ——
   * 进剪辑页时 `aboutToAppear` 会先跑对账并 prepare，而 XComponent 的 `onLoad`
   * 通常在之后才拿到 surfaceId，于是**第一段没有画面**（用户报的"播放第一组不显示最上方的主视角"），
   * 要等到下一次换段 reload、surface 在 prepare 之前绑上，画面才出现。
   * `setSurfaceId()` 会再次触发对账，所以等它来驱动即可。
   *
   * 有上限（`SURFACE_WAIT_MAX_MS`）：超时就放行，宁可没有画面也不能没有声音。
   */
  private shouldWaitForSurface(): boolean {
    if (this.surfaceId.length > 0) {
      return false
    }
    const now = Date.now()
    if (this.surfaceWaitDeadlineMs === 0) {
      this.surfaceWaitDeadlineMs = now + SURFACE_WAIT_MAX_MS
      if (PLAYBACK_TRACE && !this.surfaceWaitLogged) {
        this.surfaceWaitLogged = true
        debugLog(
          'SingleTrack',
          `${this.trackId} 等视频 surface，暂不载入（上限 ${SURFACE_WAIT_MAX_MS}ms）`
        )
      }
      setTimeout(() => {
        if (this.disposed || this.surfaceId.length > 0) {
          return
        }
        debugLog('SingleTrack', `${this.trackId} surface 等待超时，改为无 surface 载入（只有声音）`)
        void this.reconcile(this.desired, false)
      }, SURFACE_WAIT_MAX_MS + 50)
    }
    return now < this.surfaceWaitDeadlineMs
  }

  getId(): string {
    return this.trackId
  }

  getCamera(): string {
    return this.camera
  }

  setCamera(camera: string): void {
    if (camera === this.camera) {
      return
    }
    this.camera = camera
    // 出声与否由机位决定（见 isAudioOutputTrack）：切模板会改机位，
    // 必须立刻重算音量，否则 T2→T4 会留下"该出声的没声、该静音的还在响"。
    void this.applyVolume()
  }

  setCallbacks(
    onProgressChanged?: (globalMs: number) => void,
    onBoundary?: (segmentEndMs: number) => void
  ): void {
    this.onProgress = onProgressChanged
    this.onBoundary = onBoundary
  }

  /** 绑定该机位的段序列（全局时间网格对齐）。空数组表示该槽位无源。 */
  bindSegments(segments: Array<SegmentSpan>): void {
    const next: Array<SegmentSpan> = []
    for (let i = 0; i < segments.length; i++) {
      const source = segments[i]
      if (source.uri.length === 0) {
        continue
      }
      const span = new SegmentSpan()
      span.uri = source.uri
      span.startMs = source.startMs
      span.durationMs = source.durationMs
      next.push(span)
    }
    next.sort((a: SegmentSpan, b: SegmentSpan) => a.startMs - b.startMs)

    if (this.sameSpans(next)) {
      // 段序列没变：保留当前播放状态，避免模板切换时无谓地重载。
      return
    }
    this.spans = next
    if (USE_PLAYLIST_PROBE) {
      // 段序列变了：播放列表必须重建（条目的 fd 也要重开）。
      this.resetPlaylist()
    }
    if (next.length === 0) {
      this.loadedUri = ''
      this.loadingUri = ''
      this.endedUri = ''
      this.prepared = false
      this.playing = false
      this.resetSeekTracking()
      if (this.player) {
        try {
          this.player.pause()
          this.player.reset()
        } catch (_) {}
      }
      this.closeFd()
    }
    // 段序列变了 → 立即重新对账，让"已绑定的段"与"播放器实际载入的段"在同一轮收敛。
    // 不依赖调用方随后恰好调用了 setDuration / updateClockMaster —— 旧架构正是靠这种隐式调用顺序，
    // 一旦某个调用点漏掉就表现为"切了模板但画面不动"。
    void this.reconcile(this.desired, false)
  }

  getSegments(): Array<SegmentSpan> {
    return this.spans
  }

  /** 当前已就绪的段索引；-1 表示没有就绪的段。 */
  getCurrentSegmentIndex(): number {
    // R1 探针：条目由 onPlaybackContentChanged 直接给出，不靠 uri 反查
    //（播放列表里播放器内部换条，loadedUri 不一定同步）。
    if (USE_PLAYLIST_PROBE && this.playlistIndex >= 0) {
      return this.playlistIndex
    }
    if (this.loadedUri.length === 0) {
      return -1
    }
    for (let i = 0; i < this.spans.length; i++) {
      if (this.spans[i].uri === this.loadedUri) {
        return i
      }
    }
    return -1
  }

  setSurfaceId(surfaceId: string): void {
    if (surfaceId.length === 0) {
      return
    }
    const isFirst = this.surfaceId.length === 0
    this.surfaceId = surfaceId
    if (this.player) {
      try {
        this.player.surfaceId = surfaceId
      } catch (err) {
        debugLog('SingleTrack', `${this.trackId} set surfaceId err: ${String(err)}`)
      }
    }
    if (PLAYBACK_TRACE) {
      // 这行是"第一段没画面"的决定性证据：
      // 已prepare=是 且 已绑播放器=是 → surface 来晚了，本次渲染可能不生效（见 applyDesired 的等待逻辑）。
      debugLog(
        'SingleTrack',
        `${this.trackId} 收到 surface（首次=${isFirst ? '是' : '否'} 已prepare=${this.prepared ? '是' : '否'} 已绑播放器=${this.player ? '是' : '否'}）`
      )
    }
    // surface 是后来才到的：重新对账一次。若播放器已就绪，强制 seek 让新 surface 立即渲染首帧
    void this.reconcile(this.desired, this.prepared)
  }

  /**
   * **唯一**的对账入口。幂等：同一个 desired 重复调用无副作用。
   * forceSeek = true 时无视偏移容差强制 seek（用户拖动/点击跳转走这条路）。
   */
  reconcile(desired: DesiredState, forceSeek: boolean = false): Promise<void> {
    this.desired = desired
    this.playbackRate = desired.rate > 0 ? desired.rate : 1
    if (this.disposed) {
      return Promise.resolve()
    }
    if (forceSeek) {
      this.reconcileForceSeek = true
    }
    if (this.reconcileRunning) {
      this.reconcileDirty = true
      return this.reconcileLoop
    }
    this.reconcileLoop = this.drain()
    return this.reconcileLoop
  }

  async setGlobalMuted(muted: boolean): Promise<void> {
    this.globalMuted = muted
    await this.applyVolume()
  }

  async setPlaybackRate(rate: number): Promise<void> {
    this.playbackRate = Math.max(0.75, Math.min(2, rate))
    await this.applyPlaybackRate()
  }

  async release(): Promise<void> {
    this.disposed = true
    if (PLAYBACK_TRACE) {
      // 一场播放的总结：换源次数 / 强制 seek / 漂移 seek / 最差上报间隔。
      // 对"偶尔才出现、现在又没了"的问题，这一行就能判断这次有没有异常。
      debugLog(
        'SingleTrack',
        `${this.trackId} 会话总结：换源=${this.traceLoadCount} 强制seek=${this.traceSeekForceCount} 漂移seek=${this.traceSeekDriftCount} 最差上报间隔=${this.traceWorstReportGapMs}ms`
      )
    }
    this.desired = new DesiredState()
    this.onProgress = undefined
    this.onBoundary = undefined
    this.resetPlaylist()
    this.closeFd()
    const player = this.player
    this.player = undefined
    this.prepared = false
    this.loadedUri = ''
    this.loadingUri = ''
    this.playing = false
    this.resetSeekTracking()
    if (player) {
      try {
        await player.release()
      } catch (_) {}
    }
    // 播放器已经释放，这时才能安全关掉列表条目的 fd。
    this.closePlaylistFds()
  }

  // ------------------------------------------------------------------
  // 内部：对账循环
  // ------------------------------------------------------------------

  private async drain(): Promise<void> {
    this.reconcileRunning = true
    do {
      this.reconcileDirty = false
      const forceSeek = this.reconcileForceSeek
      this.reconcileForceSeek = false
      try {
        await this.applyDesired(forceSeek)
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err)
        debugLog('SingleTrack', `${this.trackId} reconcile error: ${message}`)
      }
    } while (this.reconcileDirty && !this.disposed)
    this.reconcileRunning = false
  }

  private async applyDesired(forceSeek: boolean): Promise<void> {
    if (this.disposed) {
      return
    }
    await this.ensurePlayer()
    if (!this.player || this.disposed) {
      return
    }

    if (USE_PLAYLIST_PROBE && !this.playlistFailed) {
      await this.applyDesiredViaPlaylist(forceSeek)
      return
    }

    const target: SegmentTarget = segmentAt(this.spans, this.desired.globalMs)
    const wantedUri = this.resolveWantedUri(target)
    const wantedOffsetMs = this.resolveWantedOffsetMs(target, wantedUri)

    if (wantedUri.length === 0) {
      // 该槽位无源（或开头即空洞）：停住并保持上一帧，绝不 reset（reset 会黑闪）。
      this.syncPlayState(false)
      return
    }

    // 必须**先拿到视频 surface 再载入**（理由与上限见 shouldWaitForSurface）。
    // setSurfaceId() 会再次触发对账，所以这里直接返回、等它来驱动即可。
    if (this.shouldWaitForSurface()) {
      return
    }

    if (this.loadedUri !== wantedUri) {
      if (this.loadingUri === wantedUri) {
        // 已经在载入同一个文件，等 prepared 事件回来再对账。
        return
      }
      await this.beginLoad(wantedUri)
      return
    }

    if (!this.prepared) {
      // 文件已就位但还没 prepared，等事件。
      return
    }

    if (this.endedUri === wantedUri && !forceSeek) {
      // 该段已播到末尾：保持末帧，等时钟越过边界后自然会换到下一段。
      return
    }

    if (this.seekInFlight && !forceSeek) {
      // seek 在飞：不要插队，等 seekDone 再对账。
      // 但 seekDone 可能永远不来（seek 被拒/丢失）→ 先让看门狗解卡，否则整轨死锁。
      if (!this.releaseStuckSeekIfNeeded()) {
        return
      }
    }

    // 偏差基准是播放器**实际**位置（observedOffsetMs），不是"上次 seek 的目标"。
    const now = Date.now()
    const elapsedMs = this.lastSeekCheckAtMs > 0 ? now - this.lastSeekCheckAtMs : 0
    this.lastSeekCheckAtMs = now
    const check = checkSeek(this.observedOffsetMs, wantedOffsetMs, forceSeek, this.driftHeldMs, elapsedMs)
    this.driftHeldMs = check.nextDriftHeldMs
    this.traceLastDriftMs = this.observedOffsetMs - wantedOffsetMs
    if (check.seek) {
      if (!this.playerAcceptsSeek(this.player)) {
        // 还没到可 seek 的状态：硬 seek 会被拒，而 seekDone 不会来。
        // 等 'prepared'/'seekDone' 事件再次对账即可。
        return
      }
      this.issueSeek(wantedOffsetMs, forceSeek ? 'force' : 'drift')
      return
    }

    this.syncPlayState(this.desired.playing)
  }

  /**
   * R1 探针：播放列表路径的对账。
   *
   * 与 reset 路径的关键区别：**换段不再拆引擎**。
   *   - 播放器自己会按列表顺序接续（这正是要验证的"无缝"行为），
   *     因此这里只在该纠正时才调 advanceToMediaSource；
   *   - 偏差纠正仍在当前条目内用 seek()。
   */
  private async applyDesiredViaPlaylist(forceSeek: boolean): Promise<void> {
    if (this.spans.length === 0) {
      this.syncPlayState(false)
      return
    }
    // 与 reset 路径同一条不变量：surface 到手之前不建表、不 prepare（理由见 shouldWaitForSurface）。
    if (this.shouldWaitForSurface()) {
      return
    }
    await this.ensurePlaylist()
    const player = this.player
    if (!this.playlistReady || !player) {
      return
    }

    const target: SegmentTarget = segmentAt(this.spans, this.desired.globalMs)
    const holdIndex = gapHoldIndex(target)
    if (holdIndex < 0) {
      // 开头即空洞：没有可显示的内容。
      this.syncPlayState(false)
      return
    }
    const wantedOffsetMs = target.kind === SegmentKind.CONTENT
      ? Math.max(0, Math.floor(target.offsetMs))
      : Math.max(0, this.spans[holdIndex].durationMs - 1)

    // 播放器通常已自动接续到下一条（这正是要验证的行为）；只在必要时纠正：
    //   - playlistIndex 未知 → 直接跳；
    //   - 目标就是下一条且播放器已 completed（说明它**没有**自动接续）→ advanceToNextMediaSource；
    //   - 目标与当前条目相差超过一条，或是强制跳转 → advanceToMediaSource 精确跳。
    let needAdvance = false
    let useNext = false
    if (this.playlistIndex < 0) {
      needAdvance = true
    } else if (holdIndex !== this.playlistIndex) {
      if (forceSeek) {
        needAdvance = true
      } else if (holdIndex === this.playlistIndex + 1) {
        let playerState = ''
        try {
          playerState = player.state
        } catch (_) {}
        if (playerState === 'completed') {
          needAdvance = true
          useNext = true
        }
      } else if (Math.abs(holdIndex - this.playlistIndex) > 1) {
        needAdvance = true
      }
    }
    if (needAdvance) {
      // 关键：**prepare 还没回来时绝不能 advance**。
      // 真机日志（第六份）就是这么崩的：`ensurePlaylist()` 末尾刚调完 prepare()，
      // 本函数紧接着 advanceToMediaSource()，播放器回
      // "current state is not prepared, unsupport AdvanceToMediaSource"，
      // 紧接着这次失败又把 seek 拖下水 → 整轨死锁。
      // 正确做法：等 'prepared' 事件再次对账（那时 playlistIndex 已由 getCurrentMediaSource 填好，
      // 通常也就**不再需要** advance 了）。
      if (!this.playerAcceptsSeek(player)) {
        return
      }
      if (useNext) {
        this.playlistAdvanceRequestedAtMs = Date.now()
        try {
          await player.advanceToNextMediaSource()
          this.playlistIndex = holdIndex
          this.playlistAdvanceFailCount = 0
          this.seekInFlight = false
          this.seekIssuedAtMs = 0
          this.resetSeekTracking()
          debugLog('SingleTrack', `${this.trackId} playlist: 播放器未自动接续，改用 advanceToNextMediaSource span=${holdIndex}`)
        } catch (err) {
          this.playlistAdvanceFailCount += 1
          debugLog('SingleTrack', `${this.trackId} playlist: advanceToNextMediaSource 失败 ${String(err)}`)
        }
      } else {
        await this.advanceToPlaylistItem(holdIndex)
      }
      if (this.playlistAdvanceFailCount > PLAYLIST_ADVANCE_FAIL_LIMIT) {
        this.abandonPlaylist('advance 连续失败')
        return
      }
    }

    if (this.seekInFlight && !forceSeek) {
      if (!this.releaseStuckSeekIfNeeded()) {
        return
      }
    }

    const now = Date.now()
    const elapsedMs = this.lastSeekCheckAtMs > 0 ? now - this.lastSeekCheckAtMs : 0
    this.lastSeekCheckAtMs = now
    const check = checkSeek(this.observedOffsetMs, wantedOffsetMs, forceSeek, this.driftHeldMs, elapsedMs)
    this.driftHeldMs = check.nextDriftHeldMs
    this.traceLastDriftMs = this.observedOffsetMs - wantedOffsetMs
    if (check.seek) {
      if (!this.playerAcceptsSeek(player)) {
        return
      }
      this.issueSeek(wantedOffsetMs, forceSeek ? 'playlist-force' : 'playlist-drift')
      return
    }

    this.syncPlayState(this.desired.playing)
  }

  /**
   * 放弃播放列表，退回 reset 路径。
   * reset 路径有"报错后下一轮重试"的能力（旧日志里 hevc 报错重试即成功），
   * 所以这是探针唯一的兜底出口 —— 保证最坏情况只是"没量到数字"，不会把预览跑死。
   */
  private abandonPlaylist(reason: string): void {
    if (this.playlistFailed) {
      return
    }
    debugLog('SingleTrack', `${this.trackId} playlist: ${reason}，退回 reset 路径`)
    this.playlistFailed = true
    this.playlistReady = false
    this.playlistBuilding = false
    this.playlistPreparePending = false
    this.playlistIds = []
    this.playlistSpanIndex = []
    this.playlistIndex = -1
    this.playlistAdvanceFailCount = 0
    this.seekInFlight = false
    this.seekIssuedAtMs = 0
    // fd 不能在这里关：播放器可能还持有这些 MediaSource。
    // 交给 release() 或下一次 ensurePlaylist() 的 clearPlaybackList() 之后关。
    void this.reconcile(this.desired, false)
  }

  /**
   * 目标文件：
   *   CONTENT → 该段自身；
   *   GAP     → 保持上一内容段（gapHoldIndex），开头即空洞时返回 ''（黑场）。
   */
  private resolveWantedUri(target: SegmentTarget): string {
    if (this.spans.length === 0) {
      return ''
    }
    const index = gapHoldIndex(target)
    if (index < 0 || index >= this.spans.length) {
      return ''
    }
    return this.spans[index].uri
  }

  /**
   * 目标偏移：
   *   CONTENT → 段内偏移；
   *   GAP     → 停在上一段的**末帧**（时长 - 1ms），画面冻结在最后一帧。
   */
  private resolveWantedOffsetMs(target: SegmentTarget, wantedUri: string): number {
    if (wantedUri.length === 0) {
      return 0
    }
    if (target.kind === SegmentKind.CONTENT) {
      return Math.max(0, Math.floor(target.offsetMs))
    }
    const index = gapHoldIndex(target)
    if (index < 0 || index >= this.spans.length) {
      return 0
    }
    return Math.max(0, this.spans[index].durationMs - 1)
  }

  private async beginLoad(uri: string): Promise<void> {
    const player = this.player
    if (!player) {
      return
    }
    this.loadingUri = uri
    this.loadedUri = ''
    this.prepared = false
    this.playing = false
    this.endedUri = ''
    this.resetSeekTracking()
    this.seekInFlight = false
    // 追踪：换段从这里开始计时。reset() + openSync + fdSrc + prepare() 全程都是"没有画面/没有声音"的。
    this.traceLoadStartedAtMs = Date.now()
    this.tracePreparedAtMs = 0
    this.tracePlayRequestedAtMs = 0
    this.traceAwaitingFirstReport = true
    this.traceLoadCount += 1
    this.traceLastReportAtMs = 0
    this.traceReportCount = 0
    this.traceIntervalSumMs = 0
    this.traceIntervalMaxMs = 0
    debugLog('SingleTrack', `${this.trackId} loading source: ${uri}`)

    try {
      await player.reset()
    } catch (_) {}
    this.closeFd()
    if (this.disposed || !this.player || this.player !== player) {
      return
    }

    if (uri.startsWith('file://')) {
      try {
        const file = fs.openSync(uri, fs.OpenMode.READ_ONLY)
        this.openedFd = file.fd
        player.fdSrc = { fd: file.fd }
      } catch (err) {
        debugLog('SingleTrack', `${this.trackId} openSync/fdSrc failed: ${String(err)}`)
        this.closeFd()
        this.loadingUri = ''
      }
    } else {
      try {
        player.url = uri
      } catch (err) {
        debugLog('SingleTrack', `${this.trackId} set url failed: ${String(err)}`)
        this.loadingUri = ''
      }
    }
    // 不再 await "等就绪"：prepared 事件到了会重新对账。
  }

  // ------------------------------------------------------------------
  // R1 探针：播放列表路径（USE_PLAYLIST_PROBE）
  // ------------------------------------------------------------------

  /**
   * 把本机位的全部切片建成播放列表，然后 prepare 一次。
   * 之后换段只需要 advanceToMediaSource/advanceToNextMediaSource，不再 reset()。
   */
  private async ensurePlaylist(): Promise<void> {
    const player = this.player
    if (!player || this.playlistReady || this.playlistBuilding || this.spans.length === 0) {
      // playlistBuilding 是重入闸：对账循环可能在建表期间再次进来，
      // 若不拦，第二次会 clearPlaybackList() 把第一次正在加的条目清掉。
      return
    }
    this.playlistBuilding = true
    try {
      try {
        await player.clearPlaybackList()
      } catch (_) {}
      this.closePlaylistFds()
      const ids: Array<string> = []
      const indexMap: Array<number> = []
      for (let i = 0; i < this.spans.length; i++) {
        const uri = this.spans[i].uri
        if (!uri.startsWith('file://')) {
          continue
        }
        try {
          const file = fs.openSync(uri, fs.OpenMode.READ_ONLY)
          const fd = file.fd
          // @SuppressWarnings syscap
          const src = media.createMediaSourceWithFd({ fd: fd })
          if (!src) {
            fs.closeSync(fd)
            debugLog('SingleTrack', `${this.trackId} playlist: createMediaSourceWithFd 返回空 i=${i}`)
            continue
          }
          const id = await player.addPlaybackMediaSource(src)
          ids.push(id)
          indexMap.push(i)
          this.playlistFds.push(fd)
        } catch (err) {
          debugLog('SingleTrack', `${this.trackId} playlist: 加入第 ${i} 条失败 ${String(err)}`)
        }
      }
      this.playlistIds = ids
      this.playlistSpanIndex = indexMap
      this.playlistReady = ids.length > 0
      this.playlistFailed = !this.playlistReady
      debugLog(
        'SingleTrack',
        `${this.trackId} playlist: 建列表完成 条目=${ids.length}/${this.spans.length} fd=${this.playlistFds.length}`
      )
    } finally {
      this.playlistBuilding = false
      // 列表加完了才 prepare（且只 prepare 一次）：
      // 加第一条时播放器就会进 initialized，那时必须忍住不 prepare，否则只会准备到第一条。
      // 注意：surface 与播放策略原本在 'initialized' 分支里设置，而那个分支在"建表期间"被抑制了，
      // 建完表状态已经是 initialized、不会再触发一次 —— 必须在这里补上，否则：
      //   surface 没绑 → 画面黑；playlistLoopMode 保持默认的 ALL → 整趟行程会循环。
      const current = this.player
      if (this.playlistReady && current) {
        let state = ''
        try {
          state = current.state
        } catch (_) {}
        if (this.playlistPreparePending || state === 'initialized') {
          this.playlistPreparePending = false
          if (this.surfaceId.length > 0) {
            try {
              current.surfaceId = this.surfaceId
            } catch (err) {
              debugLog('SingleTrack', `${this.trackId} playlist: 绑 surface 失败 ${String(err)}`)
            }
          }
          try {
            const dynamicPlayer = current as Object
            const setStrategy = (dynamicPlayer as Record<string, (opt: PlaybackStrategyOptions) => void>)['setPlaybackStrategy']
            if (typeof setStrategy === 'function') {
              const strategyOpt: PlaybackStrategyOptions = { showFirstFrameOnPrepare: true }
              // @SuppressWarnings syscap
              strategyOpt.playlistLoopMode = media.PlaylistLoopMode.PLAYLIST_LOOP_MODE_NONE
              setStrategy(strategyOpt)
              debugLog('SingleTrack', `${this.trackId} playlist: 策略已设 playlistLoopMode=NONE`)
            }
          } catch (err) {
            debugLog('SingleTrack', `${this.trackId} playlist: setPlaybackStrategy 失败 ${String(err)}`)
          }
          try {
            current.prepare()
          } catch (err) {
            debugLog('SingleTrack', `${this.trackId} playlist: prepare 失败 ${String(err)}`)
          }
        } else {
          debugLog('SingleTrack', `${this.trackId} playlist: 加完条目后状态=${state}，未 prepare（可能需人工确认）`)
        }
      }
    }
  }

  /** 跳到指定 spans 下标对应的播放列表条目。 */
  private async advanceToPlaylistItem(spanIndex: number): Promise<void> {
    const player = this.player
    if (!player) {
      return
    }
    const pos = this.playlistSpanIndex.indexOf(spanIndex)
    if (pos < 0) {
      return
    }
    this.playlistAdvanceRequestedAtMs = Date.now()
    try {
      await player.advanceToMediaSource(this.playlistIds[pos])
      this.playlistIndex = spanIndex
      this.playlistAdvanceFailCount = 0
      this.seekInFlight = false
      this.seekIssuedAtMs = 0
      this.resetSeekTracking()
    } catch (err) {
      this.playlistAdvanceFailCount += 1
      debugLog('SingleTrack', `${this.trackId} playlist: advanceToMediaSource 失败 ${String(err)}`)
    }
  }

  private closePlaylistFds(): void {
    for (let i = 0; i < this.playlistFds.length; i++) {
      try {
        fs.closeSync(this.playlistFds[i])
      } catch (_) {}
    }
    this.playlistFds = []
  }

  /**
   * 丢弃播放列表的**映射关系**（不清 fd）。
   * 顺序很重要：播放器还持有这些 MediaSource 时不能关 fd，
   * 必须等 ensurePlaylist 里 clearPlaybackList() 之后才能关。
   */
  private resetPlaylist(): void {
    this.playlistIds = []
    this.playlistSpanIndex = []
    this.playlistReady = false
    this.playlistFailed = false
    this.playlistIndex = -1
    this.playlistAdvanceRequestedAtMs = 0
  }

  /**
   * 播放器此刻是否接受 seek() / advanceToMediaSource()。
   *
   * 真机日志（第五份）证明这两个接口对状态很敏感：
   *   `seek` → "Operate Not Permit: The current state is initialized, seek operation only
   *            support prepared/playing/paused/completed state."
   *   `advanceToMediaSource` → "BusinessError: current state is not prepared, unsupport
   *            AdvanceToMediaSource"
   * 而 `seek` 被拒之后 `seekDone` 不会触发，`seekInFlight` 就永久卡住 → 整轨死锁。
   * 所以调用前必须先问状态。
   */
  private playerAcceptsSeek(player: media.AVPlayer): boolean {
    let state = ''
    try {
      state = player.state
    } catch (_) {
      return false
    }
    return state === 'prepared' || state === 'playing' || state === 'paused' || state === 'completed'
  }

  /**
   * seek 看门狗。正常 seek 在 100ms 量级完成；超过阈值说明 `seekDone` 丢了或被拒，
   * 必须主动解卡，否则该轨（若还是主轨，则整条时间轴）永久不动。
   */
  private releaseStuckSeekIfNeeded(): boolean {
    if (!this.seekInFlight) {
      return false
    }
    const issuedAt = this.seekIssuedAtMs
    if (issuedAt <= 0 || Date.now() - issuedAt <= SEEK_STUCK_MS) {
      return false
    }
    debugLog(
      'SingleTrack',
      `${this.trackId} seek 超过 ${SEEK_STUCK_MS}ms 未完成（seekDone 丢失或被拒），强制解卡`
    )
    this.seekInFlight = false
    this.seekIssuedAtMs = 0
    this.resetSeekTracking()
    return true
  }

  private issueSeek(offsetMs: number, reason: string = ''): void {
    const player = this.player
    if (!player) {
      return
    }
    const clamped = Math.max(0, Math.floor(offsetMs))
    this.seekInFlight = true
    this.seekIssuedAtMs = Date.now()
    this.driftHeldMs = 0
    if (reason.indexOf('force') >= 0) {
      this.traceSeekForceCount += 1
    } else {
      this.traceSeekDriftCount += 1
    }
    try {
      // 必须是 SEEK_CLOSEST(=2)：精确落到指定位置。
      // 绝不能用 SEEK_PREV_SYNC(=1)——那是"退到上一个关键帧"，DVR 的 GOP 常有 1~2 秒，
      // 于是每次 seek 都落在目标**之前**，播放头要等播放器追上来才能继续前进（进度条卡住），
      // 同时解码器被反复冲刷（声音断续）。
      // @SuppressWarnings syscap
      player.seek(clamped, media.SeekMode.SEEK_CLOSEST)
      // 乐观更新：在播放器回报实际位置之前，命令值就是我们对当前位置的最佳估计。
      this.observedOffsetMs = clamped
      // 每次 seek 都会冲刷解码器（听感=声音断续），且 seekDone 之前 timeUpdate 不上报
      // （观感=进度条卡住，见 @ohos.multimedia.media.d.ts:3439）。
      // 因此"播放中到底 seek 了几次、为什么 seek"必须可观测。
      debugLog(
        'SingleTrack',
        `${this.trackId} seek(${clamped}) reason=${reason.length > 0 ? reason : 'unknown'} drift=${Math.round(this.traceLastDriftMs)}ms`
      )
    } catch (err) {
      debugLog('SingleTrack', `${this.trackId} seek failed: ${String(err)}`)
      this.seekInFlight = false
    }
  }

  private syncPlayState(shouldPlay: boolean): void {
    const player = this.player
    if (!player) {
      return
    }
    if (shouldPlay === this.playing) {
      return
    }
    try {
      if (shouldPlay) {
        player.play()
        this.playing = true
        // 追踪：真正的"该出声了"时刻。换段静音要量的是"从 play() 到第一帧/第一个上报"，
        // 而不是"从 beginLoad"——否则用户按播放前的思考时间会被算进静音时长。
        if (this.traceAwaitingFirstReport && this.tracePlayRequestedAtMs === 0) {
          this.tracePlayRequestedAtMs = Date.now()
        }
        if (PLAYBACK_TRACE) {
          debugLog('SingleTrack', `${this.trackId} play()`)
        }
      } else {
        player.pause()
        this.playing = false
        if (PLAYBACK_TRACE) {
          debugLog('SingleTrack', `${this.trackId} pause()`)
        }
      }
    } catch (err) {
      debugLog('SingleTrack', `${this.trackId} ${shouldPlay ? 'play' : 'pause'} failed: ${String(err)}`)
    }
  }

  /** 重新载入 / 就绪后播放器回到文件开头：seek 追踪必须一起清零。 */
  private resetSeekTracking(): void {
    this.observedOffsetMs = 0
    this.driftHeldMs = 0
    this.lastSeekCheckAtMs = 0
  }

  private sameSpans(next: Array<SegmentSpan>): boolean {
    if (this.spans.length !== next.length) {
      return false
    }
    for (let i = 0; i < next.length; i++) {
      if (
        this.spans[i].uri !== next[i].uri ||
        this.spans[i].startMs !== next[i].startMs ||
        this.spans[i].durationMs !== next[i].durationMs
      ) {
        return false
      }
    }
    return true
  }

  private async ensurePlayer(): Promise<void> {
    if (this.player || this.disposed) {
      return
    }
    if (!canIUse('SystemCapability.Multimedia.Media.AVPlayer')) {
      debugLog('SingleTrack', `${this.trackId} AVPlayer capability not supported on current device`)
      return
    }
    try {
      // @SuppressWarnings syscap
      const player = await media.createAVPlayer()
      if (this.disposed) {
        try {
          await player.release()
        } catch (_) {}
        return
      }
      this.player = player
      this.bindPlayerEvents(player)
      if (this.surfaceId.length > 0) {
        try {
          player.surfaceId = this.surfaceId
        } catch (_) {}
      }
    } catch (err) {
      debugLog('SingleTrack', `${this.trackId} createAVPlayer failed: ${String(err)}`)
      this.player = undefined
    }
  }

  private closeFd(): void {
    if (this.openedFd !== undefined && this.openedFd >= 0) {
      try {
        fs.closeSync(this.openedFd)
      } catch (_) {}
    }
    this.openedFd = undefined
  }

  // ------------------------------------------------------------------
  // 内部：事件只做通知 + 重新触发对账，不做任何决策
  // ------------------------------------------------------------------

  private bindPlayerEvents(player: media.AVPlayer): void {
    player.on('stateChange', (state: media.AVPlayerState) => {
      if (this.disposed || this.player !== player) {
        return
      }
      debugLog('SingleTrack', `${this.trackId} state -> ${state}`)
      if (state === 'initialized') {
        if (this.surfaceId.length > 0) {
          try {
            player.surfaceId = this.surfaceId
          } catch (_) {}
        }
        // R1 探针：列表还没加完，先不要 prepare（等 ensurePlaylist 自己调）。
        if (USE_PLAYLIST_PROBE && this.playlistBuilding) {
          this.playlistPreparePending = true
          return
        }
        try {
          const dynamicPlayer = player as Object
          const setStrategy = (dynamicPlayer as Record<string, (opt: PlaybackStrategyOptions) => void>)['setPlaybackStrategy']
          if (typeof setStrategy === 'function') {
            const strategyOpt: PlaybackStrategyOptions = { showFirstFrameOnPrepare: true }
            if (USE_PLAYLIST_PROBE) {
              // 默认是 PLAYLIST_LOOP_MODE_ALL（循环整个列表），行程播放必须关掉。
              // @SuppressWarnings syscap
              strategyOpt.playlistLoopMode = media.PlaylistLoopMode.PLAYLIST_LOOP_MODE_NONE
            }
            setStrategy(strategyOpt)
          }
        } catch (_) {}
        try {
          player.prepare()
        } catch (err) {
          debugLog('SingleTrack', `${this.trackId} prepare failed: ${String(err)}`)
        }
        return
      }

      if (state === 'prepared') {
        this.prepared = true
        this.loadedUri = this.loadingUri
        this.loadingUri = ''
        this.endedUri = ''
        this.resetSeekTracking()
        if (USE_PLAYLIST_PROBE && this.playlistReady) {
          // 播放列表路径不经过 beginLoad，loadedUri 永远是空；
          // 这里主动问一次"当前条目是谁"，否则 playlistIndex 会一直是 -1、进度不上报。
          // 必须先确认 playlistReady：已退回 reset 路径时播放列表已废弃，
          // 这时再问会报 "Operate Not Permit: unsupport get current mediaSource operation"。
          try {
            const current = player.getCurrentMediaSource()
            const currentId = current ? current.getID() : ''
            const pos = currentId.length > 0 ? this.playlistIds.indexOf(currentId) : -1
            if (pos >= 0) {
              this.playlistIndex = this.playlistSpanIndex[pos]
            }
            debugLog('SingleTrack', `${this.trackId} playlist: prepared 当前条目 id=${currentId} span=${this.playlistIndex}`)
          } catch (err) {
            debugLog('SingleTrack', `${this.trackId} playlist: getCurrentMediaSource 失败 ${String(err)}`)
          }
        }
        this.tracePreparedAtMs = Date.now()
        if (PLAYBACK_TRACE) {
          const prepareMs = this.traceLoadStartedAtMs > 0 ? this.tracePreparedAtMs - this.traceLoadStartedAtMs : -1
          debugLog('SingleTrack', `${this.trackId} 换段 prepare 耗时=${prepareMs}ms uri=${this.loadedUri}`)
        }
        try {
          // FIT_CROP：等比例裁剪填充，避免画面被拉伸变形
          player.videoScaleType = 1 as media.VideoScaleType
        } catch (_) {}
        void this.applyVolume()
        void this.applyPlaybackRate()
        // 就绪后重新对账：强制 seek 定位到当前播放头（确保即使在 0ms 也能强制解码首帧出画，避免黑屏）
        void this.reconcile(this.desired, true)
        return
      }

      if (state === 'completed') {
        // 只上报边界，**不**自己换段（换段由协调器在对账时统一决定）。
        this.endedUri = this.loadedUri
        this.playing = false
        const index = this.getCurrentSegmentIndex()
        let segmentEndMs = 0
        if (index >= 0 && index < this.spans.length) {
          segmentEndMs = this.spans[index].startMs + this.spans[index].durationMs
        }
        debugLog('SingleTrack', `${this.trackId} segment completed: ${this.loadedUri} end=${segmentEndMs}`)
        if (this.onBoundary) {
          this.onBoundary(segmentEndMs)
        }
        return
      }

      if (state === 'error') {
        this.prepared = false
        this.loadingUri = ''
        this.seekInFlight = false
        this.seekIssuedAtMs = 0
        debugLog('SingleTrack', `${this.trackId} state error`)
        if (USE_PLAYLIST_PROBE) {
          // 探针期间播放器报错（真机出现过 hevc 报错）：不放弃的话这一轨会永久停在 error，
          // 而 reset 路径本来就有"下一轮重试"的能力，所以直接退回去。
          this.abandonPlaylist('播放器进入 error')
        }
      }
    })

    player.on('seekDone', () => {
      if (this.disposed || this.player !== player) {
        return
      }
      this.seekInFlight = false
      // seek 完成后再对账一次：此时才会真正 play（避免"seek 未完成就开始播"导致画面回跳）。
      void this.reconcile(this.desired, false)
    })

    // R1 探针：播放列表换条通知。回调携带"正在播放的条目 ID"。
    // 这里同时打印换条耗时与"距上一次上报的墙钟间隔" —— 后者就是换条静音时长的直接证据。
    player.onPlaybackContentChanged((id: string) => {
      if (this.disposed || this.player !== player) {
        return
      }
      const pos = this.playlistIds.indexOf(id)
      const spanIndex = pos >= 0 ? this.playlistSpanIndex[pos] : -1
      if (spanIndex >= 0) {
        this.playlistIndex = spanIndex
      }
      if (PLAYBACK_TRACE) {
        const nowMs = Date.now()
        const sinceRequest = this.playlistAdvanceRequestedAtMs > 0
          ? nowMs - this.playlistAdvanceRequestedAtMs
          : -1
        const silenceMs = this.playlistLastReportAtMs > 0
          ? nowMs - this.playlistLastReportAtMs
          : -1
        debugLog(
          'SingleTrack',
          `${this.trackId} ★播放列表换条 id=${id} span=${spanIndex} 距请求=${sinceRequest}ms 距末次上报=${silenceMs}ms`
        )
      }
      void this.reconcile(this.desired, false)
    })

    player.on('timeUpdate', (timeMs: number) => {
      if (this.disposed || this.player !== player) {
        return
      }
      if (USE_PLAYLIST_PROBE) {
        // 播放列表路径：没有 loadedUri/endedUri 概念，只用 prepared + seek 抑制。
        if (!this.prepared || this.seekInFlight) {
          return
        }
      } else {
        if (this.loadedUri.length === 0 || !this.prepared) {
          return
        }
        if (this.seekInFlight || this.loadingUri.length > 0 || this.endedUri === this.loadedUri) {
          // 载入/seek/已播完期间不上报：否则会把旧位置的进度当成当前位置，
          // 让全局播放头被"迟到的回调"拽回去。这是旧架构最典型的 bug。
          return
        }
      }
      const index = this.getCurrentSegmentIndex()
      if (index < 0) {
        return
      }
      const span = this.spans[index]
      const safeTimeMs = Math.max(0, Math.floor(timeMs))

      // ---- 追踪（仅日志）：换段静音总时长 + 上报节奏 ----
      if (PLAYBACK_TRACE) {
        const nowMs = Date.now()
        this.playlistLastReportAtMs = nowMs
        if (this.traceAwaitingFirstReport) {
          this.traceAwaitingFirstReport = false
          const totalMs = this.traceLoadStartedAtMs > 0 ? nowMs - this.traceLoadStartedAtMs : -1
          const prepareMs = this.tracePreparedAtMs > 0 && this.traceLoadStartedAtMs > 0
            ? this.tracePreparedAtMs - this.traceLoadStartedAtMs
            : -1
          const fromPlayMs = this.tracePlayRequestedAtMs > 0 ? nowMs - this.tracePlayRequestedAtMs : -1
          // ★ 换段静音时长 = fromPlayMs（从 play() 到第一帧真正开始走表）。
          // totalMs 会包含"prepared 之后用户还没点播放"的空转时间，不能当静音时长用。
          debugLog(
            'SingleTrack',
            `${this.trackId} ★换段静音=${fromPlayMs}ms（距prepare=${this.tracePreparedAtMs > 0 ? nowMs - this.tracePreparedAtMs : -1}ms prepare=${prepareMs}ms 距load=${totalMs}ms）uri=${this.loadedUri}`
          )
        }
        if (this.traceLastReportAtMs > 0) {
          const deltaMs = nowMs - this.traceLastReportAtMs
          this.traceIntervalSumMs += deltaMs
          if (deltaMs > this.traceIntervalMaxMs) {
            this.traceIntervalMaxMs = deltaMs
          }
          if (deltaMs > this.traceWorstReportGapMs) {
            this.traceWorstReportGapMs = deltaMs
          }
        }
        this.traceLastReportAtMs = nowMs
        this.traceReportCount += 1
        // timeUpdate 官方默认 100ms 一次；这里每 20 次（约 2s）汇总一次，
        // 短时间试播也能看出"进度条/声音"的节奏有没有被拖长。
        if (this.traceReportCount % 20 === 0) {
          const avgMs = Math.round(this.traceIntervalSumMs / Math.max(1, this.traceReportCount - 1))
          debugLog(
            'SingleTrack',
            `${this.trackId} 上报节奏 平均=${avgMs}ms 最大=${this.traceIntervalMaxMs}ms 样本=${this.traceReportCount}`
          )
        }
      }

      // 记录播放器的**实际**位置：下一轮对账用它判断要不要 seek。
      this.observedOffsetMs = safeTimeMs
      const globalMs = span.startMs + safeTimeMs
      if (this.onProgress) {
        this.onProgress(globalMs)
      }
    })

    player.on('error', (err: Object) => {
      const message = err instanceof Error ? err.message : String(err)
      debugLog('SingleTrack', `${this.trackId} player error: ${message}`)
    })

    // 播放器自带的指标（API 23）：里面就有 STALLING_COUNT / TOTAL_STALLING_TIME /
    // LIP_ASYNC_COUNT / TOTAL_LIP_ASYNC_TIME / PREPARE_DURATION 等，
    // 是"声音断断续续 / 音画不同步"最直接的**平台侧**证据，不用我们自己猜。
    player.onMetricsEvent((events: Array<media.AVMetricsEvent>) => {
      if (this.disposed || this.player !== player || !PLAYBACK_TRACE) {
        return
      }
      for (let i = 0; i < events.length; i++) {
        const item = events[i]
        let detailText = ''
        try {
          detailText = JSON.stringify(item.details)
        } catch (_) {
          detailText = ''
        }
        debugLog(
          'SingleTrack',
          `${this.trackId} metrics event=${item.event} pos=${item.playbackPosition} details=${detailText}`
        )
      }
    })
  }

  private async applyVolume(): Promise<void> {
    const player = this.player
    if (!player || !this.prepared) {
      // 注意：这里**静默丢弃**了本次音量意图。prepared 之后还会再调一次（prepared 分支里），
      // 所以正常路径没问题；但排查"某一轨没声音"时必须能看到这条日志。
      if (PLAYBACK_TRACE) {
        debugLog(
          'SingleTrack',
          `${this.trackId} 音量跳过（player=${player ? '有' : '无'} prepared=${this.prepared}）`
        )
      }
      return
    }
    const allowAudio = this.isAudioOutputTrack() && !this.globalMuted
    try {
      await player.setVolume(allowAudio ? 1 : 0)
      if (PLAYBACK_TRACE) {
        debugLog(
          'SingleTrack',
          `${this.trackId} 音量=${allowAudio ? 1 : 0}（机位=${this.camera} 出声轨=${this.isAudioOutputTrack() ? '是' : '否'} 全局静音=${this.globalMuted}）`
        )
      }
    } catch (err) {
      debugLog('SingleTrack', `${this.trackId} setVolume 失败: ${String(err)}`)
    }
  }

  private async applyPlaybackRate(): Promise<void> {
    const player = this.player
    if (!player || !this.prepared) {
      return
    }
    try {
      // 映射表在 SegmentModel 里（纯模块，带离线用例）：原来这里自己写 if/else，
      // 漏了 1.5x（SPEED_FORWARD_1_50_X = 6），1.5 被当成 1.25x 播，导致预览与导出不一致。
      const speedEnum = speedEnumForRate(this.playbackRate) as media.PlaybackSpeed
      await player.setSpeed(speedEnum)
    } catch (_) {}
  }
}
