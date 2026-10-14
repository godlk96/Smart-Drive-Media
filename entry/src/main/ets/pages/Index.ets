import common from '@ohos.app.ability.common'
import { AppIcon, AppIconName } from '../components/AppIcon'
import { LibraryStateModel, TripCardModel } from '../model/AppState'
import { debugLog } from '../utils/Logger'
import { formatTripDay, formatTripDuration, getTripStartTime, isTripComplete } from '../utils/TripFormat'
import { HomeViewModel } from '../viewmodel/HomeViewModel'

/** 时间轴轨宽度：时间右对齐、状态点压在最右侧，与封面之间留 10vp */
// 46 装不下 "13:28"：右侧还要留 13vp 给状态点，可用只有 33vp，
// 5 个字符的粗体时间会折成两行。加到 54。
const RAIL_WIDTH: number = 54
/** 封面与时间轴轨之间的间隙，等于轨道容器左内边距 */
const RAIL_GAP: number = 10
/** 行与行之间的呼吸位。留成容器底内边距，竖线才能穿过它连到下一段 */
const ROW_GAP: number = 12

/** 一行的全部渲染输入，凑成一个对象是为了走 @Builder 的按引用传递 */
interface TripRowContext {
  card: TripCardModel
  index: number
  dayStart: boolean
  last: boolean
}

@Entry
@Component
struct Index {
  private viewModel: HomeViewModel = new HomeViewModel()
  @State private permissionGranted: boolean = false
  @State private hasAutoRequestedPermission: boolean = false
  @State private selectionMode: boolean = false
  @State private selectedTripIds: Array<string> = []
  @State private displayCards: Array<TripCardModel> = []
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
    // 列表只反转一次并缓存：ForEach 里要按相邻两项比较日期，不能每次重算
    this.displayCards = [...state.libraryState.cards].reverse()
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

  private isDayStart(index: number): boolean {
    if (index <= 0) {
      return true
    }
    return this.displayCards[index].title !== this.displayCards[index - 1].title
  }

  private cardShadow(selected: boolean): ShadowOptions {
    if (selected) {
      return { radius: 14, color: $r('app.color.shadow_amber'), offsetX: 0, offsetY: 4 }
    }
    return { radius: 2, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 1 }
  }

  private getSummaryText(): string {
    const count: number = this.displayCards.length
    if (count === 0) {
      return ''
    }
    let totalSec: number = 0
    this.displayCards.forEach((card: TripCardModel) => {
      totalSec += card.durationSec
    })
    return `${count} 段 · ${formatTripDuration(totalSec)}`
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

  @Builder
  pageHeader() {
    Row({ space: 10 }) {
      Text(this.state.title)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)

      Text(this.getSummaryText())
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))

      if (this.canShowMergeButton()) {
        Button('合并剪辑')
          .height(32)
          .padding({ left: 14, right: 14 })
          .fontSize(13)
          .fontColor($r('app.color.card_bg'))
          .backgroundColor($r('app.color.ink'))
          .borderRadius(8)
          .onClick(() => this.openMergedEditor())
      }

      Button(this.selectionMode ? '取消' : '多选')
        .height(32)
        .padding({ left: 14, right: 14 })
        .fontSize(13)
        .fontColor(this.selectionMode ? $r('app.color.card_bg') : $r('app.color.text_primary'))
        .backgroundColor(this.selectionMode ? $r('app.color.ink') : $r('app.color.card_bg'))
        .border({
          width: 1,
          color: this.selectionMode ? $r('app.color.ink') : $r('app.color.page_border')
        })
        .borderRadius(8)
        .onClick(() => this.toggleSelectionMode())
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 16, bottom: 14 })
  }

  @Builder
  tripRow(ctx: TripRowContext) {
    Column({ space: 0 }) {
      if (ctx.dayStart) {
        Row({ space: 9 }) {
          Text(formatTripDay(ctx.card.title))
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_secondary'))
          Row()
            .height(1)
            .backgroundColor($r('app.color.page_border'))
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 14, right: 14, top: 13, bottom: 8 })
      }

      Row({ space: 0 }) {
        // 时间轴轨：时间右对齐贴住竖线，状态点压在竖线上
        Stack({ alignContent: Alignment.TopEnd }) {
          Text(getTripStartTime(ctx.card))
            .fontSize(13.5)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .textAlign(TextAlign.End)
            .maxLines(1)
            .width('100%')
            .padding({ right: 13, top: 2 })

          Row()
            .width(9)
            .height(9)
            .borderRadius(4.5)
            .backgroundColor(isTripComplete(ctx.card) ? $r('app.color.amber') : $r('app.color.page_bg'))
            .border({
              width: isTripComplete(ctx.card) ? 0 : 1.5,
              color: $r('app.color.text_disabled')
            })
            .offset({ x: 4.5, y: 5 })
        }
        .width(RAIL_WIDTH)
        // 竖线是下一列（封面容器）的左边框，而封面容器在兄弟顺序里排在轨道之后，
        // 后画的会盖住先画的 —— 状态点正好压在线上，会被那条 1vp 线从中间劈开。
        // 抬高整条轨道的层级，让点画在线的上面。
        .zIndex(1)

        // 竖线画在封面容器的左边框上：容器高度含底部呼吸位，
        // 所以相邻两行的线天然接得上，不需要任何百分比高度
        Column({ space: 0 }) {
          Stack({ alignContent: Alignment.TopStart }) {
            if (this.hasImageCover(ctx.card)) {
              Image(this.formatCoverUri(ctx.card.previewFrameUri))
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Cover)
                .alt($r('app.media.app_icon'))
            } else {
              Column() {
                Text('无封面')
                  .fontSize(11)
                  .fontColor($r('app.color.text_disabled'))
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
            }

            if (ctx.index === 0) {
              Text('最近')
                .fontSize(9.5)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .backgroundColor($r('app.color.amber_light'))
                .borderRadius(5)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .margin({ left: 9, top: 9 })
            }

            if (this.selectionMode && this.isTripSelected(ctx.card.id)) {
              Stack({ alignContent: Alignment.Center }) {
                AppIcon({ name: AppIconName.Check, iconSize: 14, iconColor: $r('app.color.card_bg') })
              }
              .width(20)
              .height(20)
              .borderRadius(10)
              .backgroundColor($r('app.color.amber'))
              .position({ x: '84%', y: '4%' })
            }
          }
          .width('100%')
          .aspectRatio(16 / 9)
          .borderRadius(11)
          .clip(true)
          .backgroundColor($r('app.color.stage_bg'))
          .border({
            width: this.isTripSelected(ctx.card.id) ? 1.5 : 1,
            color: this.isTripSelected(ctx.card.id) ? $r('app.color.amber') : $r('app.color.card_border')
          })
          .shadow(this.cardShadow(this.isTripSelected(ctx.card.id)))
          .onClick(() => this.handleCardClick(ctx.card))
        }
        .layoutWeight(1)
        .padding({ left: RAIL_GAP, bottom: ROW_GAP })
        .border({
          width: { left: 1 },
          color: ctx.last ? $r('app.color.page_bg') : $r('app.color.segment_off_border')
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ left: 14, right: 14 })
    }
    .width('100%')
  }

  @Builder
  permissionBlock() {
    Column({ space: 12 }) {
      Text('需要访问相册权限')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text(this.state.emptyText)
        .fontSize(13)
        .fontColor($r('app.color.text_tertiary'))
        .textAlign(TextAlign.Center)
      Button('授权并刷新')
        .height(40)
        .padding({ left: 18, right: 18 })
        .fontSize(14)
        .fontColor($r('app.color.card_bg'))
        .backgroundColor($r('app.color.ink'))
        .borderRadius(8)
        .onClick(() => this.requestMediaPermissionAndRefresh())
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 20, right: 20 })
  }

  @Builder
  emptyBlock() {
    Column() {
      Text(this.state.emptyText)
        .fontSize(13)
        .fontColor($r('app.color.text_tertiary'))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 20, right: 20 })
  }

  @Builder
  tripList() {
    List({ space: 0 }) {
      ForEach(this.displayCards, (item: TripCardModel, index: number) => {
        ListItem() {
          this.tripRow({
            card: item,
            index: index,
            dayStart: this.isDayStart(index),
            last: index === this.displayCards.length - 1
          })
        }
      }, (item: TripCardModel) => item.id)
    }
    .layoutWeight(1)
    .width('100%')
    .scrollBar(BarState.Off)
  }

  build() {
    Column({ space: 0 }) {
      this.pageHeader()

      if (this.state.permissionTip.length > 0) {
        Text(this.state.permissionTip)
          .fontSize(12)
          .fontColor($r('app.color.amber_deep'))
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 8 })
      }

      if (!this.permissionGranted && this.state.empty) {
        this.permissionBlock()
      } else if (this.state.empty) {
        this.emptyBlock()
      } else {
        this.tripList()
      }
    }
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
