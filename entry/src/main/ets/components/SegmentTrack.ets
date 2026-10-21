import { Segment, segmentDurationSec, segmentOrdinal, segmentDisplayName, MIN_SEGMENT_SEC } from '../model/SegmentModel'

/**
 * 手柄拖动期间向页面补发预览寻道的节流间隔（spec §3.6.1：80ms）。
 * 手势本身是 60Hz，而多机位原生解码器经不起 60Hz 的 Seek，所以按 80ms 闸一次。
 */
const ADJUST_SEEK_THROTTLE_MS = 80

/** 轨道容器的内边距：段块与空档都排在这圈留白里面，故可排布宽度 = 轨道宽 - 2×它。 */
const TRACK_PADDING = 3

/**
 * 手柄触摸区最大宽度：44vp，高与段块齐平（轨道 52 - 上下 padding 3×2 = 46vp）。
 *
 * 可见的只有一个 12vp 圆点，但可抓的范围必须远大于可见部分 —— 触摸区先是 16vp，
 * 用户反馈「左右拖动要求的精度太高，不好点」后放宽到 32vp，仍然嫌紧，现在到 44vp。
 *
 * 手柄画在**轨道覆盖层**上（见 handles 注释），触摸区 = 块外 22vp + 块内一半：
 * 外侧恒定 22vp 保证窄块也抓得住（段块宽度 = 时长比例，长片里一个 15s 段可能只有
 * 几 vp 宽，只给「块内」的话目标会小到按不准）；块内那半以块中心为界，左右手柄
 * 不重叠。触摸区是 HitTestMode.Transparent，盖到相邻段时不会把它的点击吃掉。
 */
const HANDLE_TOUCH_WIDTH = 44
const HANDLE_HEIGHT = 46

/** 轨道容器高度（vp）：去掉上下内边距后内容区正好 46vp，与手柄等高。 */
const TRACK_HEIGHT = 52

/**
 * 轨道项数据结构（片段或空白区间）
 */
class TrackTimelineItem {
  isGap: boolean = false
  segment: Segment = new Segment()
  startSec: number = 0
  endSec: number = 0
  durationSec: number = 0
  key: string = ''

  constructor(isGap: boolean, segment: Segment, startSec: number, endSec: number, durationSec: number, key: string) {
    this.isGap = isGap
    this.segment = segment
    this.startSec = startSec
    this.endSec = endSec
    this.durationSec = durationSec
    this.key = key
  }
}

/**
 * 片段轨道（spec §6.6 / Task 3）：
 * - 段块与空白区间按各自时长占宽，**段间不留缝**：没有空档项就说明中间没丢画面。
 *   权重之和恒等于片长，所以轨道宽度与真实时间严格成比例。
 * - 全片态（isRawFull）：单块通宽展示，文案“全片”，无琥珀描边，无拉动手柄。
 * - 多段态（SEGMENTED）：选中的片段具有 1.5vp 琥珀描边 + 左右两侧双向手柄。
 * - 段块与空白区间都可点选：点段块上报 onSelectSegment(id)，点空档上报 onSelectGap(startSec)，
 *   两者都由页面负责把播放头搬到落点（spec §5.4「点块即跳转」的同一套语义）。
 * - 双向手柄拖拽：水平 PanGesture 拖动过程中段块边界实时跟手伸缩（段块与紧邻空档的
 *   宽度都按 dragLeftSec / dragRightSec 现算），画面寻道按 80ms 节流上报
 *   onAdjustPreview(sec)（spec §3.6.1），松手（onActionEnd）时一次性结算边界，
 *   再由页面补发一次最终精准寻道。组件只上报秒数，Seek 一律由页面发出。
 * - 硬阻挡（Clamp）：手柄向外拉受限于片头(0)/片尾/相邻段，向内拉受限于 MIN_SEGMENT_SEC(10s)。
 */
@Component
export struct SegmentTrack {
  @Prop segments: Array<Segment> = []
  @Prop totalDurationSec: number = 0
  @Prop selectedSegmentId: number = -1
  @Prop isRawFull: boolean = false
  onSelectSegment?: (id: number) => void
  onSelectGap?: (startSec: number) => void
  onAdjustStart?: () => void
  onAdjustPreview?: (sec: number) => void
  onAdjustBoundary?: (id: number, edge: 'start' | 'end', sec: number) => void

  @State private isDraggingLeft: boolean = false
  @State private dragLeftSec: number = 0
  @State private dragLeftBaseSec: number = 0
  @State private draggingSegmentId: number = -1

  @State private isDraggingRight: boolean = false
  @State private dragRightSec: number = 0
  @State private dragRightBaseSec: number = 0

  @State private trackWidth: number = 320

  /** 上一次上报预览寻道的时间戳；0 表示「下一次手势位移立刻上报」。 */
  private lastAdjustSeekMs: number = 0

  private isSelected(segment: Segment): boolean {
    return !this.isRawFull && segment.enabled && segment.id === this.selectedSegmentId
  }

  /**
   * ForEach 的键必须带上所有影响渲染的字段
   */
  private blockKey(segment: Segment): string {
    // 序号必须进 key：删掉中间一段后，后面各段的 id / 起止秒都没变，只有序号变了。
    // key 里不带序号时 ArkUI 会复用旧子树、不重算 Text，于是轨道块还写着「片段 3」
    // 而参数行已经是「片段 2」—— 同一份数据两个说法。
    return `${segment.id}-${segment.startSec}-${segment.endSec}-${segment.speedLabel}-${segment.muted}-${segment.enabled}-${segmentOrdinal(this.segments, segment.id)}-${this.isSelected(segment)}-${this.isRawFull}`
  }

  private formatTime(sec: number): string {
    const whole = Math.max(0, Math.round(sec))
    const minutes = Math.floor(whole / 60)
    const seconds = whole % 60
    return `${minutes}:${seconds < 10 ? '0' : ''}${seconds}`
  }

  private clampStartSec(segment: Segment, targetSec: number): number {
    const sorted: Array<Segment> = []
    for (let i = 0; i < this.segments.length; i++) {
      sorted.push(this.segments[i])
    }
    sorted.sort((a: Segment, b: Segment) => a.startSec - b.startSec)
    let idx = -1
    for (let i = 0; i < sorted.length; i++) {
      if (sorted[i].id === segment.id) {
        idx = i
        break
      }
    }
    const minSec = idx > 0 ? sorted[idx - 1].endSec : 0
    const maxSec = segment.endSec - MIN_SEGMENT_SEC
    return Math.max(minSec, Math.min(targetSec, maxSec))
  }

  private clampEndSec(segment: Segment, targetSec: number): number {
    const sorted: Array<Segment> = []
    for (let i = 0; i < this.segments.length; i++) {
      sorted.push(this.segments[i])
    }
    sorted.sort((a: Segment, b: Segment) => a.startSec - b.startSec)
    let idx = -1
    for (let i = 0; i < sorted.length; i++) {
      if (sorted[i].id === segment.id) {
        idx = i
        break
      }
    }
    const minSec = segment.startSec + MIN_SEGMENT_SEC
    const total = this.totalDurationSec > 0 ? this.totalDurationSec : 60
    const maxSec = idx >= 0 && idx < sorted.length - 1 ? sorted[idx + 1].startSec : total
    return Math.max(minSec, Math.min(targetSec, maxSec))
  }

  /** 轨道可排布宽度（去掉左右内边距）。手势位移换算成秒数、以及布局占宽，都按它算。 */
  private trackInnerWidth(): number {
    return Math.max(1, this.trackWidth - TRACK_PADDING * 2)
  }

  /** 正在被拖动的那一段在 segments 里的下标；没在拖或找不到时 -1。 */
  private draggedSegmentIndex(): number {
    if (!this.isDraggingLeft && !this.isDraggingRight) {
      return -1
    }
    for (let i = 0; i < this.segments.length; i++) {
      if (this.segments[i].id === this.draggingSegmentId) {
        return i
      }
    }
    return -1
  }

  /**
   * 拖动中的那一段用「手指实时落点」当边界，其余段用已提交的边界。
   *
   * 这几个函数只在 @Builder 的布局表达式里直接调用，不能把结果当参数传进去：
   * ForEach 命中同一个 key 时会整棵子树复用、不再重跑 item 构建器，外面传进来的值
   * 会一直是拖动开始前的那个数（blockKey 注释里记着同一个坑）。写成读 @State 的表达式，
   * ArkUI 才会在 dragLeftSec / dragRightSec 变化时重算它。
   */
  private liveStartSec(segment: Segment): number {
    if (this.isDraggingLeft && this.draggingSegmentId === segment.id) {
      return this.dragLeftSec
    }
    return segment.startSec
  }

  private liveEndSec(segment: Segment): number {
    if (this.isDraggingRight && this.draggingSegmentId === segment.id) {
      return this.dragRightSec
    }
    return segment.endSec
  }

  private liveBlockWeight(segment: Segment): number {
    return Math.max(0.1, this.liveEndSec(segment) - this.liveStartSec(segment))
  }

  /**
   * 秒 → 轨道内绝对宽度（vp）。
   *
   * 轨道上每一寸都必须对应真实时间，所以宽度一律由「时长 × 轨宽 / 片长」现算，
   * 不用 layoutWeight 的比例分摊（理由见 liveGapWeight 注释）。
   */
  private widthForSec(sec: number): number {
    const total = this.totalDurationSec
    if (total <= 0) {
      return 0
    }
    return Math.max(0, this.trackInnerWidth() * sec / total)
  }

  /**
   * 空档的实时宽度（秒）。
   *
   * 拖动中的段会把紧邻空档的一端顶开或让出，空档必须同步伸缩。返回的是**秒数**，
   * 再由 widthForSec 换算成绝对宽度。
   *
   * 这里**不能**用 layoutWeight：layoutWeight 是按权重比例分摊整条轨道
   * （每项实得 = 轨宽 × w_i / Σw），只要有一项的值不对，整行都会按比例重摊一遍，
   * 旁边的段跟着被拉伸或压缩 —— 这就是「拖这一段，另一段被压扁/拉长」的来源。
   * 绝对宽度下每一项只由自己的时长决定，互不牵连。
   */
  private liveGapWeight(item: TrackTimelineItem): number {
    let start = item.startSec
    let end = item.endSec
    const idx = this.draggedSegmentIndex()
    if (idx >= 0) {
      const dragged = this.segments[idx]
      // 空档的左端贴着被拖动段的段尾 → 被段尾顶开
      if (Math.abs(item.startSec - dragged.endSec) < 0.001) {
        start = this.liveEndSec(dragged)
      }
      // 空档的右端贴着被拖动段的段头 → 被段头让出
      if (Math.abs(item.endSec - dragged.startSec) < 0.001) {
        end = this.liveStartSec(dragged)
      }
    }
    return Math.max(0, end - start)
  }

  /**
   * 空白区恒建：片头、每两段之间、片尾，**时长为 0 也照样建项**。
   *
   * 这些项是拖动时「多出来/少下去」的那几秒的唯一容器。若只在时长 > 0.05 时才建，
   * 那么两段紧贴（如 15-30 与 30-45）时中间没有空档项，把前一段的段尾往左拖，让出的
   * 5 秒无处安放 —— 权重之和从 60 掉到 55，ArkUI 只能把整条轨道按 60/55 重新摊一遍，
   * 于是后面那个片段跟着一起位移、宽度也变；松手提交后结构里终于有了真空档，权重和
   * 恢复 60，画面又弹回原位。恒建之后权重和恒等于片长，拖动期间后面的段纹丝不动。
   *
   * 0 宽的空档在视觉上不可见（绝对宽度就是 0vp），也就不会违背「相邻片段要贴紧」
   * 这条观感要求。
   */
  private buildTimelineItems(): Array<TrackTimelineItem> {
    const items: Array<TrackTimelineItem> = []
    if (this.isRawFull) {
      const seg = this.segments.length > 0 ? this.segments[0] : new Segment()
      const dur = this.totalDurationSec > 0 ? this.totalDurationSec : Math.max(1, segmentDurationSec(seg))
      items.push(new TrackTimelineItem(false, seg, 0, dur, dur, `raw-full-${dur}`))
      return items
    }

    const sorted: Array<Segment> = []
    for (let i = 0; i < this.segments.length; i++) {
      sorted.push(this.segments[i])
    }
    sorted.sort((a: Segment, b: Segment) => a.startSec - b.startSec)

    if (sorted.length === 0) {
      if (this.totalDurationSec > 0) {
        items.push(new TrackTimelineItem(true, new Segment(), 0, this.totalDurationSec, this.totalDurationSec, `gap-0-${this.totalDurationSec}`))
      }
      return items
    }

    // 空档的 key **必须带上它自己那对「已提交边界秒数」**，不能只用相邻段 id。
    //
    // 空档的宽度不是由它自己的 item 决定的，而是 liveGapWeight(item) 拿**建项时捕获的**
    // startSec/endSec 去和「正在被拖的那条边界」比对现算的（见 liveGapWeight）。而 ForEach
    // 按 key 复用子组件时**不会重跑 item 生成函数**，于是：
    //   - 只用 id 做 key：松手提交后新项的 key 与旧项一模一样，子组件被原样复用、拿着的
    //     还是上一轮的旧边界。旧边界与新边界对不上（如 15 vs 10），两侧的「贴着被拖边界」
    //     判断全部落空 → 空档宽度退回旧值 0，紧贴的那一段被画到错误位置（拖第二下开始
    //     空档再也不跟手，后段干脆跟着前段的边一起滑）。
    //   - 带上已提交边界：拖动期间提交值不变 → key 稳定、子组件照旧复用（这正是 §3.6.4
    //     要的「拖动期间结构不变」）；松手提交后边界变了 → key 变、子组件重建，拿到的是
    //     刚生成的新项。稳定性和新鲜度两者兼得。
    // 段块的 blockKey 本来就把边界编进 key（同一条道理），空档此前漏了，这里补齐。

    // 片头空白区。**时长为 0 时也要建这一项**，理由见下方「空白区恒建」注释。
    items.push(new TrackTimelineItem(true, new Segment(), 0, sorted[0].startSec, Math.max(0, sorted[0].startSec), `gap-head-${sorted[0].id}-0-${sorted[0].startSec}`))

    for (let i = 0; i < sorted.length; i++) {
      const seg = sorted[i]
      const segDur = Math.max(0.1, segmentDurationSec(seg))
      items.push(new TrackTimelineItem(false, seg, seg.startSec, seg.endSec, segDur, this.blockKey(seg)))

      // 片段间空白区。**相邻两段紧贴时也要建这一项**（宽度 0，看不见）。
      if (i < sorted.length - 1) {
        const nextSeg = sorted[i + 1]
        const gapDur = Math.max(0, nextSeg.startSec - seg.endSec)
        items.push(new TrackTimelineItem(true, new Segment(), seg.endSec, nextSeg.startSec, gapDur, `gap-${seg.id}-${nextSeg.id}-${seg.endSec}-${nextSeg.startSec}`))
      }
    }

    // 片尾空白区，同样恒建。
    const lastSeg = sorted[sorted.length - 1]
    const tailDur = Math.max(0, this.totalDurationSec - lastSeg.endSec)
    items.push(new TrackTimelineItem(true, new Segment(), lastSeg.endSec, this.totalDurationSec, tailDur, `gap-tail-${lastSeg.id}-${lastSeg.endSec}-${this.totalDurationSec}`))

    return items
  }

  /**
   * 拖动手柄的可见部分：只有一个圆点。
   *
   * 先是从 6vp 琥珀竖条 + 三颗白点改成「细线 + 圆点」，但段与段紧贴之后，那条竖线
   * 会被两侧边框和相邻段淹掉，只剩一根突兀的线杵在接缝上，所以干脆只留圆点：
   * 圆点标明边界落在哪、也说明这里可以抓。真正能抓的范围见 HANDLE_TOUCH_WIDTH。
   *
   * **HitTestMode.None**：圆点以边界为中心，有一半（约 6vp）落在相邻段上。父层虽然也是
   * None，但按 ArkUI 的定义「None 只是自身不响应，子节点照常响应」，圆点自己不声明 None
   * 的话，那半截仍会吃掉相邻段上的触摸 —— 点在相邻段边缘就会选不中它。
   */
  @Builder
  handleBar() {
    Row()
      .width(12)
      .height(12)
      .borderRadius(6)
      .backgroundColor($r('app.color.amber'))
      .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 当前正在被拖动的那个边界秒数（左侧优先）。
   *
   * 给气泡用：气泡只能挂在正在拖的那一侧（调用点由 isDraggingLeft / isDraggingRight
   * 的 if 守着），所以这里直接读 @State，不需要再往下传参。
   */
  private draggedTimeSec(): number {
    if (this.isDraggingLeft) {
      return this.dragLeftSec
    }
    return this.dragRightSec
  }

  /**
   * 拖动时浮在手柄上方的时间气泡。
   *
   * **不接收参数**：@Builder 的值类型参数变了不会触发刷新，气泡会停在按下那一刻的时间上，
   * 看起来像「显示了时间但不动」。必须让 Text 直接读 @State，依赖才登记得上。
   */
  @Builder
  bubble() {
    Row() {
      Text(this.formatTime(this.draggedTimeSec()))
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.card_bg'))
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .borderRadius(4)
        .backgroundColor($r('app.color.overlay_veil'))
    }
    .offset({ y: -30 })
    .shadow({ radius: 4, color: $r('app.color.knob_shadow'), offsetX: 0, offsetY: 1 })
    .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 拖动期间按 80ms 节流上报预览寻道位置（spec §3.6.1）。
   * 节流闸门放在组件里，是因为它跟着手势频率走；组件只上报秒数，Seek 由页面发出。
   */
  private emitAdjustPreview(sec: number): void {
    if (!this.onAdjustPreview) {
      return
    }
    const now = Date.now()
    if (now - this.lastAdjustSeekMs < ADJUST_SEEK_THROTTLE_MS) {
      return
    }
    this.lastAdjustSeekMs = now
    this.onAdjustPreview(sec)
  }

  /**
   * 手柄触摸区宽度（vp）：**块外恒定 22vp + 块内一半**。
   *
   * 手柄画在轨道覆盖层上（见 handles 注释），所以触摸区可以放心探出段块之外：外侧那
   * 22vp 让窄块也抓得住 —— 段块宽度 = 时长比例，长片里一个 15s 段可能只有几 vp 宽，
   * 只给「块内」的话目标会小到按不准。伸进块内的部分取块宽一半，于是左右两条触摸区
   * 以块中心为界、互不重叠：想抓左边界就往块左侧/外侧按，想抓右边界就往右侧按。
   */
  private handleTouchWidthVp(): number {
    return HANDLE_TOUCH_WIDTH / 2 + this.handleInnerSpanVp()
  }

  /** 手柄触摸区伸进段块内的那一半（vp）：块够宽时 22vp，窄块时取块宽的一半。 */
  private handleInnerSpanVp(): number {
    const idx = this.selectedSegmentIndex()
    if (idx < 0) {
      return 0
    }
    const blockW = this.widthForSec(this.liveBlockWeight(this.segments[idx]))
    return Math.min(HANDLE_TOUCH_WIDTH / 2, blockW / 2)
  }

  /**
   * 当前选中段在 segments 里的下标；没选中 / 全片态 / 已停用时 -1。
   *
   * 覆盖层只按 id 现找段，不把段对象当参数传进 @Builder —— 值类型参数在
   * ForEach 命中同 key 复用子树时不刷新（见 bubble 注释里的同一个坑）。
   */
  private selectedSegmentIndex(): number {
    if (this.isRawFull) {
      return -1
    }
    for (let i = 0; i < this.segments.length; i++) {
      if (this.segments[i].id === this.selectedSegmentId && this.segments[i].enabled) {
        return i
      }
    }
    return -1
  }

  /** 选中段块左边界在轨道内的 x 坐标（vp），随拖动实时变化。 */
  private selectedLeftVp(): number {
    return this.selectedEdgeVp(false)
  }

  /** 选中段块右边界在轨道内的 x 坐标（vp），随拖动实时变化。 */
  private selectedRightVp(): number {
    return this.selectedEdgeVp(true)
  }

  /**
   * 选中段块左/右边界在轨道内的 x 坐标（vp）。
   *
   * 覆盖层手柄靠它定位，所以必须读 @State 现算：把边界之前所有项的**实时**时长累加
   * 再换算成宽度（拖动中被拖段的宽度、以及紧邻空档的宽度都在变）。
   */
  private selectedEdgeVp(rightEdge: boolean): number {
    if (this.selectedSegmentIndex() < 0) {
      return -1
    }
    const items = this.buildTimelineItems()
    let accSec = 0
    for (let i = 0; i < items.length; i++) {
      const item = items[i]
      const itemSec = item.isGap ? this.liveGapWeight(item) : this.liveBlockWeight(item.segment)
      if (!item.isGap && item.segment.id === this.selectedSegmentId) {
        return this.widthForSec(rightEdge ? accSec + itemSec : accSec)
      }
      accSec += itemSec
    }
    return -1
  }

  /**
   * 左手柄（画在覆盖层上）：触摸区 = 块外 22vp + 块内一半，圆点锚在左边界。
   *
   * 触摸区左缘 = 边界 - 22vp，可见层是 44vp 盒子且左缘与触摸区左缘对齐，
   * 于是圆心正好落在边界上，跟段块多宽无关。
   */
  @Builder
  leftHandle() {
    Stack({ alignContent: Alignment.Start }) {
      // 可见层：圆点 + 气泡。HitTestMode.None —— 它是纯视觉，不吃触摸。
      Stack({ alignContent: Alignment.Center }) {
        this.handleBar()
        if (this.isDraggingLeft) {
          this.bubble()
        }
      }
      .width(HANDLE_TOUCH_WIDTH)
      .height(HANDLE_HEIGHT)
      .hitTestBehavior(HitTestMode.None)
    }
    .width(this.handleTouchWidthVp())
    .height(HANDLE_HEIGHT)
    // 透明背景：这个容器只放一个 None 的可见层，给背景才保证它有真实命中区域
    .backgroundColor(Color.Transparent)
    // Transparent：手柄在覆盖层最上面，拖动先命中它；但它不阻塞兄弟节点，
    // 所以它盖到的相邻段/空档的点击照样生效（不会「点不中旁边那段」）。
    .hitTestBehavior(HitTestMode.Transparent)
    .position({ x: this.selectedLeftVp() - HANDLE_TOUCH_WIDTH / 2, y: 0 })
    .gesture(
      PanGesture({ direction: PanDirection.Horizontal })
        .onActionStart(() => {
          const idx = this.selectedSegmentIndex()
          if (idx < 0) {
            return
          }
          if (this.onAdjustStart) {
            this.onAdjustStart()
          }
          const seg = this.segments[idx]
          this.draggingSegmentId = seg.id
          this.dragLeftBaseSec = seg.startSec
          this.dragLeftSec = seg.startSec
          this.isDraggingLeft = true
          this.lastAdjustSeekMs = 0
        })
        .onActionUpdate((event: GestureEvent) => {
          if (!this.isDraggingLeft) {
            return
          }
          if (this.trackWidth <= 0 || this.totalDurationSec <= 0) {
            return
          }
          const idx = this.selectedSegmentIndex()
          if (idx < 0) {
            return
          }
          const deltaSec = (event.offsetX / this.trackInnerWidth()) * this.totalDurationSec
          const targetSec = this.dragLeftBaseSec + deltaSec
          this.dragLeftSec = this.clampStartSec(this.segments[idx], targetSec)
          this.emitAdjustPreview(this.dragLeftSec)
        })
        .onActionEnd(() => {
          this.isDraggingLeft = false
          const idx = this.selectedSegmentIndex()
          if (idx >= 0 && this.onAdjustBoundary) {
            this.onAdjustBoundary(this.segments[idx].id, 'start', this.dragLeftSec)
          }
        })
        .onActionCancel(() => {
          this.isDraggingLeft = false
          // 手势被打断：边界没有提交，画面必须回到真正生效的那条边界上，
          // 否则画面停在手指划过的位置、而轨道块还在原处 —— 又是一处两处说法不一致。
          this.lastAdjustSeekMs = 0
          if (this.onAdjustPreview) {
            this.onAdjustPreview(this.dragLeftBaseSec)
          }
        })
    )
  }

  /**
   * 右手柄（画在覆盖层上）：触摸区 = 块内一半 + 块外 22vp，圆点锚在右边界。
   *
   * 触摸区右缘 = 边界 + 22vp；可见层是 44vp 盒子，要往左挪 (22vp - 块内那一半)，
   * 圆心才落在边界上，跟段块多宽无关。
   */
  @Builder
  rightHandle() {
    Stack({ alignContent: Alignment.Start }) {
      // 可见层：圆点 + 气泡，往左挪到「圆心 = 右边界」的位置。同样不吃触摸。
      Stack({ alignContent: Alignment.Center }) {
        this.handleBar()
        if (this.isDraggingRight) {
          this.bubble()
        }
      }
      .width(HANDLE_TOUCH_WIDTH)
      .height(HANDLE_HEIGHT)
      .offset({ x: this.handleInnerSpanVp() - HANDLE_TOUCH_WIDTH / 2 })
      .hitTestBehavior(HitTestMode.None)
    }
    .width(this.handleTouchWidthVp())
    .height(HANDLE_HEIGHT)
    .backgroundColor(Color.Transparent)
    .hitTestBehavior(HitTestMode.Transparent)
    .position({ x: this.selectedRightVp() - this.handleInnerSpanVp(), y: 0 })
    .gesture(
      PanGesture({ direction: PanDirection.Horizontal })
        .onActionStart(() => {
          const idx = this.selectedSegmentIndex()
          if (idx < 0) {
            return
          }
          if (this.onAdjustStart) {
            this.onAdjustStart()
          }
          const seg = this.segments[idx]
          this.draggingSegmentId = seg.id
          this.dragRightBaseSec = seg.endSec
          this.dragRightSec = seg.endSec
          this.isDraggingRight = true
          this.lastAdjustSeekMs = 0
        })
        .onActionUpdate((event: GestureEvent) => {
          if (!this.isDraggingRight) {
            return
          }
          if (this.trackWidth <= 0 || this.totalDurationSec <= 0) {
            return
          }
          const idx = this.selectedSegmentIndex()
          if (idx < 0) {
            return
          }
          const deltaSec = (event.offsetX / this.trackInnerWidth()) * this.totalDurationSec
          const targetSec = this.dragRightBaseSec + deltaSec
          this.dragRightSec = this.clampEndSec(this.segments[idx], targetSec)
          this.emitAdjustPreview(this.dragRightSec)
        })
        .onActionEnd(() => {
          this.isDraggingRight = false
          const idx = this.selectedSegmentIndex()
          if (idx >= 0 && this.onAdjustBoundary) {
            this.onAdjustBoundary(this.segments[idx].id, 'end', this.dragRightSec)
          }
        })
        .onActionCancel(() => {
          this.isDraggingRight = false
          // 同上：打断时把画面收回真正生效的边界。
          this.lastAdjustSeekMs = 0
          if (this.onAdjustPreview) {
            this.onAdjustPreview(this.dragRightBaseSec)
          }
        })
    )
  }

  /**
   * 手柄覆盖层（spec §3.6.1）：画在**整条轨道之上**，而不是画在段块里面。
   *
   * 两个原因：
   * 1. 触摸区够大 —— 段块宽度 = 时长比例，长片里一个 15s 段可能只有几 vp 宽；手柄塞在
   *    块内时触摸区只能跟着缩到几 vp，根本按不准。放在覆盖层上就能稳稳拿到
   *    「块外 22vp + 块内一半」（见 handleTouchWidthVp）。
   * 2. 圆点不被盖住 —— 段块是按顺序画的，后画的相邻段会盖住前一段手柄伸出去的那半颗
   *    圆点（只有末段后面是透明空档才看得见）。覆盖层最后画，圆点永远在最上面。
   *
   * 覆盖层自身 HitTestMode.None（不响应触摸、也不挡下面），两条触摸区用 Transparent：
   * 拖动优先命中手柄，点按仍能落到下面的段块/空档上。
   */
  @Builder
  handles() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.leftHandle()
      this.rightHandle()
    }
    .width('100%')
    // 覆盖层的坐标空间 = 轨道内容区（去掉 padding），与 selectedLeftVp/selectedRightVp
    // 返回的 x 坐标同一套；高度同样写死，避免百分比歧义。
    .height(TRACK_HEIGHT - TRACK_PADDING * 2)
    .hitTestBehavior(HitTestMode.None)
  }

  /** 这一段有没有紧挨着别的段（首尾相接，中间没有空档）。 */
  private hasAdjacentSegment(segment: Segment): boolean {
    for (let i = 0; i < this.segments.length; i++) {
      const other: Segment = this.segments[i]
      if (other.id === segment.id) {
        continue
      }
      if (Math.abs(other.endSec - segment.startSec) < 1e-4 || Math.abs(other.startSec - segment.endSec) < 1e-4) {
        return true
      }
    }
    return false
  }

  /**
   * 段块圆角。
   *
   * 固定 3 的来由：段与段紧贴时，两块各留大圆角会在接缝上下各凹进一个四分之一圆，
   * 看着像「中间被剪掉了一截」—— 那正是当初要修掉的错觉。
   *
   * 但孤立的一段（前后都是空档、或者整条轨道上只有它）根本没有接缝可破坏。
   * 这时候还压成 3 的方角，就是白白方着 —— 它是轨道上一个单独的东西，
   * 就该长得像单独的东西。所以按邻接情况给：挨着别的段才收小。
   */
  private blockRadius(segment: Segment): number {
    return this.hasAdjacentSegment(segment) ? 4 : 16
  }

  @Builder
  segmentBlock(segment: Segment) {
    Stack({ alignContent: Alignment.Center }) {
      Text(this.isRawFull ? '全片' : segmentDisplayName(segmentOrdinal(this.segments, segment.id)))
        .fontSize(12)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
        .fontColor(segment.enabled
          ? (this.isSelected(segment) ? $r('app.color.amber_deep') : $r('app.color.text_secondary'))
          : $r('app.color.text_disabled'))
        .decoration(segment.enabled
          ? { type: TextDecorationType.None }
          : { type: TextDecorationType.LineThrough, color: $r('app.color.text_disabled') })
      // 手柄不再画在段块里：覆盖层统一画在整条轨道之上（见 handles 注释）
    }
    // 宽度在这里现算（读 @State），拖手柄时段块跟着手指一起伸缩，而不是等松手才跳。
    // 用绝对宽度而不是 layoutWeight：见 liveGapWeight 注释。
    .width(this.widthForSec(this.liveBlockWeight(segment)))
    .height('100%')
    .borderRadius(this.blockRadius(segment))
    .borderWidth(this.isSelected(segment) ? 1.5 : 1)
    .borderColor(segment.enabled
      ? (this.isSelected(segment) ? $r('app.color.amber') : $r('app.color.segment_border'))
      : $r('app.color.segment_off_border'))
    // 选中态用 amber_soft 填底，而不是白底 + 琥珀描边：
    // 描边是"画了一个框把它圈起来"，填色才是"这一块被选中了"。轨道上本来就是
    // 浅底 + 白块的组合，再叠一层描边框，选中看起来像多了一个容器。
    .backgroundColor(segment.enabled
      ? (this.isSelected(segment) ? $r('app.color.amber_soft') : $r('app.color.card_bg'))
      : $r('app.color.segment_off_bg'))
    .onClick(() => {
      if (this.onSelectSegment) {
        this.onSelectSegment(segment.id)
      }
    })
  }

  /**
   * 空白区块。和 segmentBlock 一样走 @Builder，宽度现算（读 @State），
   * 这样拖动时段块与紧邻空档的伸缩走的是同一条刷新路径，不会一个动一个不动。
   */
  @Builder
  gapBlock(item: TrackTimelineItem) {
    Row()
      .width(this.widthForSec(this.liveGapWeight(item)))
      .height('100%')
      // 空档也要能点：点一下把播放头落进空档并切到「空白区间」参数行，
      // 否则用户点了轨道上明显的一块却什么都没发生（spec §3.1 的空白态入口）。
      .onClick(() => {
        if (this.onSelectGap) {
          this.onSelectGap(item.startSec)
        }
      })
  }

  build() {
    // 外层 Stack：段块行 + 手柄覆盖层。手柄必须**在段块之后**画，否则相邻段会盖住
    // 前一段手柄伸出去的那半颗圆点（见 handles 注释）。
    Stack({ alignContent: Alignment.TopStart }) {
      // 不设 space：轨道上每一寸宽度都必须对应真实时间。相邻两段之间没有空档项，
      // 就不该有缝 —— 留出 3vp 缝会让人以为中间被剪掉了一截画面。真正的空档仍然
      // 按真实时长占宽（见 buildTimelineItems），它才是「这里没有内容」的唯一表示。
      Row() {
        ForEach(this.buildTimelineItems(), (item: TrackTimelineItem) => {
          if (item.isGap) {
            this.gapBlock(item)
          } else {
            this.segmentBlock(item.segment)
          }
        }, (item: TrackTimelineItem) => item.key)
      }
      .width('100%')
      // 用绝对高度而不是 '100%'：内容区高度就是轨道高去掉上下内边距，写死避免
      // 百分比在不同容器下的解析歧义（段块必须正好填满轨道）。
      .height(TRACK_HEIGHT - TRACK_PADDING * 2)

      // 手柄覆盖层：选中某一段时才画（全片态没有边界可调）
      if (this.selectedSegmentIndex() >= 0) {
        this.handles()
      }
    }
    .width('100%')
    .height(TRACK_HEIGHT)
    .padding(TRACK_PADDING)
    .borderRadius(9)
    .backgroundColor($r('app.color.track_bg'))
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.trackWidth = Number(newValue.width)
    })
  }
}

/**
 * 画面区浮层（spec §6.4）：底部 54vp 渐变（底部渐变到透明），
 * 自上而下 = 进度条行 20 · 两端时间行 16。
 *
 * 剪刀**不在这里**：66095d8 把剪辑按钮移到了参数行右侧（spec §3.1 的「剪辑图标」），
 * 这里曾经留着一个没人调用的 controlRow() 与一个悬空的 onScissors，已于本次清理删除。
 *
 * 浮层盖在画面上（Task 9 把本组件放进画面区 Stack 的底部），所以：
 * - 进度条行整条都能按/拖：按下即出时间气泡，松手消失（spec §5.2）。
 * - 圆钮落在哪一段由父层决定选中（spec §5.4），这里只上报秒数。
 */
@Component
export struct PreviewOverlay {
  @Prop playheadSec: number = 0
  @Prop totalDurationSec: number = 0
  onScrubTo?: (sec: number) => void

  @State private dragging: boolean = false
  @State private dragSec: number = 0
  @State private barWidth: number = 0

  private percent(): number {
    if (this.totalDurationSec <= 0) {
      return 0
    }
    const sec = this.dragging ? this.dragSec : this.playheadSec
    return Math.min(100, Math.max(0, (sec / this.totalDurationSec) * 100))
  }

  private formatTime(sec: number): string {
    const whole = Math.max(0, Math.floor(sec))
    const minutes = Math.floor(whole / 60)
    const seconds = whole % 60
    return `${minutes}:${seconds < 10 ? '0' : ''}${seconds}`
  }

  private handleTouch(event: TouchEvent): void {
    if (this.barWidth <= 0 || this.totalDurationSec <= 0) {
      return
    }
    if (event.type === TouchType.Down || event.type === TouchType.Move) {
      const touch = event.touches.length > 0 ? event.touches[0] : (event.changedTouches.length > 0 ? event.changedTouches[0] : undefined)
      if (touch) {
        const ratio = Math.min(1, Math.max(0, touch.x / this.barWidth))
        this.dragSec = ratio * this.totalDurationSec
        this.dragging = true
      }
      return
    }
    if (event.type === TouchType.Up) {
      this.dragging = false
      const touch = event.changedTouches.length > 0 ? event.changedTouches[0] : (event.touches.length > 0 ? event.touches[0] : undefined)
      if (touch) {
        const ratio = Math.min(1, Math.max(0, touch.x / this.barWidth))
        this.dragSec = ratio * this.totalDurationSec
      }
      if (this.onScrubTo) {
        this.onScrubTo(this.dragSec)
      }
      return
    }
    if (event.type === TouchType.Cancel) {
      this.dragging = false
      return
    }
  }

  @Builder
  progressRow() {
    Stack({ alignContent: Alignment.Start }) {
      Row()
        .width('100%')
        .height(4)
        .borderRadius(2)
        .backgroundColor($r('app.color.ed_track'))
      // 已播部分：整条按播放进度填琥珀。以前只有一根 30% 白的细轨加一个白点，
      // 压在高亮画面上几乎看不见，"进度条"读起来就只剩一个圆钮。
      // 现在搬到画面下方，改在暖白底上画，所以用 ed_track + 琥珀实心圆钮。
      Row()
        .width(`${this.percent()}%`)
        .height(4)
        .borderRadius(2)
        .backgroundColor($r('app.color.amber'))
      Row() {
        Blank()
        Row()
          .width(12)
          .height(12)
          .borderRadius(6)
          .backgroundColor($r('app.color.ed_surface'))
          .border({ width: 2, color: $r('app.color.amber') })
          .shadow({ radius: 4, color: $r('app.color.knob_shadow'), offsetX: 0, offsetY: 1 })
      }
      .width(`${this.percent()}%`)
      .height(20)
      if (this.dragging) {
        Row() {
          Blank()
          Text(this.formatTime(this.dragSec))
            .fontSize(11)
            .fontColor($r('app.color.card_bg'))
            .padding({ left: 6, right: 6, top: 3, bottom: 3 })
            .borderRadius(4)
            .backgroundColor($r('app.color.overlay_veil'))
        }
        .width(`${this.percent()}%`)
        .offset({ y: -24 })
      }
    }
    .width('100%')
    .height(20)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.barWidth = Number(newValue.width)
    })
    .onTouch((event: TouchEvent) => {
      this.handleTouch(event)
    })
  }

  @Builder
  timeRow() {
    Row() {
      Text(this.formatTime(this.playheadSec))
        .fontSize(10)
        .fontColor($r('app.color.text_tertiary'))
      Blank()
      Text(this.formatTime(this.totalDurationSec))
        .fontSize(10)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .height(16)
  }

  build() {
    Column() {
      this.progressRow()
      this.timeRow()
    }
    .width('100%')
    // 定稿是「画面下方留 8、进度块 40」。这里用 margin 而不是 padding：
    // 两行子内容合计 36（轨道行 20 + 时间行 16），height 40 减去 padding 只剩 32，
    // 会让 36 的内容溢出 4 —— 溢出的部分正好压在下面那排参数胶囊上。
    // 用 margin 把 8 放到盒子外面，40 就装得下 36，渲染结果与定稿一致。
    .height(40)
    .margin({ top: 8 })
    .justifyContent(FlexAlign.Center)
  }
}
