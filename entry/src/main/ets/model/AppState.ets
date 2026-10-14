import { Segment } from './SegmentModel'

export interface TripCardModel {
  id: string
  title: string
  subtitle: string
  durationText: string
  durationSec: number
  previewUri: string
  previewFrameUri: string
  previewCamera: string
}

export interface LibraryStateModel {
  title: string
  cards: Array<TripCardModel>
  empty: boolean
  emptyText: string
  permissionTip: string
}

export interface TimelineTrackModel {
  cameraPosition: string
  segmentCount: number
  degraded: boolean
}

export interface EditorLayerModel {
  name: string
  heightRatio: number
}

export interface TimelineMarkerModel {
  positionSec: number
  style: string
}

export interface TemplateCardModel {
  id: string
  title: string
  subtitle: string
}

export interface PreviewSlotModel {
  id: string
  camera: string
  uri: string
  nextUri?: string // Added for seamless double-buffering
  x: number
  y: number
  width: number
  height: number
}

/**
 * 一次**显式跳转**请求（点时间轴、拖拽松手、播完后回到开头）。
 *
 * 为什么 token 与 targetMs 必须放在同一个对象里：
 * 旧代码用两个独立 @Prop（seekToken 数字 + playheadMs 数字）传递跳转意图，
 * 而 playheadMs 同时又被"播放推进"每秒改写。ArkUI 不保证两个 @Prop 的更新顺序，
 * 于是会出现"新 token 配旧位置"的错跳；预览区还不得不加 settle 窗口（260ms）
 * 与 0.55s 差值阈值去猜哪个回调是"自己引起的"，修一个冒一个。
 *
 * 现在 token 与 targetMs 一次赋值同时送达，@Watch 里读到的必然是配对的。
 * token 只在显式跳转时递增；播放推进、切模板重建都不递增。
 */
export class PreviewSeekRequest {
  token: number = 0
  targetMs: number = 0
}

export interface EditorStateModel {
  tripId: string
  tripTitle: string
  timeRange: string
  previewUri: string
  previewCamera: string
  playheadSec: number
  canPlayPrev: boolean
  canPlayNext: boolean
  currentClipIndex: number
  currentClipTotal: number
  playheadText: string
  totalDurationSec: number
  timeline: Array<TimelineTrackModel>
  layers: Array<EditorLayerModel>
  boundaryMarkers: Array<TimelineMarkerModel>
  templateCards: Array<TemplateCardModel>
  previewSlots: Array<PreviewSlotModel>
  activeTemplateId: string
  drawerExpanded: boolean
  /** 片段列表：整条源片切成首尾相接的段，每段自带倍速与声音开关。 */
  segments: Array<Segment>
  /** 当前选中的片段 id（参数行与轨道描边都看它）。 */
  selectedSegmentId: number
  watermarkEnabled: boolean
  exportStatusText: string
  /** 是否处于全片未剪辑原始状态（默认 true，首次落刀后变为 false，删光重置回 true）。 */
  isRawFull: boolean
}
