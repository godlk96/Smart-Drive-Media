import common from '@ohos.app.ability.common'
import abilityAccessCtrl from '@ohos.abilityAccessCtrl'
import { Permissions } from '@kit.AbilityKit'
import { sharedCoreBridge } from '../bridge/CoreBridge'
import { LibraryStateModel, TripCardModel } from '../model/AppState'
import { debugLog } from '../utils/Logger'

const REQUIRED_PERMISSIONS: Array<Permissions> = [
  'ohos.permission.READ_MEDIA' as Permissions,
  'ohos.permission.READ_IMAGEVIDEO' as Permissions,
  'ohos.permission.WRITE_MEDIA' as Permissions
]

@Entry
@Component
struct Index {
  private bridge = sharedCoreBridge
  @State private permissionGranted: boolean = false
  @State private hasAutoRequestedPermission: boolean = false
  @State private selectionMode: boolean = false
  @State private selectedTripIds: Array<string> = []
  @State private state: LibraryStateModel = {
    title: '行程库',
    cards: [],
    empty: true,
    emptyText: '',
    permissionTip: ''
  }

  aboutToAppear(): void {
    if (!this.permissionGranted && !this.hasAutoRequestedPermission) {
      this.requestMediaPermissionAndRefresh(false)
    }
    this.refreshState()
  }

  private getHostContextOrNull(): common.UIAbilityContext | null {
    try {
      const host = this.getUIContext().getHostContext()
      if (host) {
        return host as common.UIAbilityContext
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('首页', `获取上下文失败：${message}`)
    }
    return null
  }

  private refreshState(): void {
    debugLog('首页', `刷新列表，授权状态=${this.permissionGranted}`)
    const context = this.getHostContextOrNull()
    if (context === null) {
      return
    }
    this.bridge.createLibraryState(this.permissionGranted, context)
      .then((next: LibraryStateModel) => {
        this.state = next
        this.selectedTripIds = this.selectedTripIds.filter((id: string) => next.cards.some((item: TripCardModel) => item.id === id))
      })
      .catch((error: Error) => {
        debugLog('首页', `刷新失败：${error.message}`)
      })
  }

  private openEditor(card: TripCardModel): void {
    debugLog('首页', `进入剪辑，行程=${card.id}`)
    try {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/Editor',
        params: {
          tripId: card.id,
          title: card.title,
          subtitle: card.subtitle
        }
      })
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('首页', `进入剪辑失败：${message}`)
    }
  }

  private toggleTripSelection(card: TripCardModel): void {
    const exists = this.selectedTripIds.some((id: string) => id === card.id)
    if (exists) {
      this.selectedTripIds = this.selectedTripIds.filter((id: string) => id !== card.id)
      return
    }
    this.selectedTripIds = [...this.selectedTripIds, card.id]
  }

  private toggleSelectionMode(): void {
    if (this.selectionMode) {
      this.selectionMode = false
      this.selectedTripIds = []
      return
    }
    this.selectionMode = true
  }

  private isTripSelected(cardId: string): boolean {
    return this.selectedTripIds.some((id: string) => id === cardId)
  }

  private getDisplayCards(): Array<TripCardModel> {
    return [...this.state.cards].reverse()
  }

  private getSelectedTotalDurationSec(): number {
    return this.state.cards
      .filter((item: TripCardModel) => this.isTripSelected(item.id))
      .reduce((total: number, item: TripCardModel) => total + item.durationSec, 0)
  }

  private formatTotalDuration(totalSec: number): string {
    const seconds = Math.max(0, Math.floor(totalSec))
    const hour = Math.floor(seconds / 3600)
    const minute = Math.floor((seconds % 3600) / 60)
    const second = seconds % 60
    if (hour > 0) {
      return `${hour}h ${minute}m`
    }
    if (minute > 0) {
      return `${minute}m ${second}s`
    }
    return `${second}s`
  }

  private canShowMergeButton(): boolean {
    return this.selectionMode && this.selectedTripIds.length >= 2
  }

  private getCompletenessText(card: TripCardModel): string {
    return card.previewUri.length > 0 ? '完整' : '不完整'
  }

  private getCompletenessColor(card: TripCardModel): string {
    return card.previewUri.length > 0 ? '#0A59F7' : '#FF7A00'
  }

  private handleCardClick(card: TripCardModel): void {
    if (this.selectionMode) {
      this.toggleTripSelection(card)
      return
    }
    this.openEditor(card)
  }

  private openMergedEditor(): void {
    const mergedTripId = this.bridge.mergeTrips(this.selectedTripIds)
    if (mergedTripId.length === 0) {
      return
    }
    debugLog('首页', `进入合并剪辑，行程数量=${this.selectedTripIds.length}`)
    try {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/Editor',
        params: {
          tripId: mergedTripId,
          title: '',
          subtitle: ''
        }
      })
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('首页', `进入合并剪辑失败：${message}`)
    }
  }

  private requestMediaPermissionAndRefresh(shouldGuideToSetting: boolean = true): void {
    this.hasAutoRequestedPermission = true
    const context = this.getHostContextOrNull()
    if (context === null) {
      this.permissionGranted = false
      return
    }
    const atManager = abilityAccessCtrl.createAtManager()
    atManager.requestPermissionsFromUser(context, REQUIRED_PERMISSIONS)
      .then((result) => {
        const allGranted = result.authResults.every((item: number) => item === 0)
        if (allGranted) {
          this.permissionGranted = true
          debugLog('首页', '权限申请完成，已全部授权')
          this.refreshState()
          return
        }
        if (!shouldGuideToSetting) {
          this.permissionGranted = false
          debugLog('首页', '自动权限申请未全部通过，展示无权限态')
          this.refreshState()
          return
        }
        debugLog('首页', '权限被拒绝，尝试拉起系统设置授权页')
        atManager.requestPermissionOnSetting(context, REQUIRED_PERMISSIONS)
          .then((settingResult: Array<number>) => {
            const grantedInSetting = settingResult.every((item: number) => item === 0)
            this.permissionGranted = grantedInSetting
            debugLog('首页', `设置页授权结果=${grantedInSetting ? '已授权' : '未授权'}`)
            this.refreshState()
          })
          .catch((settingError: Error) => {
            this.permissionGranted = false
            debugLog('首页', `拉起设置页失败：${settingError.message}`)
            this.refreshState()
          })
      })
      .catch((error: Error) => {
        this.permissionGranted = false
        debugLog('首页', `权限申请失败：${error.message}`)
        this.refreshState()
      })
  }

  build() {
    Column({ space: 0 }) {
      Row() {
        Text('行车记录6视角剪辑')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
        Row({ space: 8 }) {
          if (this.canShowMergeButton()) {
            Button('合并剪辑')
              .height(36)
              .padding({ left: 16, right: 16 })
              .fontSize(14)
              .fontColor('#FFFFFF')
              .backgroundColor('#FF7A00')
              .borderRadius(8)
              .onClick(() => this.openMergedEditor())
          }
          Button(this.selectionMode ? '取消' : '多选')
            .height(36)
            .padding({ left: 16, right: 16 })
            .fontSize(14)
            .fontColor('#FFFFFF')
            .backgroundColor(this.selectionMode ? '#FF7A00' : '#00000000')
            .border({
              width: 1,
              color: this.selectionMode ? '#FF7A00' : '#444444'
            })
            .borderRadius(8)
            .onClick(() => this.toggleSelectionMode())
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 16, top: 16, bottom: 16 })

      if (this.state.permissionTip.length > 0) {
        Text(this.state.permissionTip)
          .fontSize(12)
          .fontColor('#FF7A00')
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 8 })
      }

      if (!this.permissionGranted && this.state.empty) {
        Column({ space: 12 }) {
          Text('需要访问相册权限')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
          Text(this.state.emptyText)
            .fontSize(14)
            .fontColor('#999999')
            .textAlign(TextAlign.Center)
          Button('授权并刷新')
            .height(40)
            .padding({ left: 18, right: 18 })
            .fontSize(14)
            .fontColor('#FFFFFF')
            .backgroundColor('#FF7A00')
            .borderRadius(8)
            .onClick(() => this.requestMediaPermissionAndRefresh())
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding({ left: 20, right: 20 })
      } else if (this.state.empty) {
        Column() {
          Text(this.state.emptyText)
            .fontSize(14)
            .fontColor('#999999')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding({ left: 20, right: 20 })
      } else {
        Grid() {
          ForEach(this.getDisplayCards(), (item: TripCardModel) => {
            GridItem() {
              Column({ space: 0 }) {
                Stack({ alignContent: Alignment.TopStart }) {
                  if (item.previewFrameUri.length > 0) {
                    if (item.previewFrameUri.endsWith('.jpg') || item.previewFrameUri.endsWith('.jpeg') || item.previewFrameUri.endsWith('.png') || item.previewFrameUri.endsWith('.webp')) {
                      Image(item.previewFrameUri)
                        .width('100%')
                        .height('100%')
                        .objectFit(ImageFit.Cover)
                    } else {
                      Video({
                        src: item.previewFrameUri
                      })
                        .width('100%')
                        .height('100%')
                        .objectFit(ImageFit.Cover)
                        .autoPlay(true)
                        .controls(false)
                        .muted(true)
                    }
                  } else {
                    Column({ space: 4 }) {
                      Text('预览')
                        .fontSize(10)
                        .fontColor('#999999')
                      Text(item.previewUri.length > 0 ? '已命中视频' : '无视频')
                        .fontSize(10)
                        .fontColor('#666666')
                    }
                    .width('100%')
                    .height('100%')
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .backgroundColor('#333333')
                  }
                  Text(this.getCompletenessText(item))
                    .fontSize(10)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#FFFFFF')
                    .backgroundColor(this.getCompletenessColor(item))
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .borderRadius(3)
                    .margin({ top: 4, left: 4 })
                  if (this.selectionMode && this.isTripSelected(item.id)) {
                    Text('✓')
                      .fontSize(12)
                      .fontColor('#FFFFFF')
                      .width(20)
                      .height(20)
                      .textAlign(TextAlign.Center)
                      .backgroundColor('#FF7A00')
                      .borderRadius(10)
                      .position({ x: '84%', y: '4%' })
                  }
                }
                .width('100%')
                .aspectRatio(16 / 9)
                .borderRadius(12)
                .clip(true)
                .border({
                  width: this.isTripSelected(item.id) ? 2 : 0,
                  color: '#FF7A00'
                })
                .backgroundColor('#282828')
                .onClick(() => this.handleCardClick(item))

                Column({ space: 2 }) {
                  Text(item.title)
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#FFFFFF')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(item.subtitle)
                    .fontSize(10)
                    .fontColor('#999999')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%')
                .padding({ left: 8, right: 8, top: 8, bottom: 8 })
                .backgroundColor('#282828')
              }
            }
          }, (item: TripCardModel) => item.id)
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(12)
        .rowsGap(12)
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 16 })
      }
    }
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
    .backgroundColor('#181818')
  }
}
