import router from '@ohos.router'
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
    this.refreshState()
  }

  private refreshState(): void {
    debugLog('首页', `刷新列表，授权状态=${this.permissionGranted}`)
    const context = getContext(this) as common.UIAbilityContext
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
    router.pushUrl({
      url: 'pages/Editor',
      params: {
        tripId: card.id,
        title: card.title,
        subtitle: card.subtitle
      }
    })
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
    router.pushUrl({
      url: 'pages/Editor',
      params: {
        tripId: mergedTripId,
        title: '',
        subtitle: ''
      }
    })
  }

  private requestMediaPermissionAndRefresh(): void {
    const context = getContext(this) as common.UIAbilityContext
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
    Stack({ alignContent: Alignment.Bottom }) {
      Column({ space: 10 }) {
        Row() {
          if (this.selectionMode) {
            Button('取消')
              .type(ButtonType.Normal)
              .fontSize(13)
              .fontColor('#94A3B8')
              .backgroundColor('#00000000')
              .onClick(() => this.toggleSelectionMode())
            Text(`已选 ${this.selectedTripIds.length}`)
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor('#F8FAFC')
            Blank()
          } else {
            Text('智驾影音')
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor('#F8FAFC')
            Blank()
            Button(this.permissionGranted ? '已授权' : '授权读取')
              .type(ButtonType.Capsule)
              .fontSize(12)
              .onClick(() => {
                debugLog('首页', '点击授权按钮')
                this.requestMediaPermissionAndRefresh()
              })
            Button('选择')
              .type(ButtonType.Capsule)
              .fontSize(12)
              .fontColor('#F97316')
              .backgroundColor('#3F1C1408')
              .onClick(() => this.toggleSelectionMode())
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12 })

        if (!this.selectionMode) {
          Text('自动识别相册中的行车记录')
            .fontSize(13)
            .fontColor('#94A3B8')
            .width('100%')
            .padding({ left: 16, right: 16 })
        }

        if (this.state.permissionTip.length > 0) {
          Text(this.state.permissionTip)
            .fontSize(12)
            .fontColor('#F59E0B')
            .width('100%')
            .padding({ left: 16, right: 16, top: 2 })
        }

        if (this.state.empty) {
          Column() {
            Text(this.state.emptyText)
              .fontSize(13)
              .fontColor('#94A3B8')
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
                Stack({ alignContent: Alignment.TopEnd }) {
                  Stack({ alignContent: Alignment.BottomStart }) {
                    if (item.previewUri.length > 0) {
                      Image(item.previewUri)
                        .width('100%')
                        .height('100%')
                        .objectFit(ImageFit.Cover)
                    } else {
                      Column()
                        .width('100%')
                        .height('100%')
                        .backgroundColor('#1E293B')
                    }

                    Column()
                      .width('100%')
                      .height('55%')
                      .linearGradient({
                        angle: 180,
                        colors: [['#00000000', 0.0], ['#45000000', 0.4], ['#DD020617', 1.0]]
                      })
                      .alignSelf(ItemAlign.End)

                    Column({ space: 4 }) {
                      Row() {
                        Text(item.durationText)
                          .fontSize(10)
                          .fontColor('#F8FAFC')
                          .backgroundColor('#66000000')
                          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                          .borderRadius(6)
                        Blank()
                      }
                      .width('100%')
                      Row() {
                        Column({ space: 2 }) {
                          Text(item.title)
                            .fontSize(14)
                            .fontWeight(FontWeight.Bold)
                            .fontColor('#F8FAFC')
                          Text(item.subtitle)
                            .fontSize(10)
                            .fontColor('#CBD5E1')
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                        }
                        .alignItems(HorizontalAlign.Start)
                        .layoutWeight(1)
                      }
                      .width('100%')
                    }
                    .width('100%')
                    .padding(10)
                    .alignItems(HorizontalAlign.Start)
                  }
                  .width('100%')
                  .aspectRatio(4 / 3)
                  .borderRadius(12)
                  .clip(true)
                  .border({
                    width: this.isTripSelected(item.id) ? 2 : 0,
                    color: '#F97316'
                  })
                  .backgroundColor('#1E293B')
                  .onClick(() => this.handleCardClick(item))

                  if (this.selectionMode) {
                    Text(this.isTripSelected(item.id) ? '✓' : '')
                      .fontSize(11)
                      .fontWeight(FontWeight.Bold)
                      .fontColor('#FFFFFF')
                      .width(20)
                      .height(20)
                      .textAlign(TextAlign.Center)
                      .backgroundColor(this.isTripSelected(item.id) ? '#F97316' : '#33000000')
                      .borderRadius(10)
                      .margin({ top: 8, right: 8 })
                  }
                }
              }
            }, (item: TripCardModel) => item.id)
          }
          .columnsTemplate('1fr 1fr')
          .columnsGap(10)
          .rowsGap(10)
          .layoutWeight(1)
          .width('100%')
          .padding({
            left: 16,
            right: 16,
            bottom: this.selectionMode ? 130 : 16
          })
        }
      }
      .width('100%')
      .height('100%')

      if (this.selectionMode) {
        Row() {
          Column({ space: 2 }) {
            Text(`已选 ${this.selectedTripIds.length} 组`)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor('#F8FAFC')
            Text(`总时长 ${this.formatTotalDuration(this.getSelectedTotalDurationSec())}`)
              .fontSize(11)
              .fontColor('#94A3B8')
          }
          .alignItems(HorizontalAlign.Start)
          Blank()
          Button('合并并剪辑')
            .type(ButtonType.Capsule)
            .fontSize(13)
            .enabled(this.selectedTripIds.length > 0)
            .onClick(() => this.openMergedEditor())
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 20 })
        .backgroundColor('#EE0F172A')
      }
    }
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
    .backgroundColor('#0F172A')
  }
}
