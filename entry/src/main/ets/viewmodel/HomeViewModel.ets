import common from '@ohos.app.ability.common'
import abilityAccessCtrl from '@ohos.abilityAccessCtrl'
import wantConstant from '@ohos.app.ability.wantConstant'
import { BusinessError } from '@ohos.base'
import { sharedCoreBridge } from '../bridge/CoreBridge'
import { PAGE_ROUTE_EDITOR, REQUIRED_MEDIA_PERMISSIONS } from '../constants/AppConstants'
import { LibraryStateModel, TripCardModel } from '../model/AppState'
import { WorkStore, WorkEntry } from '../service/WorkStore'
import { debugLog } from '../utils/Logger'

export interface HomeRouteRequest {
  url: string
  params: HomeRouteParams
}

export interface HomeRouteParams {
  /** 从「行程库」进入时带上的行程 id */
  tripId?: string
  /** 从「我的剪辑」进入时带上，剪辑页据此按作品 id 还原那次导出的参数 */
  workId?: string
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
  entries: Array<WorkEntry>
  isLoading: boolean
  /** 非空表示这次读取失败，列表要显示提示而不是装成空历史 */
  errorText: string
  selectionMode: boolean
  selectedEntryIds: Array<string>
}

function createEmptyMyEditsState(): MyEditsViewState {
  return {
    entries: [],
    isLoading: true,
    errorText: '',
    selectionMode: false,
    selectedEntryIds: []
  }
}

function cloneWorkEntry(entry: WorkEntry): WorkEntry {
  const next = new WorkEntry()
  next.id = entry.id
  next.videoPath = entry.videoPath
  next.coverPath = entry.coverPath
  // meta 在列表里只读，共享引用即可（sidecar 不会在会话中被就地改写）。
  next.meta = entry.meta
  next.sortKey = entry.sortKey
  return next
}

export class HomeViewModel {
  private state: HomeViewState = createEmptyHomeState()
  private bridge = sharedCoreBridge
  private isRefreshing: boolean = false
  private onStateChangedListener?: () => void
  private myEdits: MyEditsViewState = createEmptyMyEditsState()
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
    return {
      entries: this.myEdits.entries.map((entry: WorkEntry) => cloneWorkEntry(entry)),
      isLoading: this.myEdits.isLoading,
      errorText: this.myEdits.errorText,
      selectionMode: this.myEdits.selectionMode,
      selectedEntryIds: [...this.myEdits.selectedEntryIds]
    }
  }

  /**
   * 读作品库目录（`filesDir/exports/`）一次，拿到就是全部 —— 一次 `WorkStore.list()`
   * 之后直接通知界面。
   *
   * 不再有「先出列表再后台补封面 / 补孤儿」两段式：封面在导出时就落成 `<id>.jpg`，
   * 缺 sidecar 的作品在 `WorkEntry.meta` 里如实体现为 undefined，界面按 `canReedit` 降级。
   * 整条链路不读 preferences、不扫相册、不要权限。
   */
  async refreshMyEdits(context: common.UIAbilityContext): Promise<void> {
    if (this.isRefreshingMyEdits) {
      debugLog('首页VM', '我的剪辑正在刷新中，跳过重复刷新')
      return
    }
    this.isRefreshingMyEdits = true
    this.myEdits.isLoading = true
    this.myEdits.errorText = ''
    this.notifyStateChanged()
    try {
      // 与旧链路同一个注入点，只是把依赖从 EditHistoryService 换成 WorkStore ——
      // 少了这一句，WorkStore 拿不到 context，exportsDir() 返回空串，列表永远空。
      WorkStore.getInstance().setContext(context)
      let loaded: Array<WorkEntry> = []
      try {
        loaded = await WorkStore.getInstance().list()
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        debugLog('首页VM', `读取作品库失败：${message}`)
        this.myEdits.entries = []
        this.myEdits.errorText = '作品库暂时不可用'
        return
      }
      this.myEdits.entries = loaded
      this.myEdits.selectedEntryIds = this.myEdits.selectedEntryIds
        .filter((id: string) => loaded.some((entry: WorkEntry) => entry.id === id))
      this.myEdits.errorText = ''
    } finally {
      this.isRefreshingMyEdits = false
      this.myEdits.isLoading = false
      this.notifyStateChanged()
    }
  }

  openEditorFromWorkRoute(entry: WorkEntry): HomeRouteRequest {
    return {
      url: PAGE_ROUTE_EDITOR,
      params: {
        workId: entry.id
      }
    }
  }

  toggleWorkSelection(entryId: string): void {
    if (!this.myEdits.selectionMode) {
      return
    }
    const existsInList = this.myEdits.entries.some((entry: WorkEntry) => entry.id === entryId)
    if (!existsInList) {
      return
    }
    const exists = this.myEdits.selectedEntryIds.some((id: string) => id === entryId)
    if (exists) {
      this.myEdits.selectedEntryIds = this.myEdits.selectedEntryIds.filter((id: string) => id !== entryId)
      return
    }
    this.myEdits.selectedEntryIds = [...this.myEdits.selectedEntryIds, entryId]
  }

  toggleWorkSelectionMode(): void {
    if (this.myEdits.selectionMode) {
      this.myEdits.selectionMode = false
      this.myEdits.selectedEntryIds = []
      return
    }
    this.myEdits.selectionMode = true
  }

  isWorkSelected(entryId: string): boolean {
    return this.myEdits.selectedEntryIds.some((id: string) => id === entryId)
  }

  canShowDeleteButton(): boolean {
    return this.myEdits.selectionMode && this.myEdits.selectedEntryIds.length >= 1
  }

  /**
   * 删作品：`WorkStore.deleteWork(id)` 会删掉 App 空间里的 `.mp4` / `.json` / `.jpg` 三份。
   * 相册里的副本 App 管不着（没有 `WRITE_IMAGEVIDEO`），删不掉也不假装删掉了 ——
   * 确认弹窗的文案已如实说明。
   */
  async deleteSelectedRecords(): Promise<boolean> {
    if (this.myEdits.selectedEntryIds.length === 0) {
      return false
    }
    const ids: Array<string> = [...this.myEdits.selectedEntryIds]
    let ok = true
    for (let i = 0; i < ids.length; i++) {
      const deleted = await WorkStore.getInstance().deleteWork(ids[i])
      if (!deleted) {
        ok = false
      }
    }
    if (!ok) {
      this.myEdits.errorText = '作品库暂时不可用'
      this.notifyStateChanged()
      return false
    }
    this.myEdits.entries = this.myEdits.entries.filter((entry: WorkEntry) => ids.indexOf(entry.id) < 0)
    this.myEdits.selectedEntryIds = []
    this.myEdits.selectionMode = false
    this.notifyStateChanged()
    return true
  }

  /**
   * 点 ▶ 看成片：用隐式 Want 交给系统播放。返回空串表示已拉起，否则是给用户看的失败文案。
   * 作品本体在 App 私有空间，用 `file://` 形式把沙盒路径交给系统（能不能播需真机确认，spec 风险 1）。
   * 注意：stage model 没有 ACTION_VIEW_DATA 常量，action 只能写字面量（spec 4.10）。
   */
  async playWork(entry: WorkEntry, context: common.UIAbilityContext): Promise<string> {
    if (entry.videoPath.length === 0) {
      return '没有找到这条视频'
    }
    try {
      await context.startAbility({
        action: 'ohos.want.action.viewData',
        uri: `file://${entry.videoPath}`,
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
