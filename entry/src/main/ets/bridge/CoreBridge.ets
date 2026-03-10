import {
  EditorLayerModel,
  EditorStateModel,
  LibraryStateModel,
  TemplateCardModel,
  TimelineMarkerModel,
  TimelineTrackModel,
  TripCardModel
} from '../model/AppState'
import { CAMERA_ORDER, DvrMeta, ExportComposeRequest, TripSnapshot } from '../model/TripModels'
import { parseDvrFileName, pickPreviewSource } from '../service/DvrScannerService'
import { buildTimeline, mergeTimeline } from '../service/TimelineService'
import { buildComposeRequestByService } from '../service/ExportService'
import { executeFfmpegComposeByService } from '../service/ExportRuntimeService'
import { debugLog } from '../utils/Logger'
import photoAccessHelper from '@ohos.file.photoAccessHelper'
import dataSharePredicates from '@ohos.data.dataSharePredicates'
import common from '@ohos.app.ability.common'
import fs from '@ohos.file.fs'

const JS_BRIDGE_ENTRY: string = 'entry/src/main/js/harmonyBridge.mjs'
const HUAWEI_SHARE_ALBUM_NAMES: Array<string> = ['华为分享', 'Huawei Share']
const CLIP_DURATION_SEC: number = 60
const EXPORT_PIPELINE_VERSION: string = 'native-stack-v6'
const EDITOR_SPEEDS: Array<string> = ['1.0X', '4.0X', '8.0X', '16.0X']
const DEFAULT_TEMPLATE_ID: string = 'T2'
const TEMPLATE_CARDS: Array<TemplateCardModel> = [
  { id: 'T1', title: '单视角', subtitle: '16:9' },
  { id: 'T2', title: '画中画', subtitle: '16:9' },
  { id: 'T3', title: '矩阵', subtitle: '16:9' },
  { id: 'T4', title: '旅拍', subtitle: '9:16' }
]

function toTimeText(date: Date): string {
  const hh = date.getHours().toString().padStart(2, '0')
  const mm = date.getMinutes().toString().padStart(2, '0')
  const ss = date.getSeconds().toString().padStart(2, '0')
  return `${hh}:${mm}:${ss}`
}

function secondsToClock(totalSec: number): string {
  const sec = Math.max(0, totalSec)
  const hour = Math.floor(sec / 3600)
  const minute = Math.floor((sec % 3600) / 60)
  const second = sec % 60
  return `${hour.toString().padStart(2, '0')}:${minute.toString().padStart(2, '0')}:${second.toString().padStart(2, '0')}`
}

export class CoreBridge {
  private readonly requiredPermissions: Array<string> = ['ohos.permission.READ_MEDIA', 'ohos.permission.READ_IMAGEVIDEO', 'ohos.permission.WRITE_MEDIA']
  private readonly jsBridgeEntry: string = JS_BRIDGE_ENTRY
  private cards: Array<TripCardModel> = []
  private trips: Map<string, TripSnapshot> = new Map()
  private tripId: string = ''
  private tripTitle: string = '夜间行车'
  private tripRange: string = '00:00:00 - 00:00:00'
  private tripDurationSec: number = 60
  private tripTimeline: Array<TimelineTrackModel> = []
  private previewUri: string = ''
  private previewCamera: string = ''
  private currentClipIndex: number = 0
  private currentClipTotal: number = 0
  private hideSpeed: boolean = true
  private hideGps: boolean = true
  private hideVin: boolean = true
  private playheadMs: number = 0
  private selectionStartSec: number = 0
  private selectionEndSec: number = CLIP_DURATION_SEC
  private activeTemplateId: string = DEFAULT_TEMPLATE_ID
  private drawerExpanded: boolean = true
  private speedIndex: number = 0
  private muted: boolean = false
  private watermarkEnabled: boolean = true
  private exportStatusText: string = '待导出'
  private exporting: boolean = false
  private exportProgress: number = 0
  private exportTimer: number = -1
  private lastContext?: common.UIAbilityContext = undefined

  getJsBridgeEntry(): string {
    return this.jsBridgeEntry
  }

  getRequiredPermissions(): Array<string> {
    return [...this.requiredPermissions]
  }

  private async collectDvrMetas(fetchResult: photoAccessHelper.FetchResult<photoAccessHelper.PhotoAsset>): Promise<Array<DvrMeta>> {
    let count: number = 0
    try {
      count = fetchResult.getCount()
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('扫描', `读取资源数量失败，原因=${message}`)
      return []
    }
    const metas: Array<DvrMeta> = []
    for (let i = 0; i < count; i++) {
      try {
        const asset = await fetchResult.getObjectByPosition(i)
        const name = String(asset?.displayName ?? '')
        const uri = String(asset?.uri ?? '')
        const parsed = parseDvrFileName(name, uri)
        if (parsed !== null) {
          metas.push(parsed)
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        debugLog('扫描', `跳过异常资源，索引=${i}，原因=${message}`)
      }
    }
    return metas
  }

  private async fallbackScanAllAssets(helper: photoAccessHelper.PhotoAccessHelper): Promise<Array<DvrMeta>> {
    const fallbackFetchOptions: photoAccessHelper.FetchOptions = {
      fetchColumns: [],
      predicates: new dataSharePredicates.DataSharePredicates()
    }
    let fallbackList: photoAccessHelper.FetchResult<photoAccessHelper.PhotoAsset>
    try {
      fallbackList = await helper.getAssets(fallbackFetchOptions)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      throw new Error(`降级扫描获取资产失败：${message}`)
    }
    const fallbackMetas = await this.collectDvrMetas(fallbackList)
    debugLog('扫描', `降级全量扫描完成，匹配DVR视频=${fallbackMetas.length}`)
    return fallbackMetas
  }

  private async readHuaweiShareDvrFiles(context: common.UIAbilityContext): Promise<Array<DvrMeta>> {
    const helper = photoAccessHelper.getPhotoAccessHelper(context)
    let album: photoAccessHelper.Album | undefined = undefined
    let albumLookupFailed: boolean = false
    for (let i = 0; i < HUAWEI_SHARE_ALBUM_NAMES.length; i++) {
      try {
        const albumPredicates = new dataSharePredicates.DataSharePredicates()
        albumPredicates.equalTo('album_name', HUAWEI_SHARE_ALBUM_NAMES[i])
        const albumFetchOptions: photoAccessHelper.FetchOptions = {
          fetchColumns: [],
          predicates: albumPredicates
        }
        const albumList = await helper.getAlbums(photoAccessHelper.AlbumType.USER, photoAccessHelper.AlbumSubtype.USER_GENERIC, albumFetchOptions)
        const found = await albumList.getFirstObject()
        if (found) {
          album = found
          break
        }
      } catch (error) {
        albumLookupFailed = true
        const message = error instanceof Error ? error.message : String(error)
        debugLog('扫描', `查询华为分享专辑失败，名称=${HUAWEI_SHARE_ALBUM_NAMES[i]}，原因=${message}`)
      }
    }
    if (!album) {
      if (albumLookupFailed) {
        debugLog('扫描', '查询专辑失败，准备降级全量扫描')
        return this.fallbackScanAllAssets(helper)
      }
      debugLog('扫描', '未找到“华为分享/Huawei Share”相册')
      return []
    }
    try {
      const assetFetchOptions: photoAccessHelper.FetchOptions = {
        fetchColumns: [],
        predicates: new dataSharePredicates.DataSharePredicates()
      }
      const assetList = await album.getAssets(assetFetchOptions)
      const metas = await this.collectDvrMetas(assetList)
      debugLog('扫描', `华为分享匹配DVR视频=${metas.length}`)
      return metas
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('扫描', `读取华为分享专辑失败，准备降级全量扫描，原因=${message}`)
      return this.fallbackScanAllAssets(helper)
    }
  }

  private buildTripsFromMetas(metas: Array<DvrMeta>): Array<TripSnapshot> {
    if (metas.length === 0) {
      return []
    }
    metas.sort((a: DvrMeta, b: DvrMeta) => a.timestamp - b.timestamp)
    const groupsMap: Map<number, Array<DvrMeta>> = new Map()
    metas.forEach((item: DvrMeta) => {
      const list = groupsMap.get(item.timestamp) ?? []
      list.push(item)
      groupsMap.set(item.timestamp, list)
    })
    const sortedKeys = Array.from(groupsMap.keys()).sort((a: number, b: number) => a - b)
    const groups: Array<Array<DvrMeta>> = sortedKeys.map((key: number) => groupsMap.get(key) ?? [])

    const trips: Array<TripSnapshot> = []
    groups.forEach((group: Array<DvrMeta>, index: number) => {
      const startTs = group[0].timestamp
      const endTs = startTs + CLIP_DURATION_SEC * 1000
      const startDate = new Date(startTs)
      const endDate = new Date(endTs)
      const title = group[0].date
      const startText = toTimeText(startDate)
      const endText = toTimeText(endDate)
      const cameraSet = new Set(group.map((item: DvrMeta) => item.camera))
      const durationSec = CLIP_DURATION_SEC
      const preview = pickPreviewSource(group)
      const trip = new TripSnapshot()
      trip.id = `trip-${title}-${startText.replace(/:/g, '')}-${index}`
      trip.title = title
      trip.subtitle = `${startText} - ${endText} · ${cameraSet.size} 视角`
      trip.durationSec = durationSec
      trip.tripTitle = `${title.replace(/-/g, '/')} 夜间行车`
      trip.tripRange = `${startText} - ${endText}`
      trip.previewUri = preview.uri
      trip.previewCamera = preview.camera
      trip.clips = [...group]
      trip.timeline = buildTimeline(group)
      trip.startTs = startTs
      trip.endTs = endTs
      trips.push(trip)
    })
    return trips
  }

  mergeTrips(tripIds: Array<string>): string {
    const selected: Array<TripSnapshot> = []
    tripIds.forEach((id: string) => {
      const trip = this.trips.get(id)
      if (trip !== undefined) {
        selected.push(trip)
      }
    })
    selected.sort((a: TripSnapshot, b: TripSnapshot) => a.startTs - b.startTs)
    if (selected.length === 0) {
      return ''
    }
    if (selected.length === 1) {
      return selected[0].id
    }
    const startTs = selected[0].startTs
    const endTs = selected[selected.length - 1].endTs
    const startDate = new Date(startTs)
    const endDate = new Date(endTs)
    const title = selected[0].title
    const timeline = mergeTimeline(selected.map((item: TripSnapshot) => item.timeline))
    const preview = selected.find((item: TripSnapshot) => item.previewUri.length > 0)
    const mergedClips: Array<DvrMeta> = []
    selected.forEach((item: TripSnapshot) => {
      item.clips.forEach((clip: DvrMeta) => {
        mergedClips.push(clip)
      })
    })
    mergedClips.sort((a: DvrMeta, b: DvrMeta) => a.timestamp - b.timestamp)
    const merged = new TripSnapshot()
    merged.id = `trip-merged-${title}-${toTimeText(startDate).replace(/:/g, '')}-${selected.length}`
    merged.title = title
    merged.subtitle = `${toTimeText(startDate)} - ${toTimeText(endDate)} · ${timeline.length} 视角`
    merged.durationSec = Math.max(1, Math.floor((endTs - startTs) / 1000))
    merged.tripTitle = `${title.replace(/-/g, '/')} 合并行程`
    merged.tripRange = `${toTimeText(startDate)} - ${toTimeText(endDate)}`
    merged.previewUri = preview?.previewUri ?? ''
    merged.previewCamera = preview?.previewCamera ?? ''
    merged.clips = mergedClips
    merged.timeline = timeline
    merged.startTs = startTs
    merged.endTs = endTs
    this.trips.set(merged.id, merged)
    debugLog('扫描', `已创建合并行程，片段组数=${selected.length}`)
    return merged.id
  }

  async createLibraryState(permissionGranted: boolean, context?: common.UIAbilityContext): Promise<LibraryStateModel> {
    debugLog('扫描', `开始构建行程，授权状态=${permissionGranted}`)
    this.lastContext = context
    if (!permissionGranted) {
      return {
        title: '行程库',
        cards: [],
        empty: true,
        emptyText: '缺少权限：ohos.permission.READ_MEDIA、ohos.permission.READ_IMAGEVIDEO、ohos.permission.WRITE_MEDIA，请在系统设置中开启后重试。',
        permissionTip: '请授权相册与 Huawei Share 读取权限'
      }
    }

    if (!context) {
      debugLog('扫描', '缺少上下文，无法访问相册')
      return {
        title: '行程库',
        cards: [],
        empty: true,
        emptyText: '无法访问相册上下文，请重启应用后重试',
        permissionTip: ''
      }
    }

    try {
      const metas = await this.readHuaweiShareDvrFiles(context)
      const tripSnapshots = this.buildTripsFromMetas(metas)
      this.trips.clear()
      this.cards = tripSnapshots.map((item: TripSnapshot) => {
        this.trips.set(item.id, item)
        const card: TripCardModel = {
          id: item.id,
          title: item.title,
          subtitle: item.subtitle,
          durationText: `${item.durationSec}s`,
          durationSec: item.durationSec,
          previewUri: item.previewUri
        }
        return card
      })
      if (tripSnapshots.length > 0) {
        const tripSummary = tripSnapshots.map((item: TripSnapshot) => `${item.id}:${item.subtitle}`).join(' | ')
        debugLog('扫描', `分组明细=${tripSummary}`)
        const first = tripSnapshots[0]
        this.tripId = first.id
        this.tripTitle = first.tripTitle
        this.tripRange = first.tripRange
        this.tripDurationSec = first.durationSec
        this.tripTimeline = first.timeline
      } else {
        this.tripId = ''
        this.tripTitle = '夜间行车'
        this.tripRange = '00:00:00 - 00:00:00'
        this.tripDurationSec = 60
        this.tripTimeline = []
      }
      debugLog('扫描', `分组完成，行程组数=${tripSnapshots.length}`)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('扫描', `读取华为分享失败：${message}`)
      return {
        title: '行程库',
        cards: [],
        empty: true,
        emptyText: '读取华为分享失败，请在系统设置中开启“照片和视频”权限后重试',
        permissionTip: ''
      }
    }

    return {
      title: '行程库',
      cards: [...this.cards],
      empty: this.cards.length === 0,
      emptyText: this.cards.length === 0 ? '请通过 Huawei Share 分享记录仪视频到手机相册' : '',
      permissionTip: ''
    }
  }

  private buildEditorState(snapshot?: TripSnapshot, preferredCamera?: string, preferredIndex?: number): EditorStateModel {
    let activeSnapshot = snapshot
    if (!activeSnapshot) {
      const cached = this.trips.get(this.tripId)
      if (cached) {
        activeSnapshot = cached
      }
    }
    if (activeSnapshot) {
      this.tripId = activeSnapshot.id
      this.tripTitle = activeSnapshot.tripTitle
      this.tripRange = activeSnapshot.tripRange
      this.tripDurationSec = activeSnapshot.durationSec
      this.tripTimeline = activeSnapshot.timeline
      const timelineCameraSet = new Set(this.tripTimeline.map((item: TimelineTrackModel) => item.cameraPosition))
      let camera = preferredCamera ?? activeSnapshot.previewCamera
      if (camera.length === 0 || !timelineCameraSet.has(camera)) {
        camera = this.tripTimeline[0]?.cameraPosition ?? activeSnapshot.previewCamera
      }
      const cameraClips = activeSnapshot.clips
        .filter((item: DvrMeta) => item.camera === camera && item.uri.length > 0)
        .sort((a: DvrMeta, b: DvrMeta) => a.timestamp - b.timestamp)
      let index = preferredIndex ?? 0
      if (cameraClips.length === 0) {
        const anyClip = activeSnapshot.clips.find((item: DvrMeta) => item.uri.length > 0)
        this.previewUri = anyClip?.uri ?? ''
        this.previewCamera = anyClip?.camera ?? camera
        this.currentClipIndex = 0
        this.currentClipTotal = anyClip ? 1 : 0
      } else {
        index = Math.max(0, Math.min(index, cameraClips.length - 1))
        this.previewUri = cameraClips[index].uri
        this.previewCamera = camera
        this.currentClipIndex = index
        this.currentClipTotal = cameraClips.length
      }
      const trackSummary = this.tripTimeline.map((item: TimelineTrackModel) => `${item.cameraPosition}:${item.segmentCount}`).join(',')
      debugLog('剪辑', `状态刷新，范围=${this.tripRange}，轨道=${trackSummary}，预览视角=${this.previewCamera}，索引=${this.currentClipIndex + 1}/${this.currentClipTotal}`)
    }
    if (this.tripTimeline.length === 0) {
      debugLog('剪辑', '轨道为空，注入默认占位轨道')
      this.tripTimeline = [
        { cameraPosition: 'Front', segmentCount: 1, degraded: true }
      ]
      this.previewUri = ''
      this.previewCamera = 'Front'
      this.currentClipIndex = 0
      this.currentClipTotal = 0
    }
    this.selectionStartSec = Math.max(0, Math.min(this.selectionStartSec, this.tripDurationSec))
    this.selectionEndSec = Math.max(this.selectionStartSec, Math.min(this.selectionEndSec, this.tripDurationSec))
    const segmentCount = Math.max(1, Math.ceil(this.tripDurationSec / CLIP_DURATION_SEC))
    const markers: Array<TimelineMarkerModel> = []
    for (let i = 1; i < segmentCount; i++) {
      markers.push({
        positionSec: Math.min(this.tripDurationSec, i * CLIP_DURATION_SEC),
        style: 'dashed'
      })
    }
    const layers: Array<EditorLayerModel> = [
      { name: 'preview', heightRatio: 0.52 },
      { name: 'control', heightRatio: 0.12 },
      { name: 'timeline', heightRatio: 0.16 },
      { name: 'drawer', heightRatio: 0.20 }
    ]
    return {
      tripId: this.tripId,
      tripTitle: this.tripTitle,
      timeRange: this.tripRange,
      previewUri: this.previewUri,
      previewCamera: this.previewCamera,
      canPlayPrev: this.currentClipTotal > 0 && this.currentClipIndex > 0,
      canPlayNext: this.currentClipTotal > 0 && this.currentClipIndex < this.currentClipTotal - 1,
      currentClipIndex: this.currentClipTotal === 0 ? 0 : this.currentClipIndex + 1,
      currentClipTotal: this.currentClipTotal,
      playheadText: `00:00:00 / ${secondsToClock(this.tripDurationSec)}`,
      totalDurationSec: this.tripDurationSec,
      timeline: this.tripTimeline,
      layers: layers,
      selectionStartSec: this.selectionStartSec,
      selectionEndSec: this.selectionEndSec,
      boundaryMarkers: markers,
      templateCards: [...TEMPLATE_CARDS],
      activeTemplateId: this.activeTemplateId,
      drawerExpanded: this.drawerExpanded,
      speedLabel: EDITOR_SPEEDS[this.speedIndex],
      muted: this.muted,
      watermarkEnabled: this.watermarkEnabled,
      hideSpeed: this.hideSpeed,
      hideGps: this.hideGps,
      hideVin: this.hideVin,
      exportStatusText: this.exportStatusText
    }
  }

  createEditorState(tripId: string, titleHint: string, subtitleHint: string): EditorStateModel {
    debugLog('剪辑', `加载行程详情，行程ID=${tripId}`)
    const selected = this.trips.get(tripId)
    this.playheadMs = 0
    this.selectionStartSec = 0
    this.selectionEndSec = this.tripDurationSec
    this.activeTemplateId = DEFAULT_TEMPLATE_ID
    this.drawerExpanded = true
    this.speedIndex = 0
    this.muted = false
    this.watermarkEnabled = true
    this.exportStatusText = '待导出'
    if (selected) {
      this.selectionEndSec = selected.durationSec
      const trackSummary = selected.timeline.map((item: TimelineTrackModel) => `${item.cameraPosition}:${item.segmentCount}`).join(',')
      debugLog('剪辑', `命中缓存行程，范围=${selected.tripRange}，时长=${selected.durationSec}s，轨道=${trackSummary}，预览视角=${selected.previewCamera}，预览URI长度=${selected.previewUri.length}`)
      return this.buildEditorState(selected, selected.previewCamera, 0)
    }
    debugLog('剪辑', `未命中缓存行程，回退参数模式，titleHint=${titleHint} subtitleHint=${subtitleHint}`)
    if (tripId.length > 0) {
      this.tripId = tripId
    }
    if (titleHint.length > 0) {
      this.tripTitle = `${titleHint.replace(/-/g, '/')} 夜间行车`
    }
    if (subtitleHint.length > 0) {
      const parts = subtitleHint.split('·')
      this.tripRange = parts[0].trim()
    }
    return this.buildEditorState(undefined, 'Front', 0)
  }

  updatePlayhead(positionMs: number): string {
    const maxMs = this.tripDurationSec * 1000
    this.playheadMs = Math.max(0, Math.min(positionMs, maxMs))
    const second: number = Math.floor(this.playheadMs / 1000)
    const text = `${secondsToClock(second)} / ${secondsToClock(this.tripDurationSec)}`
    return text
  }

  updateSelectionRange(startSec: number, endSec: number): EditorStateModel {
    const max = Math.max(0, this.tripDurationSec)
    const nextStart = Math.max(0, Math.min(Math.floor(startSec), max))
    const nextEnd = Math.max(nextStart, Math.min(Math.floor(endSec), max))
    this.selectionStartSec = nextStart
    this.selectionEndSec = nextEnd
    this.playheadMs = Math.max(nextStart * 1000, Math.min(this.playheadMs, nextEnd * 1000))
    const snapshot = this.trips.get(this.tripId)
    return this.buildEditorState(snapshot, this.previewCamera, this.currentClipIndex)
  }

  selectTemplate(templateId: string): EditorStateModel {
    const exists = TEMPLATE_CARDS.some((item: TemplateCardModel) => item.id === templateId)
    this.activeTemplateId = exists ? templateId : DEFAULT_TEMPLATE_ID
    const snapshot = this.trips.get(this.tripId)
    return this.buildEditorState(snapshot, this.previewCamera, this.currentClipIndex)
  }

  toggleTemplateDrawer(expanded: boolean): EditorStateModel {
    this.drawerExpanded = expanded
    const snapshot = this.trips.get(this.tripId)
    return this.buildEditorState(snapshot, this.previewCamera, this.currentClipIndex)
  }

  cycleSpeed(): EditorStateModel {
    this.speedIndex = (this.speedIndex + 1) % EDITOR_SPEEDS.length
    const snapshot = this.trips.get(this.tripId)
    return this.buildEditorState(snapshot, this.previewCamera, this.currentClipIndex)
  }

  toggleMuted(): EditorStateModel {
    this.muted = !this.muted
    const snapshot = this.trips.get(this.tripId)
    return this.buildEditorState(snapshot, this.previewCamera, this.currentClipIndex)
  }

  toggleWatermark(): EditorStateModel {
    this.watermarkEnabled = !this.watermarkEnabled
    const snapshot = this.trips.get(this.tripId)
    return this.buildEditorState(snapshot, this.previewCamera, this.currentClipIndex)
  }

  updatePrivacy(type: string, enabled: boolean): EditorStateModel {
    debugLog('剪辑', `更新隐私开关，类型=${type}，值=${enabled}`)
    if (type === 'speed') {
      this.hideSpeed = enabled
    } else if (type === 'gps') {
      this.hideGps = enabled
    } else if (type === 'vin') {
      this.hideVin = enabled
    }
    const snapshot = this.trips.get(this.tripId)
    return this.buildEditorState(snapshot, this.previewCamera, this.currentClipIndex)
  }

  switchCamera(camera: string): EditorStateModel {
    debugLog('剪辑', `切换视角，目标=${camera}`)
    const snapshot = this.trips.get(this.tripId)
    return this.buildEditorState(snapshot, camera, 0)
  }

  playPrevClip(): EditorStateModel {
    const snapshot = this.trips.get(this.tripId)
    return this.buildEditorState(snapshot, this.previewCamera, this.currentClipIndex - 1)
  }

  playNextClip(): EditorStateModel {
    const snapshot = this.trips.get(this.tripId)
    return this.buildEditorState(snapshot, this.previewCamera, this.currentClipIndex + 1)
  }

  private clearExportTimer(): void {
    if (this.exportTimer >= 0) {
      clearInterval(this.exportTimer)
      this.exportTimer = -1
    }
  }

  private buildExportFileName(): string {
    const now = new Date()
    const yyyy = now.getFullYear().toString()
    const mm = (now.getMonth() + 1).toString().padStart(2, '0')
    const dd = now.getDate().toString().padStart(2, '0')
    const hh = now.getHours().toString().padStart(2, '0')
    const min = now.getMinutes().toString().padStart(2, '0')
    const ss = now.getSeconds().toString().padStart(2, '0')
    return `SmartDrive_Export_${yyyy}${mm}${dd}_${hh}${min}${ss}.mp4`
  }

  getExportStatusText(): string {
    return this.exportStatusText
  }

  private startExportPipeline(fileName: string): void {
    this.exporting = true
    this.exportProgress = 0
    debugLog('导出', `开始执行导出，目标文件=${fileName}`)
    this.updateExportProgress(fileName, 0)
    void this.finishExport(fileName)
  }

  private updateExportProgress(fileName: string, percent: number): void {
    const normalized = Math.max(0, Math.min(100, Math.floor(percent)))
    if (normalized === this.exportProgress) {
      return
    }
    this.exportProgress = normalized
    this.exportStatusText = `导出处理中 ${normalized}%（${fileName}）`
    debugLog('导出', `导出进度=${normalized}% 文件=${fileName}`)
  }

  private async finishExport(fileName: string): Promise<void> {
    try {
      const snapshot = this.trips.get(this.tripId)
      const sourceUri = await this.composeExportSourceUri(snapshot, fileName, (progress: number) => {
        this.updateExportProgress(fileName, progress)
      })
      this.updateExportProgress(fileName, 100)
      const albumUri = await this.saveVideoToAlbum(fileName, sourceUri)
      this.exporting = false
      this.exportStatusText = `导出完成：${fileName}（相册URI=${albumUri}）`
      debugLog('导出', `导出任务完成，文件名=${fileName}，相册URI=${albumUri}`)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      this.exporting = false
      this.exportStatusText = `导出失败：${message}`
      debugLog('导出', `导出任务失败，原因=${message}`)
    }
  }

  private buildComposeRequest(snapshot: TripSnapshot, fileName: string): ExportComposeRequest {
    const baseDir = this.lastContext?.cacheDir ?? this.lastContext?.filesDir ?? '/data/storage/el2/base/files'
    const outputPath = `${baseDir}/${fileName}`
    return buildComposeRequestByService(
      snapshot.clips,
      fileName,
      outputPath,
      snapshot.durationSec,
      this.hideSpeed,
      this.hideGps,
      this.hideVin
    )
  }

  private async composeExportSourceUri(
    snapshot: TripSnapshot | undefined,
    fileName: string,
    onProgress: (percent: number) => void
  ): Promise<string> {
    if (!snapshot) {
      throw new Error('缺少行程数据')
    }
    const request = this.buildComposeRequest(snapshot, fileName)
    if (request.frontUris.length === 0 || request.backUris.length === 0) {
      throw new Error(`方案A需要前后双轨输入，Front=${request.frontUris.length} Back=${request.backUris.length}`)
    }
    try {
      const cacheDir = this.lastContext?.cacheDir ?? '/data/storage/el2/base/cache'
      const composedUri = await executeFfmpegComposeByService(
        request,
        cacheDir,
        (message: string) => {
          debugLog('导出', message)
        },
        onProgress
      )
      if (composedUri.length === 0) {
        throw new Error('FFmpeg返回空输出')
      }
      if (composedUri.startsWith('__ERROR__:')) {
        throw new Error(`FFmpeg执行失败：${composedUri}`)
      }
      if (request.frontUris.includes(composedUri) || request.backUris.includes(composedUri)) {
        throw new Error('FFmpeg返回输入源文件，尚未生成合成输出')
      }
      const stat = await fs.stat(composedUri)
      debugLog('导出', `FFmpeg合成完成，版本=${EXPORT_PIPELINE_VERSION}，输出URI=${composedUri}，大小=${stat.size}`)
      return composedUri
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      throw new Error(`方案A导出失败：${message}`)
    }
  }

  private async saveVideoToAlbum(fileName: string, sourceUri: string): Promise<string> {
    if (!this.lastContext) {
      throw new Error('缺少页面上下文')
    }
    const helper = photoAccessHelper.getPhotoAccessHelper(this.lastContext)
    const srcFileUris: Array<string> = [sourceUri]
    const dotIndex = fileName.lastIndexOf('.')
    const title = dotIndex > 0 ? fileName.slice(0, dotIndex) : fileName
    const photoCreationConfigs: Array<photoAccessHelper.PhotoCreationConfig> = [{
      title: title,
      fileNameExtension: 'mp4',
      photoType: photoAccessHelper.PhotoType.VIDEO,
      subtype: photoAccessHelper.PhotoSubtype.DEFAULT
    }]
    let desFileUris: Array<string>
    try {
      desFileUris = await helper.showAssetsCreationDialog(srcFileUris, photoCreationConfigs)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      throw new Error(`打开相册保存面板失败：${message}`)
    }
    const albumUri = desFileUris[0]
    if (!albumUri || albumUri.length === 0) {
      throw new Error('未选择相册保存位置')
    }
    let sourceStat: fs.Stat
    try {
      sourceStat = await fs.stat(sourceUri)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      throw new Error(`读取源文件信息失败：${message}`)
    }
    let srcFd: number = -1
    let dstFd: number = -1
    const chunkSize: number = 1024 * 1024
    let written: number = 0
    try {
      const src = await fs.open(sourceUri, fs.OpenMode.READ_ONLY)
      srcFd = src.fd
      const dst = await fs.open(albumUri, fs.OpenMode.READ_WRITE)
      dstFd = dst.fd
      while (true) {
        const buffer = new ArrayBuffer(chunkSize)
        const readLen = await fs.read(srcFd, buffer)
        if (readLen <= 0) {
          break
        }
        const payload = buffer.slice(0, readLen)
        const writeLen = await fs.write(dstFd, payload)
        written += writeLen
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      throw new Error(`写入相册文件失败：${message}`)
    } finally {
      if (srcFd >= 0) {
        try {
          await fs.close(srcFd)
        } catch (_) {
        }
      }
      if (dstFd >= 0) {
        try {
          await fs.close(dstFd)
        } catch (_) {
        }
      }
    }
    let targetStat: fs.Stat
    try {
      targetStat = await fs.stat(albumUri)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      throw new Error(`读取目标文件信息失败：${message}`)
    }
    debugLog('导出', `写入相册完成，版本=${EXPORT_PIPELINE_VERSION}，源大小=${sourceStat.size}，目标大小=${targetStat.size}`)
    debugLog('导出', `写入字节统计=${written}，源URI长度=${sourceUri.length}，目标URI长度=${albumUri.length}`)
    return albumUri
  }

  startExport(): string {
    const snapshot = this.trips.get(this.tripId)
    if (!snapshot) {
      this.exportStatusText = '导出失败：缺少行程数据'
      return this.exportStatusText
    }
    if (this.exporting) {
      return this.exportStatusText
    }
    const exportCameras: Array<string> = ['Front', 'Back']
    const details: Array<string> = []
    exportCameras.forEach((camera: string) => {
      const clips = snapshot.clips
        .filter((item: DvrMeta) => item.camera === camera)
        .sort((a: DvrMeta, b: DvrMeta) => a.timestamp - b.timestamp)
      details.push(`${camera}:${clips.length}`)
    })
    debugLog('导出', `策略=前后分轨时间拼接后上下合成，版本=${EXPORT_PIPELINE_VERSION}，明细=${details.join(',')}`)
    const fileName = this.buildExportFileName()
    this.exportStatusText = `导出处理中 0%（${fileName}）`
    this.startExportPipeline(fileName)
    return this.exportStatusText
  }
}

export const sharedCoreBridge: CoreBridge = new CoreBridge()
