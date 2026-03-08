/**
 * (行程库大脑) 准备行程列表数据。它把复杂的 Trip 对象转换成 UI 容易显示的“卡片数据”（标题、时长、缩略图）。
 */
function formatDate(date) {
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

function formatTime(date) {
  const hour = String(date.getHours()).padStart(2, '0')
  const minute = String(date.getMinutes()).padStart(2, '0')
  const second = String(date.getSeconds()).padStart(2, '0')
  return `${hour}:${minute}:${second}`
}

function toTripCard(trip) {
  const cameraCount = trip.videoTracks.length
  return {
    id: trip.id,
    date: formatDate(trip.startTime),
    timeRange: `${formatTime(trip.startTime)} - ${formatTime(trip.endTime)}`,
    cameraCount,
    duration: trip.duration,
    thumbnailUrl: trip.thumbnailUrl
  }
}

export class TripLibraryViewModel {
  static emptyMessage = '请通过 Huawei Share 分享记录仪视频到手机相册'

  constructor({ passiveImportController }) {
    this.passiveImportController = passiveImportController
    this.state = {
      scanMode: 'passive',
      cards: [],
      empty: true,
      message: TripLibraryViewModel.emptyMessage
    }
  }

  async initialize() {
    const trips = await this.passiveImportController.start()
    this.state.cards = trips.map(toTripCard)
    this.state.empty = this.state.cards.length === 0
    this.state.message = this.state.empty ? TripLibraryViewModel.emptyMessage : ''
    return { ...this.state, cards: [...this.state.cards] }
  }
}
