import { EditorStateModel } from './AppState'
import { TripGroup } from './TripGroup'

export interface EditorPrivacyConfig {
  maskSpeed: boolean
  maskTime: boolean
  maskGps: boolean
  maskVin: boolean
}

export interface EditorExportConfig {
  speedLabel: string
  muted: boolean
  watermarkEnabled: boolean
}

export interface EditorState {
  tripId: string
  currentTrip: TripGroup
  selectedTemplate: string
  selectionStartSec: number
  selectionEndSec: number
  playheadSec: number
  exportConfig: EditorExportConfig
  privacyConfig: EditorPrivacyConfig
}

export function createEmptyEditorState(): EditorState {
  return {
    tripId: '',
    currentTrip: new TripGroup(),
    selectedTemplate: 'T2',
    selectionStartSec: 0,
    selectionEndSec: 60,
    playheadSec: 0,
    exportConfig: {
      speedLabel: '1.0X',
      muted: false,
      watermarkEnabled: true
    },
    privacyConfig: {
      maskSpeed: true,
      maskTime: true,
      maskGps: true,
      maskVin: true
    }
  }
}

export function domainEditorStateFromViewState(viewState: EditorStateModel, trip: TripGroup): EditorState {
  return {
    tripId: viewState.tripId,
    currentTrip: trip,
    selectedTemplate: viewState.activeTemplateId,
    selectionStartSec: viewState.selectionStartSec,
    selectionEndSec: viewState.selectionEndSec,
    playheadSec: viewState.playheadSec,
    exportConfig: {
      speedLabel: viewState.speedLabel,
      muted: viewState.muted,
      watermarkEnabled: viewState.watermarkEnabled
    },
    privacyConfig: {
      maskSpeed: viewState.hideSpeed,
      maskTime: viewState.hideGps,
      maskGps: viewState.hideGps,
      maskVin: viewState.hideVin
    }
  }
}
