import { DvrMeta, ExportSegment, TripSnapshot } from './TripModels'
import { Segment, toExportSegments } from './SegmentModel'

export enum CameraPosition {
  FRONT = 'FRONT',
  REAR = 'REAR',
  LEFT = 'LEFT',
  RIGHT = 'RIGHT',
  LEFT_FRONT = 'LEFT_FRONT',
  RIGHT_FRONT = 'RIGHT_FRONT'
}

export enum TemplateId {
  T1 = 'T1',
  T2 = 'T2',
  T3 = 'T3',
  T4 = 'T4',
  T5 = 'T5',
  T6 = 'T6'
}

export interface ClipSegment {
  clipId: string
  camera: CameraPosition
  uri: string
  timestampMs: number
  durationSec: number
}

export interface CameraTrack {
  camera: CameraPosition
  segments: Array<ClipSegment>
}

export interface Trip {
  tripId: string
  title: string
  rangeText: string
  durationSec: number
  tracks: Record<CameraPosition, CameraTrack>
  startTs: number
  endTs: number
}

export interface TemplateSlotBinding {
  slotId: string
  camera: CameraPosition
}

export interface TemplatePreviewSlot {
  slotId: string
  x: number
  y: number
  width: number
  height: number
  /**
   * 仅预览用的横向放大倍数（1 / 缺省 = 不放大）。
   * 用来近似原生导出对 T4 左右两侧做的 crop：画布只占 1/4 宽，但显示的是 2 倍宽源画面的中段。
   *
   * 已知差异（不在本次重构范围内，故意不修）：原生左槽取 LeftFront 的**右半**、右槽取 RightFront 的**左半**，
   * 而这里靠 Stack 居中把 2 倍宽画面裁成中段。要精确对齐需要再引入一个 crop 起点字段，
   * 而它只能在真机上肉眼验证——在没有设备的前提下改它只会引入无法验证的视觉回归。
   */
  zoomX?: number
}

export interface TemplateFfmpegPolicy {
  needSideTrack: boolean
  /**
   * 是否需要第 4 路轨道（仅 T6 四机位为 true）。
   * 与原生 kNativeTemplateContracts 的 needSide2Track 逐条对应，由 tools/offline-test.mjs 守着。
   */
  needSide2Track: boolean
  disableFrontAudio: boolean
  frontTrackCandidates: Array<CameraPosition>
  backTrackCandidates: Array<CameraPosition>
  sideTrackCandidates: Array<CameraPosition>
  side2TrackCandidates: Array<CameraPosition>
  alignSideByFrontTimeline: boolean
  ignoreNativeTrackSelection: boolean
}

export interface TemplateDefinition {
  templateId: TemplateId
  title: string
  subtitle: string
  /**
   * 导出画布尺寸。与原生 kNativeTemplateContracts
   * （entry/src/main/cpp/export_engine.cpp:83-89）逐条对应，
   * 由 tools/offline-test.mjs 的跨语言一致性用例守着，防止"预览一套、导出一套"再次漂移。
   */
  canvasWidth: number
  canvasHeight: number
  requiredCameras: Array<CameraPosition>
  optionalCameras: Array<CameraPosition>
  slotBindings: Array<TemplateSlotBinding>
  previewSlots: Array<TemplatePreviewSlot>
  ffmpegPolicy: TemplateFfmpegPolicy
}

export const DEFAULT_TEMPLATE_ID: TemplateId = TemplateId.T5

const TEMPLATE_DEFINITION_MAP: Record<TemplateId, TemplateDefinition> = {
  [TemplateId.T1]: {
    templateId: TemplateId.T1,
    canvasWidth: 1920,
    canvasHeight: 2160,
    title: '防追尾双录',
    subtitle: '上下堆叠',
    requiredCameras: [CameraPosition.FRONT, CameraPosition.REAR],
    optionalCameras: [CameraPosition.RIGHT, CameraPosition.LEFT, CameraPosition.LEFT_FRONT, CameraPosition.RIGHT_FRONT],
    slotBindings: [
      { slotId: 'top', camera: CameraPosition.FRONT },
      { slotId: 'bottom', camera: CameraPosition.REAR }
    ],
    previewSlots: [
      { slotId: 'top', x: 0, y: 0, width: 1, height: 0.5 },
      { slotId: 'bottom', x: 0, y: 0.5, width: 1, height: 0.5 }
    ],
    ffmpegPolicy: {
      needSideTrack: false,
      needSide2Track: false,
      disableFrontAudio: false,
      frontTrackCandidates: [CameraPosition.FRONT, CameraPosition.LEFT_FRONT, CameraPosition.RIGHT_FRONT],
      backTrackCandidates: [CameraPosition.REAR, CameraPosition.RIGHT, CameraPosition.RIGHT_FRONT, CameraPosition.LEFT],
      sideTrackCandidates: [],
      side2TrackCandidates: [],
      alignSideByFrontTimeline: false,
      ignoreNativeTrackSelection: false
    }
  },
  [TemplateId.T2]: {
    templateId: TemplateId.T2,
    canvasWidth: 1920,
    canvasHeight: 1620,
    title: '避险防加塞',
    subtitle: '倒品字',
    requiredCameras: [CameraPosition.FRONT, CameraPosition.LEFT, CameraPosition.RIGHT],
    optionalCameras: [CameraPosition.REAR, CameraPosition.LEFT_FRONT, CameraPosition.RIGHT_FRONT],
    slotBindings: [
      { slotId: 'top', camera: CameraPosition.FRONT },
      { slotId: 'bottomLeft', camera: CameraPosition.LEFT },
      { slotId: 'bottomRight', camera: CameraPosition.RIGHT }
    ],
    previewSlots: [
      { slotId: 'top', x: 0, y: 0, width: 1, height: 0.6667 },
      { slotId: 'bottomLeft', x: 0, y: 0.6667, width: 0.5, height: 0.3333 },
      { slotId: 'bottomRight', x: 0.5, y: 0.6667, width: 0.5, height: 0.3333 }
    ],
    ffmpegPolicy: {
      needSideTrack: true,
      needSide2Track: false,
      disableFrontAudio: false,
      frontTrackCandidates: [CameraPosition.FRONT, CameraPosition.LEFT_FRONT, CameraPosition.RIGHT_FRONT],
      backTrackCandidates: [CameraPosition.RIGHT, CameraPosition.RIGHT_FRONT, CameraPosition.REAR, CameraPosition.LEFT],
      sideTrackCandidates: [CameraPosition.LEFT, CameraPosition.LEFT_FRONT, CameraPosition.FRONT, CameraPosition.RIGHT],
      side2TrackCandidates: [],
      alignSideByFrontTimeline: true,
      ignoreNativeTrackSelection: false
    }
  },
  [TemplateId.T3]: {
    templateId: TemplateId.T3,
    canvasWidth: 3840,
    canvasHeight: 1080,
    title: '左右盲区',
    subtitle: '左右分屏',
    requiredCameras: [CameraPosition.LEFT, CameraPosition.RIGHT],
    optionalCameras: [CameraPosition.LEFT_FRONT, CameraPosition.RIGHT_FRONT, CameraPosition.FRONT, CameraPosition.REAR],
    slotBindings: [
      { slotId: 'left', camera: CameraPosition.LEFT },
      { slotId: 'right', camera: CameraPosition.RIGHT }
    ],
    previewSlots: [
      { slotId: 'left', x: 0, y: 0, width: 0.5, height: 1 },
      { slotId: 'right', x: 0.5, y: 0, width: 0.5, height: 1 }
    ],
    ffmpegPolicy: {
      needSideTrack: false,
      needSide2Track: false,
      disableFrontAudio: true,
      frontTrackCandidates: [CameraPosition.LEFT, CameraPosition.LEFT_FRONT, CameraPosition.FRONT],
      backTrackCandidates: [CameraPosition.RIGHT, CameraPosition.RIGHT_FRONT, CameraPosition.REAR],
      sideTrackCandidates: [],
      side2TrackCandidates: [],
      alignSideByFrontTimeline: false,
      ignoreNativeTrackSelection: true
    }
  },
  [TemplateId.T4]: {
    templateId: TemplateId.T4,
    canvasWidth: 3840,
    canvasHeight: 1080,
    title: '沉浸式旅拍',
    subtitle: '横向三分屏',
    requiredCameras: [CameraPosition.LEFT_FRONT, CameraPosition.FRONT, CameraPosition.RIGHT_FRONT],
    optionalCameras: [CameraPosition.LEFT, CameraPosition.RIGHT, CameraPosition.REAR],
    slotBindings: [
      { slotId: 'left', camera: CameraPosition.LEFT_FRONT },
      { slotId: 'center', camera: CameraPosition.FRONT },
      { slotId: 'right', camera: CameraPosition.RIGHT_FRONT }
    ],
    previewSlots: [
      // 与原生 T4 的 [left][middle][right] hstack 一致：960 / 1920 / 960 → 0.25 / 0.5 / 0.25。
      // 原生对两侧做 crop=960:1080（左槽取右半、右槽取左半），预览用 zoomX=2 近似同一构图。
      { slotId: 'left', x: 0, y: 0, width: 0.25, height: 1, zoomX: 2 },
      { slotId: 'center', x: 0.25, y: 0, width: 0.5, height: 1 },
      { slotId: 'right', x: 0.75, y: 0, width: 0.25, height: 1, zoomX: 2 }
    ],
    ffmpegPolicy: {
      needSideTrack: true,
      needSide2Track: false,
      disableFrontAudio: false,
      frontTrackCandidates: [CameraPosition.FRONT, CameraPosition.LEFT_FRONT, CameraPosition.RIGHT_FRONT],
      backTrackCandidates: [CameraPosition.RIGHT_FRONT, CameraPosition.RIGHT, CameraPosition.REAR],
      sideTrackCandidates: [CameraPosition.LEFT_FRONT, CameraPosition.LEFT, CameraPosition.FRONT],
      side2TrackCandidates: [],
      alignSideByFrontTimeline: true,
      ignoreNativeTrackSelection: true
    }
  },
  [TemplateId.T5]: {
    templateId: TemplateId.T5,
    canvasWidth: 1920,
    canvasHeight: 1080,
    title: '单视角',
    subtitle: '固定前视',
    requiredCameras: [CameraPosition.FRONT],
    optionalCameras: [],
    slotBindings: [
      { slotId: 'top', camera: CameraPosition.FRONT }
    ],
    previewSlots: [
      { slotId: 'top', x: 0, y: 0, width: 1, height: 1 }
    ],
    ffmpegPolicy: {
      needSideTrack: false,
      needSide2Track: false,
      disableFrontAudio: false,
      frontTrackCandidates: [CameraPosition.FRONT],
      backTrackCandidates: [CameraPosition.FRONT],
      sideTrackCandidates: [],
      side2TrackCandidates: [],
      alignSideByFrontTimeline: false,
      ignoreNativeTrackSelection: true
    }
  },
  [TemplateId.T6]: {
    templateId: TemplateId.T6,
    canvasWidth: 3840,
    canvasHeight: 2160,
    title: '四机位',
    subtitle: '2×2 四宫格',
    requiredCameras: [CameraPosition.FRONT, CameraPosition.REAR, CameraPosition.LEFT, CameraPosition.RIGHT],
    optionalCameras: [CameraPosition.LEFT_FRONT, CameraPosition.RIGHT_FRONT],
    slotBindings: [
      { slotId: 'topLeft', camera: CameraPosition.FRONT },
      { slotId: 'topRight', camera: CameraPosition.REAR },
      { slotId: 'bottomLeft', camera: CameraPosition.LEFT },
      { slotId: 'bottomRight', camera: CameraPosition.RIGHT }
    ],
    // 画布 3840×2160，四格各 1920×1080 —— 每格正好等于机位原生分辨率。
    // 原生导出对这四路只做等比缩放 + 居中补边（不裁剪、不拉伸），所以预览也不需要 zoomX。
    previewSlots: [
      { slotId: 'topLeft', x: 0, y: 0, width: 0.5, height: 0.5 },
      { slotId: 'topRight', x: 0.5, y: 0, width: 0.5, height: 0.5 },
      { slotId: 'bottomLeft', x: 0, y: 0.5, width: 0.5, height: 0.5 },
      { slotId: 'bottomRight', x: 0.5, y: 0.5, width: 0.5, height: 0.5 }
    ],
    ffmpegPolicy: {
      needSideTrack: true,
      needSide2Track: true,
      disableFrontAudio: false,
      frontTrackCandidates: [CameraPosition.FRONT, CameraPosition.LEFT_FRONT, CameraPosition.RIGHT_FRONT],
      backTrackCandidates: [CameraPosition.REAR, CameraPosition.RIGHT_FRONT, CameraPosition.LEFT_FRONT],
      sideTrackCandidates: [CameraPosition.LEFT, CameraPosition.LEFT_FRONT, CameraPosition.RIGHT_FRONT],
      side2TrackCandidates: [CameraPosition.RIGHT, CameraPosition.RIGHT_FRONT, CameraPosition.LEFT_FRONT],
      alignSideByFrontTimeline: true,
      ignoreNativeTrackSelection: true
    }
  }
}

export function isTemplateId(value: string): boolean {
  return value === TemplateId.T1 || value === TemplateId.T2 || value === TemplateId.T3 ||
    value === TemplateId.T4 || value === TemplateId.T5 || value === TemplateId.T6
}

export function normalizeTemplateIdValue(value: string): TemplateId {
  if (isTemplateId(value)) {
    return value as TemplateId
  }
  return DEFAULT_TEMPLATE_ID
}

export function resolveTemplateDefinition(value: string): TemplateDefinition {
  const templateId = normalizeTemplateIdValue(value)
  return TEMPLATE_DEFINITION_MAP[templateId]
}

export function listTemplateDefinitions(): Array<TemplateDefinition> {
  return [
    TEMPLATE_DEFINITION_MAP[TemplateId.T1],
    TEMPLATE_DEFINITION_MAP[TemplateId.T2],
    TEMPLATE_DEFINITION_MAP[TemplateId.T3],
    TEMPLATE_DEFINITION_MAP[TemplateId.T4],
    TEMPLATE_DEFINITION_MAP[TemplateId.T5],
    TEMPLATE_DEFINITION_MAP[TemplateId.T6]
  ]
}

/**
 * 剪辑页模板条的**展示顺序**，与模板定义的全量顺序解耦。
 *
 * `listTemplateDefinitions()` 保持 T1..T6 的稳定全量顺序（测试、原生契约一致性检查都依赖它），
 * 这里只表达"用户在剪辑页看到什么顺序"：把常用的单视角/双录前置，四机位放在三分屏之前。
 * 需求来源：用户要求剪辑页顺序为「T5 T1 T2 四机位 T3 T4」。
 */
export const EDITOR_TEMPLATE_DISPLAY_ORDER: Array<TemplateId> = [
  TemplateId.T5,
  TemplateId.T1,
  TemplateId.T2,
  TemplateId.T6,
  TemplateId.T3,
  TemplateId.T4
]

/** 剪辑页模板条用的模板定义列表（按 EDITOR_TEMPLATE_DISPLAY_ORDER 排列）。 */
export function listEditorTemplateDefinitions(): Array<TemplateDefinition> {
  const out: Array<TemplateDefinition> = []
  for (let i = 0; i < EDITOR_TEMPLATE_DISPLAY_ORDER.length; i++) {
    out.push(TEMPLATE_DEFINITION_MAP[EDITOR_TEMPLATE_DISPLAY_ORDER[i]])
  }
  return out
}

export interface PlaybackState {
  playheadMs: number
  segments: Array<ExportSegment>
}

export interface BrandState {
  watermarkEnabled: boolean
}

export interface EditorUiState {
  drawerExpanded: boolean
  exporting: boolean
  exportStatus: string
}

export interface EditorState {
  sessionId: string
  trip: Trip
  selectedTemplateId: TemplateId
  playback: PlaybackState
  brand: BrandState
  ui: EditorUiState
}

export interface ExportSnapshot {
  sessionId: string
  createdAt: number
  trip: Trip
  selectedTemplateId: TemplateId
  playback: PlaybackState
  brand: BrandState
}

function emptyTrack(camera: CameraPosition): CameraTrack {
  return { camera: camera, segments: [] }
}

export function toCameraPosition(camera: string): CameraPosition {
  if (camera === 'Front') {
    return CameraPosition.FRONT
  }
  if (camera === 'Back') {
    return CameraPosition.REAR
  }
  if (camera === 'Left') {
    return CameraPosition.LEFT
  }
  if (camera === 'Right') {
    return CameraPosition.RIGHT
  }
  if (camera === 'LeftFront') {
    return CameraPosition.LEFT_FRONT
  }
  if (camera === 'RightFront') {
    return CameraPosition.RIGHT_FRONT
  }
  return CameraPosition.FRONT
}

export function toLegacyCamera(camera: CameraPosition): string {
  if (camera === CameraPosition.FRONT) {
    return 'Front'
  }
  if (camera === CameraPosition.REAR) {
    return 'Back'
  }
  if (camera === CameraPosition.LEFT) {
    return 'Left'
  }
  if (camera === CameraPosition.RIGHT) {
    return 'Right'
  }
  if (camera === CameraPosition.LEFT_FRONT) {
    return 'LeftFront'
  }
  return 'RightFront'
}

function toTemplateId(value: string): TemplateId {
  return normalizeTemplateIdValue(value)
}

export function tripFromSnapshot(snapshot: TripSnapshot): Trip {
  const tracks: Record<CameraPosition, CameraTrack> = {
    [CameraPosition.FRONT]: emptyTrack(CameraPosition.FRONT),
    [CameraPosition.REAR]: emptyTrack(CameraPosition.REAR),
    [CameraPosition.LEFT]: emptyTrack(CameraPosition.LEFT),
    [CameraPosition.RIGHT]: emptyTrack(CameraPosition.RIGHT),
    [CameraPosition.LEFT_FRONT]: emptyTrack(CameraPosition.LEFT_FRONT),
    [CameraPosition.RIGHT_FRONT]: emptyTrack(CameraPosition.RIGHT_FRONT)
  }
  snapshot.clips
    .filter((clip: DvrMeta) => clip.uri.length > 0)
    .sort((a: DvrMeta, b: DvrMeta) => a.timestamp - b.timestamp)
    .forEach((clip: DvrMeta, index: number) => {
      const camera = toCameraPosition(clip.camera)
      const segment: ClipSegment = {
        clipId: `${snapshot.id}_${camera}_${clip.timestamp}_${index}`,
        camera: camera,
        uri: clip.uri,
        timestampMs: clip.timestamp,
        durationSec: 60
      }
      tracks[camera].segments.push(segment)
    })
  return {
    tripId: snapshot.id,
    title: snapshot.tripTitle,
    rangeText: snapshot.tripRange,
    durationSec: snapshot.durationSec,
    tracks: tracks,
    startTs: snapshot.startTs,
    endTs: snapshot.endTs
  }
}

export function createEditorStateFromSnapshot(
  snapshot: TripSnapshot,
  sessionId: string,
  templateId: string,
  segments: Array<Segment>,
  watermarkEnabled: boolean,
  drawerExpanded: boolean,
  exportStatus: string
): EditorState {
  const trip = tripFromSnapshot(snapshot)
  return {
    sessionId: sessionId,
    trip: trip,
    selectedTemplateId: toTemplateId(templateId),
    playback: {
      playheadMs: 0,
      segments: toExportSegments(segments)
    },
    brand: {
      watermarkEnabled: watermarkEnabled
    },
    ui: {
      drawerExpanded: drawerExpanded,
      exporting: false,
      exportStatus: exportStatus
    }
  }
}

export function deepCloneExportSnapshot(state: EditorState): ExportSnapshot {
  const raw = JSON.parse(JSON.stringify({
    sessionId: state.sessionId,
    createdAt: Date.now(),
    trip: state.trip,
    selectedTemplateId: state.selectedTemplateId,
    playback: state.playback,
    brand: state.brand
  })) as ExportSnapshot
  return raw
}

/**
 * 解析历史记录里存的 ExportSnapshot JSON。
 *
 * 与 parseEditRecords 同样是**永不抛错**的防御式解析：这份字符串来自磁盘，
 * 可能是旧版本写的、可能写坏了。缺 trip 或 playback.segments 不是数组时
 * 一律当不可用 —— 宁可让用户看到「这条记录打不开」，也不能拿半个快照
 * 去还原出一个参数错乱的剪辑页。
 */
export function parseExportSnapshot(raw: string): ExportSnapshot | undefined {
  if (raw.length === 0) {
    return undefined
  }
  let parsed: ExportSnapshot | undefined = undefined
  try {
    parsed = JSON.parse(raw) as ExportSnapshot
  } catch (error) {
    return undefined
  }
  if (!parsed || !parsed.trip || !parsed.playback) {
    return undefined
  }
  if (!Array.isArray(parsed.playback.segments)) {
    return undefined
  }
  return parsed
}

/**
 * 记录与现场行程的身份校验。
 *
 * **不能只信 tripId**：它的构造含「该分组在整次扫描里的序号」，用户删掉靠前的
 * 源素材后，后面的行程会整体重编号，一个存下来的 tripId 会静默指向另一趟行程，
 * 于是「还原」会把用户带到别人的片段上。标题 + 起点这对字段稳定得多。
 * 标题为空一律判不匹配 —— 那说明记录本身残缺，宁可报错也不能猜。
 */
export function snapshotMatchesTrip(stored: ExportSnapshot, live: TripSnapshot): boolean {
  const storedTitle = stored.trip ? stored.trip.title : ''
  if (storedTitle.length === 0) {
    return false
  }
  return storedTitle === live.tripTitle && stored.trip.startTs === live.startTs
}

/**
 * 用历史快照还原出一份编辑器状态。
 *
 * 权威来源是**分裂**的，这是本函数最要紧的一条约定：
 *   - 素材（trip）以**现场**为准 —— 快照里的 URI 是上次导出时的路径，源文件
 *     可能已被用户删掉或换过位置，照抄只会得到一堆打不开的片段；
 *   - 参数（模板、播放头、分段、水印）以**记录**为准 —— 这正是用户点
 *     「重新剪辑」想拿回来的东西。
 * 两边对不上时由调用方先用 snapshotMatchesTrip 拦下，本函数不重复判断。
 */
export function restoreEditorStateFromSnapshot(
  stored: ExportSnapshot,
  live: TripSnapshot,
  sessionId: string,
  exportStatus: string
): EditorState {
  return {
    sessionId: sessionId,
    trip: tripFromSnapshot(live),
    selectedTemplateId: toTemplateId(stored.selectedTemplateId),
    playback: {
      playheadMs: stored.playback.playheadMs,
      segments: JSON.parse(JSON.stringify(stored.playback.segments)) as Array<ExportSegment>
    },
    brand: {
      watermarkEnabled: stored.brand.watermarkEnabled
    },
    ui: {
      drawerExpanded: true,
      exporting: false,
      exportStatus: exportStatus
    }
  }
}
