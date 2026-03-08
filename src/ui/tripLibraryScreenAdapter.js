/**
 * (列表适配器) 协调 ViewModel 和 Router，处理列表页的初始化和点击事件。
 */
function mapCardItem(card) {
  return {
    id: card.id,
    title: card.date,
    subtitle: `${card.timeRange} · ${card.cameraCount} 视角`,
    durationText: `${card.duration}s`,
    thumbnailUrl: card.thumbnailUrl
  }
}

export class TripLibraryScreenAdapter {
  constructor({ viewModel, router }) {
    this.viewModel = viewModel
    this.router = router
    this.state = {
      title: '行程库',
      cards: [],
      empty: true,
      emptyText: '',
      scanMode: 'passive'
    }
  }

  async initialize() {
    const vmState = await this.viewModel.initialize()
    this.state = {
      title: '行程库',
      cards: vmState.cards.map(mapCardItem),
      empty: vmState.empty,
      emptyText: vmState.message,
      scanMode: vmState.scanMode
    }
    return this.getState()
  }

  openTrip(tripId) {
    return this.router.navigate('editor', { tripId })
  }

  getState() {
    return {
      ...this.state,
      cards: [...this.state.cards],
      route: this.router.getState()
    }
  }
}
