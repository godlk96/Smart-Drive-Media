/**
 * (信号塔) 实现了一种简单的“发布-订阅”机制，当数据变化时通知 UI 刷新。
 */
function createSignal(getState) {
  const listeners = new Set()
  return {
    emit() {
      const state = getState()
      for (const listener of listeners) {
        listener(state)
      }
      return state
    },
    subscribe(listener) {
      listeners.add(listener)
      return () => listeners.delete(listener)
    }
  }
}

export function bindLibraryScreen(adapter) {
  const signal = createSignal(() => adapter.getState())
  return {
    async initialize() {
      await adapter.initialize()
      return signal.emit()
    },
    openTrip(tripId) {
      adapter.openTrip(tripId)
      return signal.emit()
    },
    getState() {
      return adapter.getState()
    },
    subscribe(listener) {
      return signal.subscribe(listener)
    }
  }
}

export function bindEditorScreen(adapter) {
  const signal = createSignal(() => adapter.getState())
  return {
    loadTrip(trip) {
      adapter.loadTrip(trip)
      return signal.emit()
    },
    setOrientation(orientation) {
      adapter.setOrientation(orientation)
      return signal.emit()
    },
    seekTo(positionMs) {
      adapter.seekTo(positionMs)
      return signal.emit()
    },
    syncToMaster(slaveTimes) {
      adapter.syncToMaster(slaveTimes)
      return signal.emit()
    },
    updateSelectionRange(startMs, endMs) {
      adapter.updateSelectionRange(startMs, endMs)
      return signal.emit()
    },
    selectTemplate(templateId) {
      adapter.selectTemplate(templateId)
      return signal.emit()
    },
    setDrawerExpanded(expanded) {
      adapter.setDrawerExpanded(expanded)
      return signal.emit()
    },
    cycleSpeed() {
      adapter.cycleSpeed()
      return signal.emit()
    },
    toggleMuted() {
      adapter.toggleMuted()
      return signal.emit()
    },
    toggleWatermark() {
      adapter.toggleWatermark()
      return signal.emit()
    },
    setControlDeck(nextControlDeck) {
      adapter.setControlDeck(nextControlDeck)
      return signal.emit()
    },
    setPrivacyConfig(nextPrivacyConfig) {
      adapter.setPrivacyConfig(nextPrivacyConfig)
      return signal.emit()
    },
    toggleHideSpeed() {
      adapter.toggleHideSpeed()
      return signal.emit()
    },
    toggleHideVin() {
      adapter.toggleHideVin()
      return signal.emit()
    },
    toggleHideGps() {
      adapter.toggleHideGps()
      return signal.emit()
    },
    toggleCinematicCrop() {
      adapter.toggleCinematicCrop()
      return signal.emit()
    },
    startExport(outputPath) {
      adapter.startExport(outputPath)
      return signal.emit()
    },
    updateExportProgress(progress) {
      adapter.updateExportProgress(progress)
      return signal.emit()
    },
    finishExportSuccess() {
      adapter.finishExportSuccess()
      return signal.emit()
    },
    finishExportFail(message) {
      adapter.finishExportFail(message)
      return signal.emit()
    },
    backToLibrary() {
      adapter.backToLibrary()
      return signal.emit()
    },
    getState() {
      return adapter.getState()
    },
    subscribe(listener) {
      return signal.subscribe(listener)
    }
  }
}
