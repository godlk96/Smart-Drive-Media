import common from '@ohos.app.ability.common'
import window from '@ohos.window'
import { AppIcon, AppIconName } from '../components/AppIcon'
import { EditRecordCard } from '../components/EditRecordCard'
import { LibraryStateModel, TripCardModel } from '../model/AppState'
import { EditRecord } from '../model/EditRecord'
import { debugLog } from '../utils/Logger'
import { formatTripDay, formatTripDuration, getTripStartTime, isTripComplete } from '../utils/TripFormat'
import { HomeViewModel, MyEditsViewState } from '../viewmodel/HomeViewModel'

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
  @StorageProp('statusBarHeight') statusBarHeight: number = 38
  @State private permissionGranted: boolean = false
  @State private hasAutoRequestedPermission: boolean = false
  @State private isLoading: boolean = true
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
  /** 0 = 行程库，1 = 我的剪辑 */
  @State private activeTab: number = 0
  @State private myEdits: MyEditsViewState = {
    records: [],
    isLoading: true,
    errorText: '',
    coverPaths: {},
    orphanIds: [],
    unknownIds: [],
    selectionMode: false,
    selectedRecordIds: []
  }
  @State private deleteConfirmVisible: boolean = false
  @State private deleteCount: number = 0
  @State private toastText: string = ''
  @State private toastVisible: boolean = false
  private toastTimer: number = -1

  aboutToAppear(): void {
    const context = this.getHostContextOrNull()
    if (context !== null) {
      try {
        window.getLastWindow(context, (err, win) => {
          if (!err && win) {
            const area = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM)
            const h = this.getUIContext().px2vp(area.topRect.height)
            if (h > 0) {
              this.statusBarHeight = h
            }
          }
        })
      } catch (_) { }
    }
    this.viewModel.setOnStateChangedListener(() => {
      this.syncViewState()
    })
    this.syncViewState()
    if (!this.permissionGranted && !this.hasAutoRequestedPermission) {
      this.isLoading = true
      void this.requestMediaPermissionAndRefresh(false)
    } else {
      void this.refreshState()
    }
  }

  aboutToDisappear(): void {
    this.viewModel.setOnStateChangedListener(undefined)
  }

  /**
   * 从剪辑页返回时刷新「我的剪辑」—— 那边可能刚导出一条新记录，
   * 也可能覆盖了旧记录，列表不及时更新用户会以为没生效。
   */
  onPageShow(): void {
    if (this.activeTab === 1) {
      void this.refreshMyEdits()
    }
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
    this.isLoading = state.isLoading
    this.selectionMode = state.selectionMode
    this.selectedTripIds = state.selectedTripIds
    this.state = state.libraryState
    // 列表只反转一次并缓存：ForEach 里要按相邻两项比较日期，不能每次重算
    this.displayCards = [...state.libraryState.cards].reverse()
    // 「我的剪辑」同样必须走 @State：ForEach 只认 @State/@Prop 的变化，
    // 直接在 build() 里读 viewModel 拿到的数组不会随数据刷新。
    this.myEdits = this.viewModel.getMyEditsState()
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
    return { radius: 8, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 2 }
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

  // ---------------- 我的剪辑 ----------------

  private showToast(message: string): void {
    this.toastText = message
    this.toastVisible = true
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer)
    }
    this.toastTimer = setTimeout(() => {
      this.toastVisible = false
      this.toastTimer = -1
    }, 2000)
  }

  /**
   * 切 Tab。
   *
   * 「我的剪辑」每次切进来都**无条件重读**，不能只读一次：用户可能刚在
   * 「行程库」里导出一条新作品，`myEditsLoaded` 还是 true，缓存下来的列表
   * 会一直缺最新那条，直到重启 App。重读只是一次偏好读取，代价可忽略。
   */
  private switchTab(index: number): void {
    if (this.activeTab === index) {
      return
    }
    this.activeTab = index
    if (index === 1) {
      void this.refreshMyEdits()
    }
  }

  private async refreshMyEdits(): Promise<void> {
    const context = this.getHostContextOrNull()
    if (context === null) {
      return
    }
    try {
      await this.viewModel.refreshMyEdits(context)
      this.syncViewState()
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('首页', `刷新我的剪辑失败：${message}`)
    }
  }

  private isRecordSelected(recordId: string): boolean {
    return this.myEdits.selectedRecordIds.some((id: string) => id === recordId)
  }

  private coverPathOf(record: EditRecord): string {
    const path = this.myEdits.coverPaths[record.id]
    return path === undefined ? '' : path
  }

  /** 成片首帧取不到时回落到该行程在行程库里的封面，保证卡片永远有东西可画。 */
  private fallbackCoverOf(record: EditRecord): string {
    for (let i = 0; i < this.displayCards.length; i++) {
      const card = this.displayCards[i]
      if (card.id === record.tripId) {
        return card.previewFrameUri
      }
    }
    return ''
  }

  /**
   * ForEach 的 key 必须把「选中态 / 多选态 / 孤儿态」也编进去：
   * 这些变化不会改变记录本身，key 不变 ForEach 就不会重建子组件，
   * 卡片上的勾选和对 ▶ 的置灰就永远不更新。
   */
  private recordCardKey(record: EditRecord): string {
    const selected = this.isRecordSelected(record.id) ? '1' : '0'
    const mode = this.myEdits.selectionMode ? '1' : '0'
    const orphan = this.viewModel.isRecordOrphan(record.id) ? '1' : '0'
    const unknown = this.viewModel.isRecordOrphanUnknown(record.id) ? '1' : '0'
    return `${record.id}_${this.coverPathOf(record)}_${selected}${mode}${orphan}${unknown}`
  }

  private handleRecordClick(record: EditRecord): void {
    if (this.myEdits.selectionMode) {
      this.viewModel.toggleRecordSelection(record.id)
      this.syncViewState()
      return
    }
    this.openRecordEditor(record)
  }

  private openRecordEditor(record: EditRecord): void {
    debugLog('首页', `从我的剪辑重新剪辑，记录=${record.id}`)
    const route = this.viewModel.openEditorFromRecordRoute(record)
    try {
      this.getUIContext().getRouter().pushUrl(route)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('首页', `从记录进入剪辑失败：${message}`)
    }
  }

  private async handleRecordPlay(record: EditRecord): Promise<void> {
    const context = this.getHostContextOrNull()
    if (context === null) {
      return
    }
    const message = await this.viewModel.playRecord(record, context)
    if (message.length > 0) {
      this.showToast(message)
    }
  }

  private handleRecordToggle(record: EditRecord): void {
    this.viewModel.toggleRecordSelection(record.id)
    this.syncViewState()
  }

  private toggleRecordSelectionMode(): void {
    this.viewModel.toggleRecordSelectionMode()
    this.syncViewState()
  }

  private askDeleteSelected(): void {
    const count = this.myEdits.selectedRecordIds.length
    if (count === 0) {
      return
    }
    this.deleteCount = count
    this.deleteConfirmVisible = true
  }

  private async confirmDeleteSelected(): Promise<void> {
    this.deleteConfirmVisible = false
    const ok = await this.viewModel.deleteSelectedRecords()
    this.syncViewState()
    if (!ok) {
      this.showToast('移除失败，请重试')
    }
  }

  @Builder
  pageHeader() {
    Row({ space: 10 }) {
      Text(this.activeTab === 0 ? this.state.title : '我的剪辑')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)

      if (this.activeTab === 0) {
        Text(this.getSummaryText())
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
      }

      if (this.activeTab === 0) {
        if (this.canShowMergeButton()) {
          Button('合并剪辑')
            .height(38)
            .padding({ left: 17, right: 17 })
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.card_bg'))
            .backgroundColor($r('app.color.amber'))
            .borderRadius(10)
            .onClick(() => this.openMergedEditor())
        }

        Button(this.selectionMode ? '取消' : '多选')
          .height(38)
          .padding({ left: 17, right: 17 })
          .fontSize(14)
          .fontColor(this.selectionMode ? $r('app.color.card_bg') : $r('app.color.text_primary'))
          .backgroundColor(this.selectionMode ? $r('app.color.ink') : $r('app.color.ed_surface'))
          .border({
            width: 1,
            color: this.selectionMode ? $r('app.color.ink') : $r('app.color.ed_line')
          })
          .borderRadius(10)
          .onClick(() => this.toggleSelectionMode())
      } else {
        if (this.myEdits.selectionMode && this.myEdits.selectedRecordIds.length >= 1) {
          Button(`移除 ${this.myEdits.selectedRecordIds.length}`)
            .height(38)
            .padding({ left: 17, right: 17 })
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.card_bg'))
            .backgroundColor($r('app.color.amber'))
            .borderRadius(10)
            .onClick(() => this.askDeleteSelected())
        } else {
          Button(this.myEdits.selectionMode ? '取消' : '选择')
            .height(38)
            .padding({ left: 17, right: 17 })
            .fontSize(14)
            .fontColor(this.myEdits.selectionMode ? $r('app.color.card_bg') : $r('app.color.text_primary'))
            .backgroundColor(this.myEdits.selectionMode ? $r('app.color.ink') : $r('app.color.ed_surface'))
            .border({
              width: 1,
              color: this.myEdits.selectionMode ? $r('app.color.ink') : $r('app.color.ed_line')
            })
            .borderRadius(10)
            .onClick(() => this.toggleRecordSelectionMode())
        }
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      left: 16,
      right: 16,
      top: (this.statusBarHeight > 0 ? this.statusBarHeight : 38) + 10,
      bottom: 10
    })
  }

  @Builder
  tabItem(index: number, label: string) {
    Column({ space: 0 }) {
      Text(label)
        .fontSize(15)
        .fontWeight(this.activeTab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.activeTab === index ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
      Row()
        .width(18)
        .height(2)
        .borderRadius(1)
        .backgroundColor(this.activeTab === index ? $r('app.color.amber') : Color.Transparent)
        .margin({ top: 6 })
    }
    .padding({ right: 22, top: 2 })
    .alignItems(HorizontalAlign.Start)
    .onClick(() => this.switchTab(index))
  }

  @Builder
  tabBar() {
    Row({ space: 0 }) {
      this.tabItem(0, '行程库')
      this.tabItem(1, '我的剪辑')
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 10 })
  }

  @Builder
  tripRow(ctx: TripRowContext) {
    Column({ space: 0 }) {
      if (ctx.dayStart) {
        Row({ space: 8 }) {
          Text(formatTripDay(ctx.card.title))
            .fontSize(11.5)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 8, right: 8, top: 2.5, bottom: 2.5 })
            .backgroundColor($r('app.color.ed_surface'))
            .borderRadius(6)
            .border({ width: 1, color: $r('app.color.ed_line') })
            .shadow({ radius: 4, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 1 })
          Row()
            .height(1)
            .backgroundColor($r('app.color.ed_line'))
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 14, right: 14, top: 14, bottom: 8 })
      }

      Row({ space: 0 }) {
        // 时间轴轨：时间右对齐贴住竖线，导航双环状态点压在竖线上
        Stack({ alignContent: Alignment.TopEnd }) {
          Text(getTripStartTime(ctx.card))
            .fontSize(13.5)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .textAlign(TextAlign.End)
            .maxLines(1)
            .width('100%')
            .padding({ right: 13, top: 2 })

          // 导航双环光斑：外环淡琥珀柔光圈，内圈实心琥珀橙点
          Stack({ alignContent: Alignment.Center }) {
            Row()
              .width(5)
              .height(5)
              .borderRadius(2.5)
              .backgroundColor(isTripComplete(ctx.card) ? $r('app.color.amber') : $r('app.color.text_disabled'))
          }
          .width(11)
          .height(11)
          .borderRadius(5.5)
          .backgroundColor(isTripComplete(ctx.card) ? $r('app.color.amber_soft') : $r('app.color.ed_bg'))
          .border({
            width: 1.5,
            color: isTripComplete(ctx.card) ? $r('app.color.chip_amber_border') : $r('app.color.text_disabled')
          })
          .offset({ x: 5.5, y: 5 })
        }
        .width(RAIL_WIDTH)
        .zIndex(1)

        // 封面容器：外层 2.5vp 纯白双层高光边框（Double-Bezel），内嵌 16:9 视频画面
        Column({ space: 0 }) {
          Column() {
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
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.amber'))
                  .backgroundColor($r('app.color.amber_soft'))
                  .border({ width: 1, color: $r('app.color.chip_amber_border') })
                  .borderRadius(5)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .margin({ left: 7, top: 7 })
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
            .borderRadius(9)
            .clip(true)
            .backgroundColor($r('app.color.stage_bg'))
            .border({ width: 1, color: $r('app.color.stage_divider') })
          }
          .width('100%')
          .padding(2.5)
          .backgroundColor($r('app.color.ed_surface'))
          .borderRadius(12)
          .border({
            width: this.isTripSelected(ctx.card.id) ? 1.5 : 1,
            color: this.isTripSelected(ctx.card.id) ? $r('app.color.amber') : $r('app.color.ed_line')
          })
          .shadow(this.cardShadow(this.isTripSelected(ctx.card.id)))
          .onClick(() => this.handleCardClick(ctx.card))
        }
        .layoutWeight(1)
        .padding({ left: RAIL_GAP, bottom: ctx.last ? ROW_GAP + 28 : ROW_GAP })
        .border({
          width: { left: 1 },
          color: ctx.last ? $r('app.color.ed_bg') : $r('app.color.ed_line')
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
  loadingBlock() {
    Column({ space: 14 }) {
      LoadingProgress()
        .width(36)
        .height(36)
        .color($r('app.color.amber'))
      Text('正在扫描行车记录视频...')
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
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
      Text(this.state.emptyText.length > 0 ? this.state.emptyText : '未发现行车记录仪视频')
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
      }, (item: TripCardModel) => `${item.id}_${item.previewFrameUri}`)
    }
    .layoutWeight(1)
    .width('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    .scrollBar(BarState.Off)
  }

  // ---------------- 我的剪辑：列表 / 空态 / 错误态 ----------------

  @Builder
  myEditsList() {
    List({ space: 12 }) {
      ForEach(this.myEdits.records, (item: EditRecord) => {
        ListItem() {
          EditRecordCard({
            record: item,
            selected: this.isRecordSelected(item.id),
            selectionMode: this.myEdits.selectionMode,
            orphan: this.viewModel.isRecordOrphan(item.id),
            coverPath: this.coverPathOf(item),
            fallbackCoverUri: this.fallbackCoverOf(item),
            onOpen: () => {
              this.handleRecordClick(item)
            },
            onPlay: () => {
              void this.handleRecordPlay(item)
            },
            onToggleSelect: () => {
              this.handleRecordToggle(item)
            }
          })
        }
      }, (item: EditRecord) => this.recordCardKey(item))
    }
    .layoutWeight(1)
    .width('100%')
    .padding({ left: 16, right: 16, top: 4 })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    .scrollBar(BarState.Off)
  }

  @Builder
  myEditsEmptyBlock() {
    Column({ space: 12 }) {
      Text('还没有剪辑过的视频')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text('在「行程库」里挑一趟行程剪辑并导出，这里就会留下记录。')
        .fontSize(13)
        .fontColor($r('app.color.text_tertiary'))
        .textAlign(TextAlign.Center)
      Button('去行程库')
        .height(40)
        .padding({ left: 20, right: 20 })
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.card_bg'))
        .backgroundColor($r('app.color.ink'))
        .borderRadius(8)
        .onClick(() => {
          this.activeTab = 0
        })
        .margin({ top: 4 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 24, right: 24 })
  }

  @Builder
  myEditsErrorBlock() {
    Column({ space: 12 }) {
      Text(this.myEdits.errorText)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
      Button('重试')
        .height(38)
        .padding({ left: 18, right: 18 })
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor($r('app.color.ed_surface'))
        .border({ width: 1, color: $r('app.color.ed_line') })
        .borderRadius(8)
        .onClick(() => {
          void this.refreshMyEdits()
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 24, right: 24 })
  }

  @Builder
  myEditsLoadingBlock() {
    Column({ space: 14 }) {
      LoadingProgress()
        .width(32)
        .height(32)
        .color($r('app.color.amber'))
      Text('正在读取剪辑记录...')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  myEditsBlock() {
    if (this.myEdits.isLoading) {
      this.myEditsLoadingBlock()
    } else if (this.myEdits.errorText.length > 0) {
      this.myEditsErrorBlock()
    } else if (this.myEdits.records.length === 0) {
      this.myEditsEmptyBlock()
    } else {
      this.myEditsList()
    }
  }

  /**
   * 删除确认。文案必须说清「相册里的视频不会被删」——
   * 我们只删记录，删文件需要受控权限，做不到也不该让用户误以为做到了。
   */
  @Builder
  deleteConfirmModal() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.overlay_veil'))
        .onClick(() => {
          this.deleteConfirmVisible = false
        })

      Column({ space: 10 }) {
        Text(`移除 ${this.deleteCount} 条记录？`)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text('只会从「我的剪辑」列表移除，相册里的视频不会被删掉。')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
          .margin({ bottom: 4 })
        Row({ space: 10 }) {
          Button('取消')
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.ed_surface'))
            .border({ width: 1, color: $r('app.color.ed_line') })
            .borderRadius(10)
            .onClick(() => {
              this.deleteConfirmVisible = false
            })
          Button('移除')
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.card_bg'))
            .backgroundColor($r('app.color.ink'))
            .borderRadius(10)
            .onClick(() => {
              void this.confirmDeleteSelected()
            })
        }
        .width('100%')
      }
      .width('82%')
      .padding(18)
      .backgroundColor($r('app.color.card_bg'))
      .borderRadius(16)
      .border({ width: 1, color: $r('app.color.ed_line') })
      .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  toastBubble() {
    Column() {
      Text(this.toastText)
        .fontSize(13)
        .fontColor($r('app.color.overlay_text'))
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
        .backgroundColor($r('app.color.overlay_veil'))
        .borderRadius(10)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .alignItems(HorizontalAlign.Center)
    .padding({ bottom: 90 })
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  pageContent() {
    Column({ space: 0 }) {
      this.pageHeader()
      this.tabBar()

      if (this.activeTab === 0) {
        if (this.state.permissionTip.length > 0) {
          Text(this.state.permissionTip)
            .fontSize(12)
            .fontColor($r('app.color.amber_deep'))
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 8 })
        }

        if (this.isLoading) {
          this.loadingBlock()
        } else if (!this.permissionGranted && this.state.empty) {
          this.permissionBlock()
        } else if (this.state.empty) {
          this.emptyBlock()
        } else {
          this.tripList()
        }
      } else {
        this.myEditsBlock()
      }
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.pageContent()

      if (this.deleteConfirmVisible) {
        this.deleteConfirmModal()
      }

      if (this.toastVisible) {
        this.toastBubble()
      }
    }
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.ed_bg'))
  }
}
