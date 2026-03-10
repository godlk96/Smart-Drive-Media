const DEFAULT_PRELOAD_WINDOW_MS = 5_000

function createSlot(id) {
  return {
    id,
    loadedFileId: null,
    loadedFilePath: '',
    offsetMs: 0,
    status: 'idle'
  }
}

function cloneSlot(slot) {
  return {
    id: slot.id,
    loadedFileId: slot.loadedFileId,
    loadedFilePath: slot.loadedFilePath,
    offsetMs: slot.offsetMs,
    status: slot.status
  }
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max)
}

function findNextFile(sourceFiles, currentFileId) {
  const index = sourceFiles.findIndex(file => file.id === currentFileId)
  if (index < 0) {
    return null
  }
  return sourceFiles[index + 1] ?? null
}

function loadFileToSlot(slot, file, offsetMs, status) {
  if (!file) {
    slot.loadedFileId = null
    slot.loadedFilePath = ''
    slot.offsetMs = 0
    slot.status = 'idle'
    return
  }
  slot.loadedFileId = file.id
  slot.loadedFilePath = file.filePath
  slot.offsetMs = clamp(Math.floor(Number(offsetMs) || 0), 0, file.durationMs)
  slot.status = status
}

function buildIdleState() {
  const playerA = createSlot('A')
  const playerB = createSlot('B')
  return {
    activePlayerId: 'A',
    activeFileId: null,
    playheadMs: 0,
    preloadedNextFileId: null,
    swapCount: 0,
    players: [playerA, playerB]
  }
}

export class SeamlessPlayer {
  constructor({ preloadWindowMs = DEFAULT_PRELOAD_WINDOW_MS } = {}) {
    this.preloadWindowMs = Math.max(0, Number(preloadWindowMs) || DEFAULT_PRELOAD_WINDOW_MS)
    this.state = buildIdleState()
    this.sourceFiles = []
  }

  loadVirtualClip(virtualClip) {
    this.sourceFiles = [...(virtualClip?.sourceFiles ?? [])]
    this.state = buildIdleState()
    if (this.sourceFiles.length === 0) {
      return this.getState()
    }
    const firstFile = this.sourceFiles[0]
    const nextFile = this.sourceFiles[1] ?? null
    const activeSlot = this.state.players[0]
    const standbySlot = this.state.players[1]
    loadFileToSlot(activeSlot, firstFile, 0, 'active')
    loadFileToSlot(standbySlot, nextFile, 0, nextFile ? 'standby' : 'idle')
    this.state.activeFileId = firstFile.id
    this.state.preloadedNextFileId = nextFile?.id ?? null
    return this.getState()
  }

  syncToMapping(mapping) {
    if (!mapping || this.sourceFiles.length === 0) {
      return this.getState()
    }
    const targetFile = mapping.file
    const targetFileId = targetFile?.id ?? null
    if (!targetFileId) {
      return this.getState()
    }

    const activeSlot = this.getActiveSlot()
    const standbySlot = this.getStandbySlot()
    if (activeSlot.loadedFileId !== targetFileId) {
      if (standbySlot.loadedFileId === targetFileId) {
        this.state.activePlayerId = standbySlot.id
        standbySlot.status = 'active'
        activeSlot.status = activeSlot.loadedFileId ? 'standby' : 'idle'
        this.state.swapCount += 1
      } else {
        loadFileToSlot(activeSlot, targetFile, mapping.offsetMs, 'active')
      }
    }

    const nextFile = findNextFile(this.sourceFiles, targetFileId)
    const refreshedActive = this.getActiveSlot()
    const refreshedStandby = this.getStandbySlot()
    const remainingMs = Math.max(0, targetFile.durationMs - (Number(mapping.offsetMs) || 0))
    const shouldPreloadNext = Boolean(nextFile) && remainingMs <= this.preloadWindowMs
    if (nextFile && (shouldPreloadNext || refreshedStandby.loadedFileId !== nextFile.id)) {
      loadFileToSlot(refreshedStandby, nextFile, 0, 'standby')
    } else if (!nextFile) {
      loadFileToSlot(refreshedStandby, null, 0, 'idle')
    }

    loadFileToSlot(refreshedActive, targetFile, mapping.offsetMs, 'active')
    this.state.activeFileId = targetFileId
    this.state.playheadMs = Math.max(0, Number(mapping.logicalTimeMs) || 0)
    this.state.preloadedNextFileId = nextFile?.id ?? null
    return this.getState()
  }

  getActiveSlot() {
    return this.state.players.find(item => item.id === this.state.activePlayerId) ?? this.state.players[0]
  }

  getStandbySlot() {
    return this.state.players.find(item => item.id !== this.state.activePlayerId) ?? this.state.players[1]
  }

  getState() {
    return {
      activePlayerId: this.state.activePlayerId,
      activeFileId: this.state.activeFileId,
      playheadMs: this.state.playheadMs,
      preloadedNextFileId: this.state.preloadedNextFileId,
      swapCount: this.state.swapCount,
      players: this.state.players.map(cloneSlot)
    }
  }
}
