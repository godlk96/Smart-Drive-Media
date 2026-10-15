import { PreviewSeekRequest } from '../model/AppState'
import { normalizeCameraNameById } from '../constants/AppConstants'
import { DvrMeta, TripSnapshot } from '../model/TripModels'
import { GlobalTimelineManager } from '../media/GlobalTimelineManager'
import { SingleTrackController } from '../media/SingleTrackController'
import { SegmentSpan, TimeGrid, buildSegmentSpans, buildTimeGrid } from '../media/TimelineMath'
import { MAX_PREVIEW_SLOTS, SlotGeometry, buildSlotGeometry, templateAspectRatio } from '../media/PreviewLayout'
import { SingleTrackView } from './SingleTrackView'
import { debugLog } from '../utils/Logger'

interface PersistentSlotState {
  index: number
  visible: boolean
  camera: string
  x: number
  y: number
  width: number
  height: number
  zoomX: number
  hasSource: boolean
  controller: SingleTrackController
}

/**
 * 预览区 —— 只做两件事：
 *   1. 把「模板 + 行程切片」**同步翻译**成 4 个常驻槽位的状态（纯函数层 PreviewLayout / TimelineMath）；
 *   2. 把宿主的播放意图转交给 GlobalTimelineManager。
 *
 * 与上一版的区别（都是"删机制"而不是"加机制"）：
 *   - **不再接收 editorState**。上一版 watch 整个 EditorStateModel，而宿主每播放 tick 都会替换 state，
 *     于是布局重建（setDuration / updateClockMaster / setMuted / setPlaybackRate / play|pause 全量重放）
 *     每秒被执行约 10 次。现在只接收 6 个**事件级**标量：模板 id、行程、播放/静音/倍速，
 *     以及一次性的跳转请求。没有任何一个字段会被每秒改写。
 *   - **seekToken + playheadMs 合并成 PreviewSeekRequest**。旧版用两个独立 @Prop 表达"跳到哪里"，
 *     而 playheadMs 同时又被播放推进改写，二者更新顺序不受 ArkUI 保证 → "新 token 配旧位置"错跳。
 *     现在 token 与 targetMs 一次赋值同时到达。
 *   - **ForEach 换成三个显式槽位**。上一版把 activeTemplateId / switchTaskId / 机位编进 ForEach 的 key，
 *     好让切模板时重建子组件拿到新的相机；代价是 XComponent 与 Surface 每次切模板都被销毁重建。
 *     现在每个槽位的 controller 身份终身不变（slot_0/1/2 各自持有），切模板只改 controller 的机位与段，
 *     XComponent 永不重建；几何由显式索引读取 @State，不依赖 key 变化来刷新。
 *
 * 注意：@Builder 的 index 参数是常量字面量，UI 刷新依赖的是 `this.slots`（本组件 @State）本身，
 * 因此不涉及"@Builder 按值传参不刷新"的限制。
 */
@Component
export struct EditorPreviewArea {
  @Prop @Watch('onTemplateOrTripChanged') activeTemplateId: string = ''
  @Prop @Watch('onTemplateOrTripChanged') tripSnapshot: TripSnapshot = new TripSnapshot()
  @Prop @Watch('onPlayingChanged') playing: boolean = false
  @Prop @Watch('onMutedChanged') muted: boolean = false
  @Prop @Watch('onSpeedLabelChanged') speedLabel: string = '1.0X'
  /**
   * 显式跳转请求。**只有**用户主动跳转（点时间轴 / 拖拽松手 / 播完回到开头）才会让 token 递增；
   * 播放推进、切模板、换机位都不走这里——位置由 TimelineClock 唯一持有。
   */
  @Prop @Watch('onSeekRequestChanged') seekRequest: PreviewSeekRequest = new PreviewSeekRequest()
  onPlayheadChanged?: (playheadMs: number) => void
  onPlaybackEnded?: () => void

  @State private slots: Array<PersistentSlotState> = []
  private manager: GlobalTimelineManager = new GlobalTimelineManager()
  private disposed: boolean = false

  /**
   * 每个 @Watch 处理器都先与"已生效的值"比较，只有真正变化才做事。
   *
   * 这是本组件**唯一**的并发防线，也是它能做到"重复调用无害"的原因：
   * ArkUI 不保证 @Watch 只在值变化时触发（父组件重渲染也可能再次派发），
   * 一旦依赖"框架只在我变化时叫我"，就会出现每秒十几次的布局重建 —— 那正是上一版的病。
   * 现在无论框架叫多少次，token / key / 布尔值不变就立刻返回。
   */
  private appliedSeekToken: number = 0
  private appliedApplyKey: string = ''
  private appliedPlaying: boolean = false
  private appliedMuted: boolean = false
  private appliedSpeedLabel: string = ''

  aboutToAppear(): void {
    this.disposed = false
    this.initPersistentSlots()
    this.manager.setCallbacks(
      (globalMs: number) => {
        if (!this.disposed && this.onPlayheadChanged) {
          this.onPlayheadChanged(globalMs)
        }
      },
      undefined,
      () => {
        if (!this.disposed && this.onPlaybackEnded) {
          this.onPlaybackEnded()
        }
      }
    )
    this.applyTemplateAndTrip()
    // @Watch 不会在变量**初始化**时触发，所以挂载时可能已经有一个待处理的跳转请求（宿主在
    // 子组件创建前就写好了播放头）。这里主动消费一次，避免"画面停在 0 而播放头在 90s"。
    this.onSeekRequestChanged()
  }

  aboutToDisappear(): void {
    this.disposed = true
    this.manager.release()
  }

  /**
   * 4 个常驻槽位只建一次。controller 与槽位下标**终身绑定**（slot_0 永远是第 0 个 XComponent），
   * 切模板时只调用 controller.setCamera / bindSegments —— 这是 XComponent 不被重建的前提。
   */
  private initPersistentSlots(): void {
    const initialSlots: Array<PersistentSlotState> = []
    const defaultCameras = ['Front', 'Back', 'Left', 'Right']
    for (let i = 0; i < MAX_PREVIEW_SLOTS; i++) {
      const camera = defaultCameras[i]
      // 出声轨**不再**由这里按槽位下标决定（曾经是 `i === 0`）：槽位下标与机位不是一回事，
      // 只有 front 文件带音轨，而 T4 的槽位顺序是 LeftFront/Front/RightFront，
      // 按 `i === 0` 会让 T4 预览没有声音（缺陷 7.2）。
      // 现在由 SingleTrackController 按机位（camera === 'Front'）自行判断。
      const controller = new SingleTrackController(`slot_${i}`, camera)
      this.manager.registerTrack(controller)
      initialSlots.push({
        index: i,
        visible: i === 0,
        camera,
        x: 0,
        y: 0,
        width: 1,
        height: 1,
        zoomX: 1,
        hasSource: false,
        controller
      })
    }
    this.slots = initialSlots
  }

  private toPercent(value: number): string {
    const percent = Math.max(0, Math.min(100, value * 100))
    return `${percent}%`
  }

  private parseSpeedLabel(label: string): number {
    const parsed = Number(label.replace('X', '').replace('x', ''))
    if (parsed >= 0.75 && parsed <= 2) {
      return parsed
    }
    return 1
  }

  /** 行程切片：机位名归一化后交给纯函数层（构造副本，绝不改 @Prop）。 */
  private buildNormalizedClips(): Array<DvrMeta> {
    const source = this.tripSnapshot.clips
    const result: Array<DvrMeta> = []
    for (let i = 0; i < source.length; i++) {
      const item = source[i]
      if (item.uri.length === 0) {
        continue
      }
      const copy = new DvrMeta()
      copy.fileName = item.fileName
      copy.uri = item.uri
      copy.date = item.date
      copy.time = item.time
      copy.camera = normalizeCameraNameById(item.camera)
      copy.timestamp = item.timestamp
      result.push(copy)
    }
    return result
  }

  /** 布局重算的去重键：只有模板、行程内容或时长真的变了才需要重建。 */
  private buildApplyKey(): string {
    const snapshot = this.tripSnapshot
    return `${this.activeTemplateId}|${snapshot.id}|${snapshot.clips.length}|${snapshot.durationSec}`
  }

  /**
   * 模板/行程变化：**同步**重算几何与段绑定，然后交给协调器。
   * 这里刻意不做 seek —— 时钟位置由 TimelineClock 持有，绑定新段后协调器会按当前位置载入正确的段。
   */
  private applyTemplateAndTrip(): void {
    if (this.disposed) {
      return
    }
    this.appliedApplyKey = this.buildApplyKey()
    const templateId = this.activeTemplateId
    const geometries: Array<SlotGeometry> = buildSlotGeometry(templateId)
    const clips = this.buildNormalizedClips()
    const grid: TimeGrid = buildTimeGrid(clips)

    const nextSlots: Array<PersistentSlotState> = []
    for (let i = 0; i < MAX_PREVIEW_SLOTS && i < this.slots.length; i++) {
      const slot = this.slots[i]
      if (i < geometries.length) {
        const geometry = geometries[i]
        const camera = normalizeCameraNameById(geometry.camera)
        const segments: Array<SegmentSpan> = buildSegmentSpans(clips, camera, grid)
        slot.visible = true
        slot.camera = camera
        slot.x = geometry.x
        slot.y = geometry.y
        slot.width = geometry.width
        slot.height = geometry.height
        slot.zoomX = geometry.zoomX
        slot.hasSource = segments.length > 0
        slot.controller.setCamera(camera)
        slot.controller.bindSegments(segments)
      } else {
        slot.visible = false
        slot.hasSource = false
        slot.controller.bindSegments([])
      }
      nextSlots.push(slot)
    }

    this.slots = nextSlots

    this.manager.setDuration(grid.durationMs)
    this.manager.updateClockMaster()
    this.syncTransport()
    debugLog('EditorPreviewArea', `applied template=${templateId} slots=${geometries.length} durationMs=${grid.durationMs}`)
  }

  /** 只同步"播放意图 / 音量 / 速率"，不改变时钟位置。 */
  private syncTransport(): void {
    this.appliedPlaying = this.playing
    this.appliedMuted = this.muted
    this.appliedSpeedLabel = this.speedLabel
    void this.applyTransport()
  }

  private async applyTransport(): Promise<void> {
    try {
      await this.manager.setMuted(this.muted)
      await this.manager.setPlaybackRate(this.parseSpeedLabel(this.speedLabel))
      if (this.playing) {
        await this.manager.play()
      } else {
        await this.manager.pause()
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('EditorPreviewArea', `transport sync failed: ${message}`)
    }
  }

  onTemplateOrTripChanged(): void {
    if (this.disposed) {
      return
    }
    if (this.buildApplyKey() === this.appliedApplyKey) {
      return
    }
    this.applyTemplateAndTrip()
  }

  onPlayingChanged(): void {
    if (this.playing === this.appliedPlaying) {
      return
    }
    this.appliedPlaying = this.playing
    this.syncTransport()
  }

  onMutedChanged(): void {
    if (this.disposed) {
      return
    }
    if (this.muted === this.appliedMuted) {
      return
    }
    this.appliedMuted = this.muted
    void this.manager.setMuted(this.muted)
  }

  onSpeedLabelChanged(): void {
    if (this.disposed) {
      return
    }
    if (this.speedLabel === this.appliedSpeedLabel) {
      return
    }
    this.appliedSpeedLabel = this.speedLabel
    void this.manager.setPlaybackRate(this.parseSpeedLabel(this.speedLabel))
  }

  onSeekRequestChanged(): void {
    if (this.disposed) {
      return
    }
    if (this.seekRequest.token === this.appliedSeekToken) {
      return
    }
    this.appliedSeekToken = this.seekRequest.token
    void this.manager.seek(this.seekRequest.targetMs)
  }

  @Builder
  slotAt(index: number) {
    if (index < this.slots.length) {
      Stack({ alignContent: Alignment.Center }) {
        // 常驻挂载：XComponent 与 Surface 终身不销毁重建。
        SingleTrackView({
          controller: this.slots[index].controller
        })
          .width(this.slots[index].zoomX > 1 ? `${this.slots[index].zoomX * 100}%` : '100%')
          .height('100%')
          .visibility(Visibility.Visible)

        if (!this.slots[index].hasSource && this.slots[index].visible) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor($r('app.color.stage_divider'))
        }
      }
      .clip(true)
      .width(this.toPercent(this.slots[index].width))
      .height(this.toPercent(this.slots[index].height))
      .position({ x: this.toPercent(this.slots[index].x), y: this.toPercent(this.slots[index].y) })
      .visibility(this.slots[index].visible ? Visibility.Visible : Visibility.Hidden)
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Stack({ alignContent: Alignment.TopStart }) {
        this.slotAt(0)
        this.slotAt(1)
        this.slotAt(2)
        this.slotAt(3)
      }
      .aspectRatio(templateAspectRatio(this.activeTemplateId))
      .width(templateAspectRatio(this.activeTemplateId) >= 16 / 9 ? '100%' : undefined)
      .height(templateAspectRatio(this.activeTemplateId) < 16 / 9 ? '100%' : undefined)
      .backgroundColor($r('app.color.stage_bg'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.stage_bg'))
  }
}
