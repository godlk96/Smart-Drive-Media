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
    Column({ space: 12 }) {
      Row() {
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
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16 })

      Text('自动识别相册中的行车记录')
        .fontSize(13)
        .fontColor('#94A3B8')
        .width('100%')
        .padding({ left: 16, right: 16 })

      if (this.state.permissionTip.length > 0) {
        Text(this.state.permissionTip)
          .fontSize(12)
          .fontColor('#F59E0B')
          .width('100%')
          .padding({ left: 16, right: 16, top: 4 })
      }

      if (this.state.empty) {
        Column() {
          Text(this.state.emptyText)
            .fontSize(13)
            .fontColor('#94A3B8')
        }
        .width('100%')
        .height('70%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        if (this.selectedTripIds.length > 0) {
          Row() {
            Text(`已选 ${this.selectedTripIds.length} 组`)
              .fontSize(12)
              .fontColor('#93C5FD')
            Blank()
            Button('合并进入剪辑')
              .type(ButtonType.Capsule)
              .fontSize(12)
              .onClick(() => this.openMergedEditor())
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4 })
        }

        List({ space: 12 }) {
          ForEach(this.state.cards, (item: TripCardModel) => {
            ListItem() {
              Column({ space: 8 }) {
                Row() {
                  Text(item.title)
                    .fontSize(18)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#F8FAFC')
                  Blank()
                  Text(item.durationText)
                    .fontSize(11)
                    .fontColor('#94A3B8')
                }
                .width('100%')
                Text(item.subtitle)
                  .fontSize(12)
                  .fontColor('#94A3B8')
                  .width('100%')
                Row() {
                  Toggle({ type: ToggleType.Checkbox, isOn: this.selectedTripIds.some((id: string) => id === item.id) })
                    .onChange(() => this.toggleTripSelection(item))
                  Text('选中分组')
                    .fontSize(11)
                    .fontColor('#93C5FD')
                  Blank()
                  Text('去剪辑')
                    .fontSize(12)
                    .fontColor('#3B82F6')
                }
                .width('100%')
              }
              .width('100%')
              .padding(14)
              .backgroundColor('#1E293B')
              .borderRadius(12)
              .onClick(() => this.openEditor(item))
            }
          }, (item: TripCardModel) => item.id)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16, bottom: 16 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0F172A')
  }
}
