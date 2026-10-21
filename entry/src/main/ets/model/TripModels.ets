import { TimelineTrackModel } from './AppState'



export class DvrMeta {
  fileName: string = ''
  uri: string = ''
  date: string = ''
  time: string = ''
  camera: string = ''
  timestamp: number = 0
}

export class TripSnapshot {
  id: string = ''
  title: string = ''
  subtitle: string = ''
  durationSec: number = 60
  segmentCount: number = 1
  tripTitle: string = ''
  tripRange: string = ''
  previewUri: string = ''
  previewFrameUri: string = ''
  previewCamera: string = ''
  clips: Array<DvrMeta> = []
  timeline: Array<TimelineTrackModel> = []
  startTs: number = 0
  endTs: number = 0
  /**
   * 这趟行程由**几组**行程合并而来；没做过合并就是 1。
   *
   * 合并剪辑在 `mergeTrips` 里把选中的几趟拼成一个快照，这个数就是当时选了几趟。
   * 剪辑页标题下面那行「N 组 · N 视角」里的组数读它 —— 组的单位是**行程**，不是段。
   */
  groupCount: number = 1
}

export class PreviewSource {
  uri: string = ''
  frameUri: string = ''
  camera: string = ''
}

/** 导出用的一段：毫秒区间 + 该段自己的倍速与声音开关。 */
export class ExportSegment {
  startMs: number = 0
  endMs: number = 0
  speedLabel: string = '1.0X'
  muted: boolean = false
}

export class ExportComposeRequest {
  fileName: string = ''
  outputPath: string = ''
  preferredMode: string = 'A_FFMPEG'
  frontUris: Array<string> = []
  backUris: Array<string> = []
  sideUris: Array<string> = []
  /** T4 四机位专用第 4 路（右下 / 右后）；其余模板保持空数组。 */
  side2Uris: Array<string> = []
  expectedDurationSec: number = 0
  rangeStartMs: number = 0
  rangeEndMs: number = 0
  templateId: string = 'T1'
  speedLabel: string = '1.0X'
  muted: boolean = false
  watermarkEnabled: boolean = true
  /** 多段导出：native 侧优先读它；上面四个单值字段是过渡兼容。 */
  segments: Array<ExportSegment> = []
}
