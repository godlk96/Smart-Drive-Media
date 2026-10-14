import {
  EditorLayerModel,
  EditorStateModel,
  LibraryStateModel,
  PreviewSlotModel,
  TemplateCardModel,
  TimelineMarkerModel,
  TimelineTrackModel,
  TripCardModel
} from '../model/AppState'
import {
  DEFAULT_TEMPLATE_ID,
  listTemplateDefinitions,
  normalizeTemplateIdValue,
  resolveTemplateDefinition,
  toLegacyCamera
} from '../model/Models'
import { DvrMeta, TripSnapshot } from '../model/TripModels'
import { parseDvrFileName, pickPreviewSource } from '../service/DvrScannerService'
import { buildTimeline, mergeTimeline } from '../service/TimelineService'
import { extractFirstFrameByService, isUsableThumbnail, resolveThumbnailCachePath } from '../service/ExportNativeService'
import { PreferencesService } from '../service/PreferencesService'
import { debugLog } from '../utils/Logger'
import { RUN_GAP_MS, SLICE_MS } from '../media/TimelineMath'
import {
  adjustSegmentEnd,
  adjustSegmentStart,
  canSplitAt,
  canSplitOrInsertAt,
  canToggleSegment,
  createFullSegment,
  cycleSpeedLabel,
  removeSegment,
  segmentIndexAtSec,
  setSegmentMuted,
  setSegmentSpeed,
  splitOrInsertAt,
  splitSegmentAt,
  toggleSegmentEnabled as toggleSegmentEnabledIn,
  Segment
} from '../model/SegmentModel'
import photoAccessHelper from '@ohos.file.photoAccessHelper'
import dataSharePredicates from '@ohos.data.dataSharePredicates'
import common from '@ohos.app.ability.common'

const HUAWEI_SHARE_ALBUM_NAMES: Array<string> = ['华为分享', 'Huawei Share']
// 切片时长与"行程分组阈值"都必须与预览时间轴（TimelineMath）**同源**：
//   - CLIP_DURATION_SEC 决定行程时长 = 切片数 × 该值；
//   - TRIP_GAP_THRESHOLD_MS 决定"多远算断开"，而 TimelineMath 用同一个阈值把切片
//     切成"连续录制段"再拼接。两者一旦不一致，合并行程的时间轴就会错位。
const CLIP_DURATION_SEC: number = SLICE_MS / 1000
const TRIP_GAP_THRESHOLD_MS: number = RUN_GAP_MS
const DVR_FILE_PATTERN: RegExp = /^(?:.+_)?DVR_LoopRecording_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_.+_camera\.(mp4|mov|ts)$/i
const SENTRY_FILE_PATTERN: RegExp = /^(?:.+_)?Sentry_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_[a-z]+\.(mp4|mov|ts)$/i
const VIDEO_FILE_URI_PATTERN: RegExp = /^((file|datashare):\/\/.+|\/data\/storage\/.+)\.(mp4|mov|ts)(\?.*)?$/i

function createDvrFetchOptions(): photoAccessHelper.FetchOptions {
  const predicates = new dataSharePredicates.DataSharePredicates()
  predicates.equalTo(photoAccessHelper.PhotoKeys.PHOTO_TYPE, photoAccessHelper.PhotoType.VIDEO)
  predicates.orderByDesc(photoAccessHelper.PhotoKeys.DATE_ADDED)
  return {
    fetchColumns: [photoAccessHelper.PhotoKeys.DISPLAY_NAME, photoAccessHelper.PhotoKeys.DATE_ADDED],
    predicates: predicates
  }
}

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

function isDvrCandidateName(name: string): boolean {
  return DVR_FILE_PATTERN.test(name) || SENTRY_FILE_PATTERN.test(name)
}

function canExtractPreviewFrame(uri: string): boolean {
  if (!uri || uri.length === 0) {
    return false
  }
  const lower = uri.toLowerCase()
  return VIDEO_FILE_URI_PATTERN.test(uri) ||
    lower.includes('/photo/') ||
    lower.endsWith('.mp4') ||
    lower.endsWith('.mov') ||
    lower.endsWith('.ts')
}

function resolvePreviewTrack(track: string, availableTracks: Array<string>): string {
  let preferred: Array<string>
  if (track === 'Front') {
    preferred = ['Front', 'LeftFront', 'RightFront', 'Left', 'Right']
  } else if (track === 'Back') {
    preferred = ['Back', 'Front', 'Right', 'Left', 'LeftFront', 'RightFront']
  } else if (track === 'Left') {
    preferred = ['Left', 'LeftFront', 'Front', 'Right', 'RightFront']
  } else if (track === 'Right') {
    preferred = ['Right', 'RightFront', 'Front', 'Left', 'LeftFront']
  } else if (track === 'LeftFront') {
    preferred = ['LeftFront', 'Front', 'Left', 'RightFront', 'Right']
  } else if (track === 'RightFront') {
    preferred = ['RightFront', 'Front', 'Right', 'LeftFront', 'Left']
  } else {
    preferred = [track]
  }
  for (const candidate of preferred) {
    if (availableTracks.some((item: string) => item === candidate)) {
      return candidate
    }
  }
  if (track !== 'Back') {
    for (const candidate of availableTracks) {
      if (candidate !== 'Back') {
        return candidate
      }
    }
    return track
  }
  return availableTracks[0] ?? track
}

export interface SlotUriResult {
  current: string;
  next: string;
}

export class CoreBridge {
  private readonly requiredPermissions: Array<string> = ['ohos.permission.READ_MEDIA', 'ohos.permission.READ_IMAGEVIDEO', 'ohos.permission.WRITE_MEDIA']
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
  private playheadMs: number = 0
  private segments: Array<Segment> = []
  private selectedSegmentId: number = 0
  private isRawFull: boolean = true
  /** 段列表是按哪个时长建立的；与当前行程时长不一致时重建（换行程 = 丢弃上一次的编辑）。 */
  private segmentSourceDurationSec: number = -1
  private activeTemplateId: string = DEFAULT_TEMPLATE_ID
  private drawerExpanded: boolean = true
  private watermarkEnabled: boolean = true
  private exportStatusText: string = '待导出'
  private lastContext?: common.UIAbilityContext = undefined
  private previewFrameCache: Map<string, string> = new Map()
  private previewResolutionToken: number = 0
  private onCoverReadyListener?: (tripId: string, coverPath: string) => void

  setOnCoverReadyListener(listener?: (tripId: string, coverPath: string) => void): void {
    this.onCoverReadyListener = listener
  }

  getRequiredPermissions(): Array<string> {
    return [...this.requiredPermissions]
  }

  private async collectDvrMetas(fetchResult: photoAccessHelper.FetchResult<photoAccessHelper.PhotoAsset>): Promise<Array<DvrMeta>> {
    let assets: Array<photoAccessHelper.PhotoAsset> = []
    try {
      assets = await fetchResult.getAllObjects()
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('扫描', `读取资源列表失败，原因=${message}`)
      return []
    } finally {
      try {
        fetchResult.close()
      } catch (_) {
      }
    }

    const metas: Array<DvrMeta> = []
    for (let i = 0; i < assets.length; i++) {
      const asset = assets[i]
      const name = String(asset?.displayName ?? '')
      const uri = String(asset?.uri ?? '')
      if (name.length === 0 || uri.length === 0) {
        continue
      }
      if (!isDvrCandidateName(name)) {
        continue
      }
      const parsed = parseDvrFileName(name, uri)
      if (parsed !== null) {
        metas.push(parsed)
      }
    }
    return metas
  }

  private async fallbackScanAllAssets(helper: photoAccessHelper.PhotoAccessHelper): Promise<Array<DvrMeta>> {
    const fallbackFetchOptions = createDvrFetchOptions()
    let fallbackList: photoAccessHelper.FetchResult<photoAccessHelper.PhotoAsset>
    try {
      fallbackList = await helper.getAssets(fallbackFetchOptions)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      throw new Error(`降级扫描获取资产失败：${message}`)
    }
    const fallbackMetas = await this.collectDvrMetas(fallbackList)
    debugLog('扫描', `全图库精准扫描完成，匹配DVR视频=${fallbackMetas.length}`)
    return fallbackMetas
  }

  private async readHuaweiShareDvrFiles(context: common.UIAbilityContext): Promise<Array<DvrMeta>> {
    const helper = photoAccessHelper.getPhotoAccessHelper(context)
    let album: photoAccessHelper.Album | undefined = undefined
    let albumLookupFailed: boolean = false
    for (let i = 0; i < HUAWEI_SHARE_ALBUM_NAMES.length; i++) {
      let albumList: photoAccessHelper.FetchResult<photoAccessHelper.Album> | undefined = undefined
      try {
        const albumPredicates = new dataSharePredicates.DataSharePredicates()
        albumPredicates.equalTo('album_name', HUAWEI_SHARE_ALBUM_NAMES[i])
        const albumFetchOptions: photoAccessHelper.FetchOptions = {
          fetchColumns: [],
          predicates: albumPredicates
        }
        albumList = await helper.getAlbums(photoAccessHelper.AlbumType.USER, photoAccessHelper.AlbumSubtype.USER_GENERIC, albumFetchOptions)
        const found = await albumList.getFirstObject()
        if (found) {
          album = found
          break
        }
      } catch (error) {
        albumLookupFailed = true
        const message = error instanceof Error ? error.message : String(error)
        debugLog('扫描', `查询华为分享专辑失败，名称=${HUAWEI_SHARE_ALBUM_NAMES[i]}，原因=${message}`)
      } finally {
        if (albumList) {
          try {
            albumList.close()
          } catch (_) {
          }
        }
      }
    }
    if (!album) {
      if (albumLookupFailed) {
        debugLog('扫描', '查询专辑失败，降级全图库精准过滤扫描')
      } else {
        debugLog('扫描', '未找到“华为分享/Huawei Share”相册，使用全图库精准过滤扫描')
      }
      return this.fallbackScanAllAssets(helper)
    }
    try {
      const assetFetchOptions = createDvrFetchOptions()
      const assetList = await album.getAssets(assetFetchOptions)
      const metas = await this.collectDvrMetas(assetList)
      debugLog('扫描', `华为分享匹配DVR视频=${metas.length}`)
      if (metas.length > 0) {
        return metas
      }
      debugLog('扫描', '华为分享相册未匹配到DVR视频，回退全图库精准扫描')
      return this.fallbackScanAllAssets(helper)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('扫描', `读取华为分享专辑失败，降级全量扫描，原因=${message}`)
      return this.fallbackScanAllAssets(helper)
    }
  }

  private async resolveCachedPreviewFrames(trips: Array<TripSnapshot>, cacheDir: string): Promise<void> {
    for (let i = 0; i < trips.length; i++) {
      const trip = trips[i]
      if (trip.previewUri.length === 0) {
        trip.previewFrameUri = ''
        continue
      }
      const cached = this.previewFrameCache.get(trip.previewUri)
      if (cached && cached.length > 0) {
        trip.previewFrameUri = cached
        continue
      }
      const cacheKey = `${trip.id}_${trip.startTs}`
      const targetImagePath = resolveThumbnailCachePath(cacheDir, cacheKey)
      if (await isUsableThumbnail(targetImagePath)) {
        this.previewFrameCache.set(trip.previewUri, targetImagePath)
        trip.previewFrameUri = targetImagePath
        continue
      }
      trip.previewFrameUri = ''
    }
  }

  private async resolvePendingTripPreviewFrames(
    trips: Array<TripSnapshot>,
    cacheDir: string,
    generationToken: number
  ): Promise<void> {
    // 逆序遍历：因为 displayCards 是反转显示的，最新的行程在列表最顶端，优先为靠前行程提取封面！
    for (let i = trips.length - 1; i >= 0; i--) {
      if (this.previewResolutionToken !== generationToken) {
        debugLog('扫描', `取消旧的封面提取任务，token=${generationToken}`)
        return
      }
      const trip = trips[i]
      if (trip.previewFrameUri.length > 0 || trip.previewUri.length === 0) {
        continue
      }
      if (!canExtractPreviewFrame(trip.previewUri)) {
        continue
      }
      const cacheKey = `${trip.id}_${trip.startTs}`
      try {
        const framePath = await extractFirstFrameByService(trip.previewUri, cacheDir, cacheKey)
        if (this.previewResolutionToken !== generationToken) {
          return
        }
        if (framePath.length > 0) {
          trip.previewFrameUri = framePath
          this.previewFrameCache.set(trip.previewUri, framePath)
          this.updateCardCover(trip.id, framePath)
          debugLog('扫描', `异步封面提取成功，行程=${trip.id}，封面=${framePath}`)
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        debugLog('扫描', `异步提取封面异常，行程=${trip.id}，原因=${message}`)
      }
    }
  }

  private updateCardCover(tripId: string, coverPath: string): void {
    const card = this.cards.find((c: TripCardModel) => c.id === tripId)
    if (card) {
      card.previewFrameUri = coverPath
    }
    const trip = this.trips.get(tripId)
    if (trip) {
      trip.previewFrameUri = coverPath
    }
    if (this.onCoverReadyListener) {
      this.onCoverReadyListener(tripId, coverPath)
    }
  }


  private getTemplateSlotDefs(templateId: string): Array<PreviewSlotModel> {
    const definition = resolveTemplateDefinition(templateId)
    const slotCameraMap: Record<string, string> = {}
    definition.slotBindings.forEach((binding) => {
      slotCameraMap[binding.slotId] = toLegacyCamera(binding.camera)
    })
    return definition.previewSlots.map((slot) => {
      const previewSlot: PreviewSlotModel = {
        id: slot.slotId,
        camera: slotCameraMap[slot.slotId] ?? 'Front',
        uri: '',
        x: slot.x,
        y: slot.y,
        width: slot.width,
        height: slot.height
      }
      return previewSlot
    })
  }

  private resolveAnchorCamera(snapshot: TripSnapshot, preferredCamera?: string): string {
    const availableTracks = snapshot.timeline.map((item: TimelineTrackModel) => item.cameraPosition)
    const templatePrimaryCamera = this.getTemplateSlotDefs(this.activeTemplateId)[0]?.camera ?? ''
    if (preferredCamera && availableTracks.some((item: string) => item === preferredCamera)) {
      return preferredCamera
    }
    if (templatePrimaryCamera.length > 0) {
      return resolvePreviewTrack(templatePrimaryCamera, availableTracks)
    }
    if (snapshot.previewCamera.length > 0) {
      return resolvePreviewTrack(snapshot.previewCamera, availableTracks)
    }
    return availableTracks[0] ?? 'Front'
  }

  private pickSlotUri(snapshot: TripSnapshot, camera: string, anchorTimestamp: number): SlotUriResult {
    const clips = snapshot.clips
      .filter((item: DvrMeta) => item.camera === camera && item.uri.length > 0)
      .sort((a: DvrMeta, b: DvrMeta) => a.timestamp - b.timestamp)
    if (clips.length === 0) {
      return { current: '', next: '' } as SlotUriResult
    }
    if (anchorTimestamp <= 0) {
      return { current: clips[0].uri, next: clips.length > 1 ? clips[1].uri : '' } as SlotUriResult
    }
    let nearest = clips[0]
    let nearestIndex = 0
    let nearestDelta = Math.abs(nearest.timestamp - anchorTimestamp)
    clips.forEach((clip: DvrMeta, index: number) => {
      const delta = Math.abs(clip.timestamp - anchorTimestamp)
      if (delta < nearestDelta) {
        nearest = clip
        nearestDelta = delta
        nearestIndex = index
      }
    })
    const nextUri = nearestIndex + 1 < clips.length ? clips[nearestIndex + 1].uri : ''
    return { current: nearest.uri, next: nextUri } as SlotUriResult
  }

  private buildPreviewSlots(snapshot: TripSnapshot, anchorTimestamp: number): Array<PreviewSlotModel> {
    const defs = this.getTemplateSlotDefs(this.activeTemplateId)
    const availableTracks = snapshot.timeline.map((item: TimelineTrackModel) => item.cameraPosition)
    const result: Array<PreviewSlotModel> = []
    for (const slot of defs) {
      const resolvedCamera = resolvePreviewTrack(slot.camera, availableTracks)
      const uris = this.pickSlotUri(snapshot, resolvedCamera, anchorTimestamp)
      const previewSlot: PreviewSlotModel = {
        id: slot.id,
        camera: resolvedCamera,
        uri: uris.current,
        nextUri: uris.next,
        x: slot.x,
        y: slot.y,
        width: slot.width,
        height: slot.height
      }
      result.push(previewSlot)
    }
    return result
  }

  private buildTripsFromMetas(metas: Array<DvrMeta>): Array<TripSnapshot> {
    if (metas.length === 0) {
      return []
    }
    metas.sort((a: DvrMeta, b: DvrMeta) => a.timestamp - b.timestamp)
    const slicesMap: Map<number, Array<DvrMeta>> = new Map()
    metas.forEach((item: DvrMeta) => {
      const list = slicesMap.get(item.timestamp) ?? []
      list.push(item)
      slicesMap.set(item.timestamp, list)
    })
    const sortedTimestamps = Array.from(slicesMap.keys()).sort((a: number, b: number) => a - b)

    const tripSliceGroups: Array<Array<Array<DvrMeta>>> = []
    let currentGroup: Array<Array<DvrMeta>> = []
    let lastSliceEndTs: number = -1

    sortedTimestamps.forEach((ts: number) => {
      const slice = slicesMap.get(ts) ?? []
      const sliceEndTs = ts + CLIP_DURATION_SEC * 1000
      if (currentGroup.length === 0) {
        currentGroup.push(slice)
        lastSliceEndTs = sliceEndTs
      } else {
        if (ts - lastSliceEndTs <= TRIP_GAP_THRESHOLD_MS) {
          currentGroup.push(slice)
          lastSliceEndTs = sliceEndTs
        } else {
          tripSliceGroups.push(currentGroup)
          currentGroup = [slice]
          lastSliceEndTs = sliceEndTs
        }
      }
    })
    if (currentGroup.length > 0) {
      tripSliceGroups.push(currentGroup)
    }

    const trips: Array<TripSnapshot> = []
    tripSliceGroups.forEach((sliceGroup: Array<Array<DvrMeta>>, index: number) => {
      const allClips: Array<DvrMeta> = []
      sliceGroup.forEach((slice: Array<DvrMeta>) => {
        slice.forEach((item: DvrMeta) => {
          allClips.push(item)
        })
      })
      const firstSlice = sliceGroup[0]
      const lastSlice = sliceGroup[sliceGroup.length - 1]
      const startTs = firstSlice[0].timestamp
      const endTs = lastSlice[0].timestamp + CLIP_DURATION_SEC * 1000
      const durationSec = Math.max(CLIP_DURATION_SEC, Math.round((endTs - startTs) / 1000))
      const startDate = new Date(startTs)
      const endDate = new Date(endTs)
      const title = firstSlice[0].date
      const startText = toTimeText(startDate)
      const endText = toTimeText(endDate)
      const cameraSet = new Set(allClips.map((item: DvrMeta) => item.camera))
      const preview = pickPreviewSource(allClips)

      const trip = new TripSnapshot()
      trip.id = `trip-${title}-${startText.replace(/:/g, '')}-${index}`
      trip.title = title
      trip.subtitle = `${startText} - ${endText} · ${cameraSet.size} 视角`
      trip.durationSec = durationSec
      trip.tripTitle = `${title.replace(/-/g, '/')} 夜间行车`
      trip.tripRange = `${startText} - ${endText}`
      trip.previewUri = preview.uri
      trip.previewFrameUri = preview.frameUri
      trip.previewCamera = preview.camera
      trip.clips = allClips
      trip.timeline = buildTimeline(allClips)
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
    merged.durationSec = selected.reduce((acc: number, item: TripSnapshot) => acc + item.durationSec, 0)
    merged.tripTitle = `${title.replace(/-/g, '/')} 合并行程`
    merged.tripRange = `${toTimeText(startDate)} - ${toTimeText(endDate)}`
    merged.previewUri = preview?.previewUri ?? ''
    merged.previewFrameUri = preview?.previewFrameUri ?? ''
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
    PreferencesService.getInstance().setContext(context ?? null)
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
      const cacheDir = context.cacheDir ?? '/data/storage/el2/base/cache'
      await this.resolveCachedPreviewFrames(tripSnapshots, cacheDir)
      const currentToken = ++this.previewResolutionToken
      if (tripSnapshots.length > 0) {
        const newestTrip = tripSnapshots[tripSnapshots.length - 1]
        if (newestTrip.previewFrameUri.length === 0 && newestTrip.previewUri.length > 0 && canExtractPreviewFrame(newestTrip.previewUri)) {
          const cacheKey = `${newestTrip.id}_${newestTrip.startTs}`
          try {
            const framePath = await extractFirstFrameByService(newestTrip.previewUri, cacheDir, cacheKey)
            if (framePath.length > 0) {
              newestTrip.previewFrameUri = framePath
              this.previewFrameCache.set(newestTrip.previewUri, framePath)
            }
          } catch (error) {
            const message = error instanceof Error ? error.message : String(error)
            debugLog('扫描', `首屏最新行程提取封面异常：${message}`)
          }
        }
      }
      this.trips.clear()
      this.cards = tripSnapshots.map((item: TripSnapshot) => {
        this.trips.set(item.id, item)
        const card: TripCardModel = {
          id: item.id,
          title: item.title,
          subtitle: item.subtitle,
          durationText: `${item.durationSec}s`,
          durationSec: item.durationSec,
          previewUri: item.previewUri,
          previewFrameUri: item.previewFrameUri,
          previewCamera: item.previewCamera
        }
        debugLog('扫描', `首页卡片，行程=${card.id}，封面长度=${card.previewFrameUri.length}，预览URI长度=${card.previewUri.length}`)
        return card
      })
      void this.resolvePendingTripPreviewFrames(tripSnapshots, cacheDir, currentToken)
      if (tripSnapshots.length > 0) {
        const tripSummary = tripSnapshots.map((item: TripSnapshot) => `${item.id}:${item.subtitle}`).join(' | ')
        debugLog('扫描', `分组明细=${tripSummary}`)
        const first = tripSnapshots[0]
        const lastTripId = await PreferencesService.getInstance().getLastTripId()
        const preferred = (lastTripId.length > 0 && this.trips.get(lastTripId)) ? this.trips.get(lastTripId)! : first
        this.tripId = preferred.id
        this.tripTitle = preferred.tripTitle
        this.tripRange = preferred.tripRange
        this.tripDurationSec = preferred.durationSec
        this.tripTimeline = preferred.timeline

        const savedTemplate = await PreferencesService.getInstance().getTemplatePreference(DEFAULT_TEMPLATE_ID)
        if (savedTemplate) {
          this.activeTemplateId = normalizeTemplateIdValue(savedTemplate)
        }
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

    const templateCards: Array<TemplateCardModel> = listTemplateDefinitions().map((item) => {
      const card: TemplateCardModel = { id: item.templateId, title: item.title, subtitle: item.subtitle }
      return card
    })
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
    let anchorTimestamp: number = 0
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
      let camera = this.resolveAnchorCamera(activeSnapshot, preferredCamera)
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
        anchorTimestamp = anyClip?.timestamp ?? anchorTimestamp
        this.currentClipIndex = 0
        this.currentClipTotal = anyClip ? 1 : 0
      } else {
        index = Math.max(0, Math.min(index, cameraClips.length - 1))
        const selectedClip = cameraClips[index]
        this.previewUri = selectedClip.uri
        anchorTimestamp = selectedClip.timestamp
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
    if (this.segmentSourceDurationSec !== this.tripDurationSec) {
      this.isRawFull = true
      this.segments = createFullSegment(this.tripDurationSec)
      this.selectedSegmentId = 0
      this.segmentSourceDurationSec = this.tripDurationSec
    }
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
    const templateCards: Array<TemplateCardModel> = listTemplateDefinitions().map((item) => {
      const card: TemplateCardModel = { id: item.templateId, title: item.title, subtitle: item.subtitle }
      return card
    })
    const previewSlots = activeSnapshot ? this.buildPreviewSlots(activeSnapshot, anchorTimestamp) : []
    return {
      tripId: this.tripId,
      tripTitle: this.tripTitle,
      timeRange: this.tripRange,
      previewUri: this.previewUri,
      previewCamera: this.previewCamera,
      playheadSec: this.playheadMs / 1000,
      canPlayPrev: this.currentClipTotal > 0 && this.currentClipIndex > 0,
      canPlayNext: this.currentClipTotal > 0 && this.currentClipIndex < this.currentClipTotal - 1,
      currentClipIndex: this.currentClipTotal === 0 ? 0 : this.currentClipIndex + 1,
      currentClipTotal: this.currentClipTotal,
      playheadText: `${secondsToClock(Math.floor(this.playheadMs / 1000))} / ${secondsToClock(this.tripDurationSec)}`,
      totalDurationSec: this.tripDurationSec,
      timeline: this.tripTimeline,
      layers: layers,
      boundaryMarkers: markers,
      templateCards: templateCards,
      previewSlots: previewSlots,
      activeTemplateId: this.activeTemplateId,
      drawerExpanded: this.drawerExpanded,
      segments: this.segments,
      selectedSegmentId: this.selectedSegmentId,
      watermarkEnabled: this.watermarkEnabled,
      exportStatusText: this.exportStatusText,
      isRawFull: this.isRawFull
    }
  }

  createEditorState(tripId: string, titleHint: string, subtitleHint: string): EditorStateModel {
    debugLog('剪辑', `加载行程详情，行程ID=${tripId}`)
    const selected = this.trips.get(tripId)
    this.playheadMs = 0
    this.activeTemplateId = DEFAULT_TEMPLATE_ID
    this.drawerExpanded = true
    this.segmentSourceDurationSec = -1
    this.isRawFull = true
    this.watermarkEnabled = true
    this.exportStatusText = '待导出'
    if (selected) {
      PreferencesService.getInstance().saveLastTripId(selected.id)
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

  seekGlobalPlayhead(second: number): EditorStateModel {
    const clamped = Math.max(0, Math.min(Math.floor(second), this.tripDurationSec))
    this.playheadMs = clamped * 1000
    if (!this.isRawFull) {
      const at = segmentIndexAtSec(this.segments, clamped)
      this.selectedSegmentId = at >= 0 ? this.segments[at].id : -1
    } else {
      this.selectedSegmentId = 0
    }
    const snapshot = this.trips.get(this.tripId)
    if (!snapshot || this.currentClipTotal <= 0) {
      return this.buildEditorState(snapshot, this.previewCamera, this.currentClipIndex)
    }
    const clipSpanSec = Math.max(1, Math.floor(this.tripDurationSec / this.currentClipTotal))
    const targetIndex = Math.max(0, Math.min(Math.floor(clamped / clipSpanSec), this.currentClipTotal - 1))
    return this.buildEditorState(snapshot, this.previewCamera, targetIndex)
  }

  selectTemplate(templateId: string): EditorStateModel {
    this.activeTemplateId = normalizeTemplateIdValue(templateId)
    PreferencesService.getInstance().saveTemplatePreference(this.activeTemplateId)
    debugLog('剪辑', `选择模板，模板ID=${this.activeTemplateId}`)
    const snapshot = this.trips.get(this.tripId)
    return this.buildEditorState(snapshot, this.previewCamera, this.currentClipIndex)
  }

  toggleTemplateDrawer(expanded: boolean): EditorStateModel {
    this.drawerExpanded = expanded
    const snapshot = this.trips.get(this.tripId)
    return this.buildEditorState(snapshot, this.previewCamera, this.currentClipIndex)
  }

  /** 循环【选中段】的倍速（plan:757）；全局 speedIndex 这条路径已删除。 */
  cycleSpeed(): EditorStateModel {
    const target = this.segmentById(this.selectedSegmentId)
    if (target) {
      this.segments = setSegmentSpeed(this.segments, target.id, cycleSpeedLabel(target.speedLabel))
    }
    const snapshot = this.trips.get(this.tripId)
    return this.buildEditorState(snapshot, this.previewCamera, this.currentClipIndex)
  }

  /** 翻转【选中段】的声音开关。 */
  toggleMuted(): EditorStateModel {
    const target = this.segmentById(this.selectedSegmentId)
    if (target) {
      this.segments = setSegmentMuted(this.segments, target.id, !target.muted)
    }
    const snapshot = this.trips.get(this.tripId)
    return this.buildEditorState(snapshot, this.previewCamera, this.currentClipIndex)
  }

  setMuted(muted: boolean): EditorStateModel {
    const target = this.segmentById(this.selectedSegmentId)
    if (target) {
      this.segments = setSegmentMuted(this.segments, target.id, muted)
    }
    const snapshot = this.trips.get(this.tripId)
    return this.buildEditorState(snapshot, this.previewCamera, this.currentClipIndex)
  }

  /** 在播放头处落刀；切出新段后选中播放头所在的那一段（切分后优先选中从当前落刀点开始的后半段）。 */
  splitAtPlayhead(): EditorStateModel {
    const sec = this.playheadMs / 1000
    if (!canSplitOrInsertAt(this.segments, sec, this.tripDurationSec, this.isRawFull)) {
      const snapshot = this.trips.get(this.tripId)
      return this.buildEditorState(snapshot, this.previewCamera, this.currentClipIndex)
    }
    if (this.isRawFull) {
      const next = splitOrInsertAt(this.segments, sec, this.tripDurationSec, true)
      this.segments = next
      this.isRawFull = false
      this.selectedSegmentId = next.length > 0 ? next[0].id : 0
    } else {
      const next = splitOrInsertAt(this.segments, sec, this.tripDurationSec, false)
      if (next.length !== this.segments.length) {
        this.segments = next
        // 切分后优先选中从当前落刀点开始的后半段（符合剪辑操作直觉：落刀后调整后续内容）
        let targetSegment: Segment | undefined = undefined
        for (let i = 0; i < this.segments.length; i++) {
          if (Math.abs(this.segments[i].startSec - sec) < 1e-4) {
            targetSegment = this.segments[i]
            break
          }
        }
        if (targetSegment !== undefined) {
          this.selectedSegmentId = targetSegment.id
        } else {
          const at = segmentIndexAtSec(this.segments, sec)
          if (at >= 0) {
            this.selectedSegmentId = this.segments[at].id
          }
        }
      }
    }
    const snapshot = this.trips.get(this.tripId)
    return this.buildEditorState(snapshot, this.previewCamera, this.currentClipIndex)
  }

  /** 剪刀置灰判据（纯读）。 */
  canSplitAtPlayhead(): boolean {
    return canSplitOrInsertAt(this.segments, this.playheadMs / 1000, this.tripDurationSec, this.isRawFull)
  }

  deleteSegment(id: number): EditorStateModel {
    this.segments = removeSegment(this.segments, id)
    if (this.segments.length === 0) {
      this.segments = createFullSegment(this.tripDurationSec)
      this.isRawFull = true
      if (this.segments.length > 0) {
        this.segments[0].speedLabel = '1.0X'
        this.segments[0].muted = false
      }
      this.selectedSegmentId = 0
    } else {
      const sec = this.playheadMs / 1000
      const atIndex = segmentIndexAtSec(this.segments, sec)
      if (atIndex >= 0) {
        this.selectedSegmentId = this.segments[atIndex].id
      } else {
        this.selectedSegmentId = -1
      }
    }
    const snapshot = this.trips.get(this.tripId)
    return this.buildEditorState(snapshot, this.previewCamera, this.currentClipIndex)
  }

  adjustSegmentBoundary(id: number, edge: 'start' | 'end', sec: number): EditorStateModel {
    if (edge === 'start') {
      this.segments = adjustSegmentStart(this.segments, id, sec, this.tripDurationSec)
    } else if (edge === 'end') {
      this.segments = adjustSegmentEnd(this.segments, id, sec, this.tripDurationSec)
    }
    const snapshot = this.trips.get(this.tripId)
    return this.buildEditorState(snapshot, this.previewCamera, this.currentClipIndex)
  }

  /** 灰段恢复 / 启用段置灰；关掉当前选中段时选中顺延到下一个启用段（plan:742）。 */
  toggleSegmentEnabled(id: number): EditorStateModel {
    if (canToggleSegment(this.segments, id)) {
      this.segments = toggleSegmentEnabledIn(this.segments, id)
      if (this.selectedSegmentId === id) {
        const next = this.nextEnabledSegmentId(id)
        if (next >= 0) {
          this.selectedSegmentId = next
        }
      }
    }
    const snapshot = this.trips.get(this.tripId)
    return this.buildEditorState(snapshot, this.previewCamera, this.currentClipIndex)
  }

  selectSegment(id: number): EditorStateModel {
    if (id === -1 || this.segmentById(id) !== undefined) {
      this.selectedSegmentId = id
    }
    const snapshot = this.trips.get(this.tripId)
    return this.buildEditorState(snapshot, this.previewCamera, this.currentClipIndex)
  }

  private segmentById(id: number): Segment | undefined {
    return this.segments.find((item: Segment) => item.id === id)
  }

  /** 下一个启用段的 id；没有则 -1（plan:742「没有则保持」）。 */
  private nextEnabledSegmentId(fromId: number): number {
    const at = this.segments.findIndex((item: Segment) => item.id === fromId)
    if (at < 0) {
      return -1
    }
    for (let i = at + 1; i < this.segments.length; i++) {
      if (this.segments[i].enabled) {
        return this.segments[i].id
      }
    }
    return -1
  }

  toggleWatermark(): EditorStateModel {
    this.watermarkEnabled = !this.watermarkEnabled
    const snapshot = this.trips.get(this.tripId)
    return this.buildEditorState(snapshot, this.previewCamera, this.currentClipIndex)
  }

  switchCamera(camera: string): EditorStateModel {
    debugLog('剪辑', `切换视角，目标=${camera}`)
    const snapshot = this.trips.get(this.tripId)
    return this.buildEditorState(snapshot, camera, 0)
  }

  getExportStatusText(): string {
    return this.exportStatusText
  }

  setExportStatusText(statusText: string): void {
    this.exportStatusText = statusText
  }

  private cloneTripSnapshot(snapshot: TripSnapshot): TripSnapshot {
    const cloned = new TripSnapshot()
    cloned.id = snapshot.id
    cloned.title = snapshot.title
    cloned.subtitle = snapshot.subtitle
    cloned.durationSec = snapshot.durationSec
    cloned.tripTitle = snapshot.tripTitle
    cloned.tripRange = snapshot.tripRange
    cloned.previewUri = snapshot.previewUri
    cloned.previewFrameUri = snapshot.previewFrameUri
    cloned.previewCamera = snapshot.previewCamera
    cloned.startTs = snapshot.startTs
    cloned.endTs = snapshot.endTs
    cloned.timeline = snapshot.timeline.slice()
    cloned.clips = snapshot.clips.map((item: DvrMeta) => {
      const clip = new DvrMeta()
      clip.fileName = item.fileName
      clip.uri = item.uri
      clip.date = item.date
      clip.time = item.time
      clip.camera = item.camera
      clip.timestamp = item.timestamp
      return clip
    })
    return cloned
  }

  getTripSnapshotClone(tripId?: string): TripSnapshot | undefined {
    const targetId = tripId && tripId.length > 0 ? tripId : this.tripId
    const snapshot = this.trips.get(targetId)
    if (!snapshot) {
      return undefined
    }
    return this.cloneTripSnapshot(snapshot)
  }

}

export const sharedCoreBridge: CoreBridge = new CoreBridge()
