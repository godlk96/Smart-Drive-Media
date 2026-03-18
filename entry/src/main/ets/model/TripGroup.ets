import { TripCardModel } from './AppState'
import { VideoFile } from './VideoFile'

export class TripGroup {
  id: string = ''
  title: string = ''
  subtitle: string = ''
  durationSec: number = 0
  previewUri: string = ''
  previewFrameUri: string = ''
  previewCamera: string = ''
  videos: Array<VideoFile> = []
}

export function tripGroupFromCard(card: TripCardModel): TripGroup {
  const group = new TripGroup()
  group.id = card.id
  group.title = card.title
  group.subtitle = card.subtitle
  group.durationSec = card.durationSec
  group.previewUri = card.previewUri
  group.previewFrameUri = card.previewFrameUri
  group.previewCamera = card.previewCamera
  return group
}
