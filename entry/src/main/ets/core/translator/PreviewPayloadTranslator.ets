import { EditorStateModel, PreviewSlotModel } from '../../model/AppState'
import { Translator } from './Translator'

export interface PreviewPayload {
  tripId: string
  templateId: string
  playheadMs: number
  speedLabel: string
  muted: boolean
  slots: Array<PreviewSlotModel>
}

export class PreviewPayloadTranslator implements Translator<EditorStateModel, PreviewPayload> {
  private cloneSlot(slot: PreviewSlotModel): PreviewSlotModel {
    const next: PreviewSlotModel = {
      id: slot.id,
      camera: slot.camera,
      uri: slot.uri,
      nextUri: slot.nextUri,
      x: slot.x,
      y: slot.y,
      width: slot.width,
      height: slot.height
    }
    return next
  }

  translate(source: EditorStateModel): PreviewPayload {
    return {
      tripId: source.tripId,
      templateId: source.activeTemplateId,
      playheadMs: Math.floor(source.playheadSec * 1000),
      speedLabel: source.speedLabel,
      muted: source.muted,
      slots: source.previewSlots.map((slot: PreviewSlotModel) => this.cloneSlot(slot))
    }
  }
}
