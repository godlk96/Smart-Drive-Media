import { EditorStateModel } from '../model/AppState'
import { EditorConfig } from '../model/EditorConfig'
import { resolveTemplateDefinition } from '../model/Models'

export interface EditorTranslationResult {
  state: EditorStateModel
  config: EditorConfig
}

export class EditorTranslationEngine {
  translateState(state: EditorStateModel): EditorTranslationResult {
    const translatedState: EditorStateModel = this.cloneEditorState(state)
    translatedState.totalDurationSec = Math.max(0, translatedState.totalDurationSec)
    translatedState.playheadSec = Math.max(0, Math.min(translatedState.playheadSec, translatedState.totalDurationSec))
    translatedState.selectionStartSec = Math.max(0, Math.min(translatedState.selectionStartSec, translatedState.totalDurationSec))
    translatedState.selectionEndSec = Math.max(translatedState.selectionStartSec,
      Math.min(translatedState.selectionEndSec, translatedState.totalDurationSec))
    const config = this.buildConfig(translatedState)
    return {
      state: translatedState,
      config
    }
  }

  translatePlayheadText(state: EditorStateModel, playheadText: string): EditorTranslationResult {
    const translated = this.translateState(state)
    translated.state.playheadText = playheadText
    return translated
  }

  private buildConfig(state: EditorStateModel): EditorConfig {
    const config = new EditorConfig()
    const template = resolveTemplateDefinition(state.activeTemplateId)
    if (template.templateId === 'T1') {
      config.previewAspectRatio = 1920 / 2160
    } else if (template.templateId === 'T2') {
      config.previewAspectRatio = 1920 / 1620
    } else if (template.templateId === 'T3' || template.templateId === 'T4') {
      config.previewAspectRatio = 3840 / 1080
    } else {
      config.previewAspectRatio = 16 / 9
    }
    const normalized = state.speedLabel.replace('X', '')
    const parsed = Number(normalized)
    config.playbackRate = parsed >= 1.0 && parsed <= 4 ? parsed : 1.0
    config.hasPreviewSource = state.previewSlots.some((slot) => slot.uri.length > 0)
    return config
  }

  private cloneEditorState(state: EditorStateModel): EditorStateModel {
    const cloned: EditorStateModel = {
      tripId: state.tripId,
      tripTitle: state.tripTitle,
      timeRange: state.timeRange,
      previewUri: state.previewUri,
      previewCamera: state.previewCamera,
      playheadSec: state.playheadSec,
      canPlayPrev: state.canPlayPrev,
      canPlayNext: state.canPlayNext,
      currentClipIndex: state.currentClipIndex,
      currentClipTotal: state.currentClipTotal,
      playheadText: state.playheadText,
      totalDurationSec: state.totalDurationSec,
      timeline: state.timeline.slice(),
      layers: state.layers.slice(),
      selectionStartSec: state.selectionStartSec,
      selectionEndSec: state.selectionEndSec,
      boundaryMarkers: state.boundaryMarkers.slice(),
      templateCards: state.templateCards.slice(),
      previewSlots: state.previewSlots.slice(),
      activeTemplateId: state.activeTemplateId,
      drawerExpanded: state.drawerExpanded,
      speedLabel: state.speedLabel,
      muted: state.muted,
      watermarkEnabled: state.watermarkEnabled,
      hideSpeed: state.hideSpeed,
      hideGps: state.hideGps,
      hideVin: state.hideVin,
      exportStatusText: state.exportStatusText
    }
    return cloned
  }
}

export const sharedEditorTranslationEngine = new EditorTranslationEngine()
