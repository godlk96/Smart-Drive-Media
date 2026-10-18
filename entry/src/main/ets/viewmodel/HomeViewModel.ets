import common from '@ohos.app.ability.common'
import abilityAccessCtrl from '@ohos.abilityAccessCtrl'
import wantConstant from '@ohos.app.ability.wantConstant'
import fs from '@ohos.file.fs'
import { BusinessError } from '@ohos.base'
import { sharedCoreBridge } from '../bridge/CoreBridge'
import { PAGE_ROUTE_EDITOR, REQUIRED_MEDIA_PERMISSIONS } from '../constants/AppConstants'
import { LibraryStateModel, TripCardModel } from '../model/AppState'
import { EditRecord } from '../model/EditRecord'
import { EditHistoryService } from '../service/EditHistoryService'
import { extractFirstFrameByService } from '../service/ExportNativeService'
import { debugLog } from '../utils/Logger'

export interface HomeRouteRequest {
  url: string
  params: HomeRouteParams
}

export interface HomeRouteParams {
  tripId: string
  /** 从「我的剪辑」进入时带上，剪辑页据此还原那次导出的参数 */
  recordId?: string
}

export interface HomeViewState {
  permissionGranted: boolean
  hasAutoRequestedPermission: boolean
  selectionMode: boolean
  selectedTripIds: Array<string>
  libraryState: LibraryStateModel
  isLoading: boolean
}

function createEmptyHomeState(): HomeViewState {
  return {
    permissionGranted: false,
    hasAutoRequestedPermission: false,
    selectionMode: false,
    selectedTripIds: [],
    libraryState: {
      title: '行程库',
      cards: [],
      empty: true,
      emptyText: '',
      permissionTip: ''
    },
    isLoading: true
  }
}

export interface MyEditsViewState {
  records: Array<EditRecord>
  isLoading: boolean
  /** 非空表示这次读取失败，列表要显示提示而不是装成空历史 */
  errorText: string
  /** recordId -> 成片首帧缓存路径 */
  coverPaths: Record<string, string>
  /** 相册里那份成片确实打不开（已确认过权限） */
  orphanIds: Array<string>
  /** 没权限确认，成片在不在未知 —— 只降级展示，绝不判孤儿 */
  unknownIds: Array<string>
  selectionMode: boolean
  selectedRecordIds: Array<string>
}

function createEmptyMyEditsState(): MyEditsViewState {
  return {
    records: [],
    isLoading: true,
    errorText: '',
    coverPaths: {},
    orphanIds: [],
    unknownIds: [],
    selectionMode: false,
    selectedRecordIds: []
  }
}

function cloneEditRecord(record: EditRecord): EditRecord {
  const next = new EditRecord()
  next.id = record.id
  next.tripId = record.tripId
  next.tripTitle = record.tripTitle
  next.tripStartTs = record.tripStartTs
  next.tripEndTs = record.tripEndTs
  next.albumUri = record.albumUri
  next.fileName = record.fileName
  next.templateId = record.templateId
  next.segmentCount = record.segmentCount
  next.durationMs = record.durationMs
  next.exportedAt = record.exportedAt
  next.coverPath = record.coverPath
  next.schemaVersion = record.schemaVersion
  next.snapshot = record.snapshot
  return next
}

/** 缩略图补帧的并发上限 —— 相册取帧是重 IO，一次全开会在低端机上把列表拖住。 */
const COVER_EXTRACT_CONCURRENCY: number = 2

export class HomeViewModel {
  private state: HomeViewState = createEmptyHomeState()
  private bridge = sharedCoreBridge
  private isRefreshing: boolean = false
  private onStateChangedListener?: () => void
  private myEdits: MyEditsViewState = createEmptyMyEditsState()
  /** 每次 refreshMyEdits 自增；后台补帧发现 token 变了就自行退出，避免旧任务回写新列表 */
  private myEditsToken: number = 0
  private isRefreshingMyEdits: boolean = false

  constructor() {
    this.bridge.setOnCoverReadyListener((tripId: string, coverPath: string) => {
      this.handleCoverReady(tripId, coverPath)
    })
  }

  setOnStateChangedListener(listener?: () => void): void {
    this.onStateChangedListener = listener
  }

  private notifyStateChanged(): void {
    if (this.onStateChangedListener) {
      this.onStateChangedListener()
    }
  }

  private handleCoverReady(tripId: string, coverPath: string): void {
    let updated = false
    for (let i = 0; i < this.state.libraryState.cards.length; i++) {
      if (this.state.libraryState.cards[i].id === tripId) {
        this.state.libraryState.cards[i].previewFrameUri = coverPath
        updated = true
        break
      }
    }
    if (updated) {
      this.notifyStateChanged()
    }
  }

  private cloneTripCard(card: TripCardModel): TripCardModel {
    const next: TripCardModel = {
      id: card.id,
      title: card.title,
      subtitle: card.subtitle,
      durationText: card.durationText,
      durationSec: card.durationSec,
      previewUri: card.previewUri,
      previewFrameUri: card.previewFrameUri,
      previewCamera: card.previewCamera
    }
    return next
  }

  getState(): HomeViewState {
    return {
      permissionGranted: this.state.permissionGranted,
      hasAutoRequestedPermission: this.state.hasAutoRequestedPermission,
      selectionMode: this.state.selectionMode,
      selectedTripIds: [...this.state.selectedTripIds],
      libraryState: {
        title: this.state.libraryState.title,
        cards: this.state.libraryState.cards.map((card: TripCardModel) => this.cloneTripCard(card)),
        empty: this.state.libraryState.empty,
        emptyText: this.state.libraryState.emptyText,
        permissionTip: this.state.libraryState.permissionTip
      },
      isLoading: this.state.isLoading
    }
  }

  async refresh(context: common.UIAbilityContext): Promise<void> {
    if (this.isRefreshing) {
      debugLog('首页VM', '正在刷新中，跳过重复刷新')
      return
    }
    this.isRefreshing = true
    this.state.isLoading = true
    this.notifyStateChanged()
    try {
      debugLog('首页VM', `刷新列表，授权状态=${this.state.permissionGranted}`)
      const next = await this.bridge.createLibraryState(this.state.permissionGranted, context)
      this.state.libraryState = next
      this.state.selectedTripIds = this.state.selectedTripIds
        .filter((id: string) => next.cards.some((item: TripCardModel) => item.id === id))
    } finally {
      this.isRefreshing = false
      this.state.isLoading = false
      this.notifyStateChanged()
    }
  }

  toggleTripSelection(cardId: string): void {
    if (!this.state.selectionMode) {
      return
    }
    const existsInLibrary = this.state.libraryState.cards.some((item: TripCardModel) => item.id === cardId)
    if (!existsInLibrary) {
      return
    }
    const exists = this.state.selectedTripIds.some((id: string) => id === cardId)
    if (exists) {
      this.state.selectedTripIds = this.state.selectedTripIds.filter((id: string) => id !== cardId)
      return
    }
    this.state.selectedTripIds = [...this.state.selectedTripIds, cardId]
  }

  toggleSelectionMode(): void {
    if (this.state.selectionMode) {
      this.state.selectionMode = false
      this.state.selectedTripIds = []
      return
    }
    this.state.selectionMode = true
  }

  isTripSelected(cardId: string): boolean {
    return this.state.selectedTripIds.some((id: string) => id === cardId)
  }

  getDisplayCards(): Array<TripCardModel> {
    return [...this.state.libraryState.cards].reverse()
  }

  canShowMergeButton(): boolean {
    return this.state.selectionMode && this.state.selectedTripIds.length >= 2
  }


  openEditorRoute(card: TripCardModel): HomeRouteRequest {
    return {
      url: PAGE_ROUTE_EDITOR,
      params: {
        tripId: card.id
      }
    }
  }

  openMergedEditorRoute(): HomeRouteRequest | undefined {
    const mergedTripId = this.bridge.mergeTrips(this.state.selectedTripIds)
    if (mergedTripId.length === 0) {
      return undefined
    }
    return {
      url: PAGE_ROUTE_EDITOR,
      params: {
        tripId: mergedTripId
      }
    }
  }

  async requestMediaPermissionAndRefresh(context: common.UIAbilityContext, shouldGuideToSetting: boolean): Promise<void> {
    this.state.hasAutoRequestedPermission = true
    this.state.isLoading = true
    this.notifyStateChanged()
    const atManager = abilityAccessCtrl.createAtManager()
    try {
      const result = await atManager.requestPermissionsFromUser(context, REQUIRED_MEDIA_PERMISSIONS)
      const allGranted = result.authResults.every((item: number) => item === 0)
      if (allGranted) {
        this.state.permissionGranted = true
        this.state.isLoading = true
        this.notifyStateChanged()
        await this.refresh(context)
        return
      }
      if (!shouldGuideToSetting) {
        this.state.permissionGranted = false
        this.state.isLoading = false
        this.notifyStateChanged()
        await this.refresh(context)
        return
      }
      const settingResult = await atManager.requestPermissionOnSetting(context, REQUIRED_MEDIA_PERMISSIONS)
      this.state.permissionGranted = settingResult.every((item: number) => item === 0)
      this.state.isLoading = this.state.permissionGranted
      this.notifyStateChanged()
      await this.refresh(context)
    } catch (error) {
      this.state.permissionGranted = false
      this.state.isLoading = false
      this.notifyStateChanged()
      const message = error instanceof Error ? error.message : String(error)
      debugLog('首页VM', `权限链路失败：${message}`)
      await this.refresh(context)
    }
  }

  // ---------------- 我的剪辑 ----------------

  getMyEditsState(): MyEditsViewState {
    const coverPaths: Record<string, string> = {}
    const coverKeys = Object.keys(this.myEdits.coverPaths)
    for (let i = 0; i < coverKeys.length; i++) {
      const key = coverKeys[i]
      coverPaths[key] = this.myEdits.coverPaths[key]
    }
    return {
      records: this.myEdits.records.map((record: EditRecord) => cloneEditRecord(record)),
      isLoading: this.myEdits.isLoading,
      errorText: this.myEdits.errorText,
      coverPaths: coverPaths,
      orphanIds: [...this.myEdits.orphanIds],
      unknownIds: [...this.myEdits.unknownIds],
      selectionMode: this.myEdits.selectionMode,
      selectedRecordIds: [...this.myEdits.selectedRecordIds]
    }
  }

  /**
   * 读历史记录 -> 立刻通知界面（列表先出来）-> 后台补封面与孤儿标记。
   * 顺序很重要：取首帧是重 IO，不能让用户盯着转圈等封面。
   */
  async refreshMyEdits(context: common.UIAbilityContext): Promise<void> {
    if (this.isRefreshingMyEdits) {
      debugLog('首页VM', '我的剪辑正在刷新中，跳过重复刷新')
      return
    }
    this.isRefreshingMyEdits = true
    this.myEditsToken = this.myEditsToken + 1
    const token = this.myEditsToken
    this.myEdits.isLoading = true
    this.myEdits.errorText = ''
    this.notifyStateChanged()
    try {
      const service = EditHistoryService.getInstance()
      await service.setContext(context)
      let loaded: Array<EditRecord> = []
      try {
        loaded = await service.list()
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        debugLog('首页VM', `读取剪辑历史失败：${message}`)
        this.myEdits.records = []
        this.myEdits.errorText = '历史记录暂时不可用'
        return
      }
      if (token !== this.myEditsToken) {
        return
      }
      this.myEdits.records = loaded
      this.myEdits.selectedRecordIds = this.myEdits.selectedRecordIds
        .filter((id: string) => loaded.some((record: EditRecord) => record.id === id))
      this.myEdits.errorText = ''
      this.notifyStateChanged()
      void this.resolveMyEditsCovers(loaded, context.cacheDir, token)
      void this.resolveMyEditsOrphans(loaded, token)
    } finally {
      this.isRefreshingMyEdits = false
      this.myEdits.isLoading = false
      this.notifyStateChanged()
    }
  }

  /**
   * 并发度受限地补成片首帧。
   * 复用剪辑页已有的取帧能力；取不到就安静留空，卡片回落到行程封面 —— 封面不该阻断列表。
   */
  private async resolveMyEditsCovers(records: Array<EditRecord>, cacheDir: string, token: number): Promise<void> {
    const queue: Array<EditRecord> = records.filter((record: EditRecord) =>
      record.coverPath.length === 0 && record.albumUri.length > 0)
    if (queue.length === 0) {
      return
    }
    let cursor: number = 0
    const work = async (): Promise<void> => {
      while (cursor < queue.length) {
        if (token !== this.myEditsToken) {
          return
        }
        const record = queue[cursor]
        cursor = cursor + 1
        let framePath: string = ''
        try {
          framePath = await extractFirstFrameByService(record.albumUri, cacheDir, record.id)
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error)
          debugLog('首页VM', `成片首帧提取异常 记录=${record.id}：${message}`)
          framePath = ''
        }
        if (token !== this.myEditsToken) {
          return
        }
        if (framePath.length === 0) {
          continue
        }
        record.coverPath = framePath
        const nextCovers: Record<string, string> = {}
        const keys = Object.keys(this.myEdits.coverPaths)
        for (let i = 0; i < keys.length; i++) {
          nextCovers[keys[i]] = this.myEdits.coverPaths[keys[i]]
        }
        nextCovers[record.id] = framePath
        this.myEdits.coverPaths = nextCovers
        this.notifyStateChanged()
        try {
          await EditHistoryService.getInstance().updateCoverPath(record.id, framePath)
        } catch (error) {
          // 缓存路径落盘失败只影响下次启动重取，不影响本次展示
          debugLog('首页VM', `记录封面路径写盘失败 记录=${record.id}`)
        }
      }
    }
    const workers: Array<Promise<void>> = []
    const workerCount = Math.min(COVER_EXTRACT_CONCURRENCY, queue.length)
    for (let i = 0; i < workerCount; i++) {
      workers.push(work())
    }
    await Promise.all(workers)
  }

  /**
   * 孤儿检测。三条硬规则（spec 4.11）：
   * 1. 没拿到 READ_IMAGEVIDEO 就一律记「未知」，绝不判孤儿；
   * 2. 只有「权限已授予 且 相册 URI 打不开」才算孤儿；
   * 3. 全程零写盘，只改内存里的 id 集合。
   */
  private async resolveMyEditsOrphans(records: Array<EditRecord>, token: number): Promise<void> {
    if (records.length === 0) {
      return
    }
    if (!this.state.permissionGranted) {
      const unknownIds: Array<string> = records.map((record: EditRecord) => record.id)
      if (token !== this.myEditsToken) {
        return
      }
      this.myEdits.unknownIds = unknownIds
      this.myEdits.orphanIds = []
      this.notifyStateChanged()
      return
    }
    const orphanIds: Array<string> = []
    const unknownIds: Array<string> = []
    for (let i = 0; i < records.length; i++) {
      if (token !== this.myEditsToken) {
        return
      }
      const record = records[i]
      if (record.albumUri.length === 0) {
        orphanIds.push(record.id)
        continue
      }
      const probe = await this.probeAlbumUri(record.albumUri)
      if (probe === 'missing') {
        orphanIds.push(record.id)
      } else if (probe === 'unknown') {
        unknownIds.push(record.id)
      }
    }
    if (token !== this.myEditsToken) {
      return
    }
    this.myEdits.orphanIds = orphanIds
    this.myEdits.unknownIds = unknownIds
    this.notifyStateChanged()
  }

  private async probeAlbumUri(albumUri: string): Promise<string> {
    let opened: fs.File | null = null
    try {
      opened = await fs.open(albumUri, fs.OpenMode.READ_ONLY)
      return 'ok'
    } catch (error) {
      const code = (error as BusinessError).code
      debugLog('首页VM', `探测相册成片失败 code=${code}`)
      // 201 / 13900012 是权限问题 —— 这时"打不开"不代表文件没了
      if (code === 201 || code === 13900012) {
        return 'unknown'
      }
      return 'missing'
    } finally {
      if (opened !== null) {
        try {
          fs.closeSync(opened)
        } catch (closeError) {
          debugLog('首页VM', '关闭探测用的文件句柄失败')
        }
      }
    }
  }

  openEditorFromRecordRoute(record: EditRecord): HomeRouteRequest {
    return {
      url: PAGE_ROUTE_EDITOR,
      params: {
        tripId: record.tripId,
        recordId: record.id
      }
    }
  }

  toggleRecordSelection(recordId: string): void {
    if (!this.myEdits.selectionMode) {
      return
    }
    const existsInList = this.myEdits.records.some((record: EditRecord) => record.id === recordId)
    if (!existsInList) {
      return
    }
    const exists = this.myEdits.selectedRecordIds.some((id: string) => id === recordId)
    if (exists) {
      this.myEdits.selectedRecordIds = this.myEdits.selectedRecordIds.filter((id: string) => id !== recordId)
      return
    }
    this.myEdits.selectedRecordIds = [...this.myEdits.selectedRecordIds, recordId]
  }

  toggleRecordSelectionMode(): void {
    if (this.myEdits.selectionMode) {
      this.myEdits.selectionMode = false
      this.myEdits.selectedRecordIds = []
      return
    }
    this.myEdits.selectionMode = true
  }

  isRecordSelected(recordId: string): boolean {
    return this.myEdits.selectedRecordIds.some((id: string) => id === recordId)
  }

  canShowDeleteButton(): boolean {
    return this.myEdits.selectionMode && this.myEdits.selectedRecordIds.length >= 1
  }

  /**
   * 只删记录层，相册里的成片保持不动（spec 4.7 —— 删文件需要受控权限，做不到也不假装做到）。
   */
  async deleteSelectedRecords(): Promise<boolean> {
    if (this.myEdits.selectedRecordIds.length === 0) {
      return false
    }
    const ids: Array<string> = [...this.myEdits.selectedRecordIds]
    try {
      const ok = await EditHistoryService.getInstance().remove(ids)
      if (!ok) {
        this.myEdits.errorText = '历史记录暂时不可用'
        this.notifyStateChanged()
        return false
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('首页VM', `删除剪辑记录失败：${message}`)
      this.myEdits.errorText = '历史记录暂时不可用'
      this.notifyStateChanged()
      return false
    }
    this.myEdits.records = this.myEdits.records.filter((record: EditRecord) => ids.indexOf(record.id) < 0)
    this.myEdits.orphanIds = this.myEdits.orphanIds.filter((id: string) => ids.indexOf(id) < 0)
    this.myEdits.unknownIds = this.myEdits.unknownIds.filter((id: string) => ids.indexOf(id) < 0)
    this.myEdits.selectedRecordIds = []
    this.myEdits.selectionMode = false
    this.notifyStateChanged()
    return true
  }

  isRecordOrphan(recordId: string): boolean {
    return this.myEdits.orphanIds.some((id: string) => id === recordId)
  }

  isRecordOrphanUnknown(recordId: string): boolean {
    return this.myEdits.unknownIds.some((id: string) => id === recordId)
  }

  /**
   * 点 ▶ 看成片：用隐式 Want 交给系统播放。返回空串表示已拉起，否则是给用户看的失败文案。
   * 注意：stage model 没有 ACTION_VIEW_DATA 常量，action 只能写字面量（spec 4.10）。
   */
  async playRecord(record: EditRecord, context: common.UIAbilityContext): Promise<string> {
    if (this.isRecordOrphan(record.id)) {
      return '相册里的视频已被删除'
    }
    if (record.albumUri.length === 0) {
      return '没有找到这条视频'
    }
    try {
      await context.startAbility({
        action: 'ohos.want.action.viewData',
        uri: record.albumUri,
        type: 'video/mp4',
        flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
      })
      return ''
    } catch (error) {
      const code = (error as BusinessError).code
      debugLog('首页VM', `拉起系统播放失败 code=${code}`)
      return '没有找到能播放这条视频的应用'
    }
  }
}
