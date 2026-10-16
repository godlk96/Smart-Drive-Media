import common from '@ohos.app.ability.common'
import abilityAccessCtrl from '@ohos.abilityAccessCtrl'
import { sharedCoreBridge } from '../bridge/CoreBridge'
import { PAGE_ROUTE_EDITOR, REQUIRED_MEDIA_PERMISSIONS } from '../constants/AppConstants'
import { LibraryStateModel, TripCardModel } from '../model/AppState'
import { debugLog } from '../utils/Logger'

export interface HomeRouteRequest {
  url: string
  params: HomeRouteParams
}

export interface HomeRouteParams {
  tripId: string
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

export class HomeViewModel {
  private state: HomeViewState = createEmptyHomeState()
  private bridge = sharedCoreBridge
  private isRefreshing: boolean = false
  private onStateChangedListener?: () => void

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
}
