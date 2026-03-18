import { EditorStateModel } from '../../model/AppState'
import { ExportSnapshot, createEditorStateFromSnapshot, deepCloneExportSnapshot } from '../../model/Models'
import { TripSnapshot } from '../../model/TripModels'
import { Translator } from './Translator'

export interface ExportTranslationInput {
  tripSnapshot?: TripSnapshot
  editorState: EditorStateModel
  sessionId: string
}

export class ExportPayloadTranslator implements Translator<ExportTranslationInput, ExportSnapshot | undefined> {
  translate(source: ExportTranslationInput): ExportSnapshot | undefined {
    if (!source.tripSnapshot) {
      return undefined
    }
    const draft = createEditorStateFromSnapshot(
      source.tripSnapshot,
      source.sessionId,
      source.editorState.activeTemplateId,
      source.editorState.speedLabel,
      source.editorState.muted,
      source.editorState.watermarkEnabled,
      source.editorState.hideSpeed,
      source.editorState.hideGps,
      source.editorState.hideVin,
      source.editorState.drawerExpanded,
      source.editorState.exportStatusText
    )
    const startMs = Math.floor(source.editorState.selectionStartSec * 1000)
    const endMs = Math.floor(source.editorState.selectionEndSec * 1000)
    const playheadMs = Math.floor(source.editorState.playheadSec * 1000)
    draft.playback.rangeStartMs = startMs
    draft.playback.rangeEndMs = endMs
    draft.playback.playheadMs = Math.max(startMs, Math.min(playheadMs, endMs))
    return deepCloneExportSnapshot(draft)
  }
}
