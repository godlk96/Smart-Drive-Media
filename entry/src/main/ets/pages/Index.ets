import common from '@ohos.app.ability.common'
import { LibraryStateModel, TripCardModel } from '../model/AppState'
import { debugLog } from '../utils/Logger'
import { HomeViewModel } from '../viewmodel/HomeViewModel'

@Entry
@Component
struct Index {
  private viewModel: HomeViewModel = new HomeViewModel()
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
    this.syncViewState()
    if (!this.permissionGranted && !this.hasAutoRequestedPermission) {
      void this.requestMediaPermissionAndRefresh(false)
    }
    void this.refreshState()
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

  private syncViewState(): void {
    const state = this.viewModel.getState()
    this.permissionGranted = state.permissionGranted
    this.hasAutoRequestedPermission = state.hasAutoRequestedPermission
    this.selectionMode = state.selectionMode
    this.selectedTripIds = state.selectedTripIds
    this.state = state.libraryState
  }

  private async refreshState(): Promise<void> {
    const context = this.getHostContextOrNull()
    if (context === null) {
      return
    }
    try {
      await this.viewModel.refresh(context)
      this.syncViewState()
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('首页', `刷新失败：${message}`)
    }
  }

  private openEditor(card: TripCardModel): void {
    debugLog('首页', `进入剪辑，行程=${card.id}`)
    const route = this.viewModel.openEditorRoute(card)
    try {
      this.getUIContext().getRouter().pushUrl(route)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('首页', `进入剪辑失败：${message}`)
    }
  }

  private toggleTripSelection(card: TripCardModel): void {
    this.viewModel.toggleTripSelection(card.id)
    this.syncViewState()
  }

  private toggleSelectionMode(): void {
    this.viewModel.toggleSelectionMode()
    this.syncViewState()
  }

  private isTripSelected(cardId: string): boolean {
    return this.selectedTripIds.some((id: string) => id === cardId)
  }

  private getDisplayCards(): Array<TripCardModel> {
    return this.viewModel.getDisplayCards()
  }

  private canShowMergeButton(): boolean {
    return this.selectionMode && this.selectedTripIds.length >= 2
  }

  private hasImageCover(item: TripCardModel): boolean {
    const uri = item.previewFrameUri
    if (uri.length === 0) {
      return false
    }
    const lower = uri.toLowerCase()
    return lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png') || lower.endsWith('.webp')
  }

  private formatCoverUri(uri: string): string {
    if (uri.startsWith('file://') || uri.startsWith('http://') || uri.startsWith('https://')) {
      return uri
    }
    return `file://${uri}`
  }

  private getCompletenessText(card: TripCardModel): string {
    return this.viewModel.getCompletenessText(card)
  }

  private getCompletenessColor(card: TripCardModel): string {
    return this.viewModel.getCompletenessColor(card)
  }

  private handleCardClick(card: TripCardModel): void {
    if (this.selectionMode) {
      this.toggleTripSelection(card)
      return
    }
    this.openEditor(card)
  }

  private openMergedEditor(): void {
    const route = this.viewModel.openMergedEditorRoute()
    if (!route) {
      return
    }
    debugLog('首页', `进入合并剪辑，行程数量=${this.selectedTripIds.length}`)
    try {
      this.getUIContext().getRouter().pushUrl(route)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('首页', `进入合并剪辑失败：${message}`)
    }
  }

  private async requestMediaPermissionAndRefresh(shouldGuideToSetting: boolean = true): Promise<void> {
    const context = this.getHostContextOrNull()
    if (context === null) {
      return
    }
    await this.viewModel.requestMediaPermissionAndRefresh(context, shouldGuideToSetting)
    this.syncViewState()
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
                  if (this.hasImageCover(item)) {
                    Image(this.formatCoverUri(item.previewFrameUri))
                      .width('100%')
                      .height('100%')
                      .objectFit(ImageFit.Cover)
                      .alt($r('app.media.app_icon'))
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
