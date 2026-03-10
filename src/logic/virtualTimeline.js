import { randomUUID } from 'node:crypto'

const DEFAULT_CLIP_ID_PREFIX = 'virtual-clip'

function toTimestampMs(rawValue) {
  if (rawValue instanceof Date) {
    return rawValue.getTime()
  }
  if (typeof rawValue === 'number' && Number.isFinite(rawValue)) {
    return rawValue
  }
  const parsed = Date.parse(String(rawValue ?? ''))
  if (Number.isFinite(parsed)) {
    return parsed
  }
  return 0
}

function toDurationMs(segment) {
  if (typeof segment?.durationMs === 'number' && Number.isFinite(segment.durationMs) && segment.durationMs > 0) {
    return segment.durationMs
  }
  if (typeof segment?.duration === 'number' && Number.isFinite(segment.duration) && segment.duration > 0) {
    return Math.round(segment.duration * 1000)
  }
  return 0
}

function clampMs(value, min, max) {
  return Math.min(Math.max(value, min), max)
}

function formatTimecode(ms) {
  const safeMs = Math.max(0, Math.floor(ms))
  const totalSeconds = Math.floor(safeMs / 1000)
  const hours = Math.floor(totalSeconds / 3600)
  const minutes = Math.floor((totalSeconds % 3600) / 60)
  const seconds = totalSeconds % 60
  if (hours > 0) {
    return `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`
  }
  return `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`
}

function buildSourceFiles(segments) {
  const sorted = [...segments]
    .filter(Boolean)
    .sort((a, b) => toTimestampMs(a.startTime) - toTimestampMs(b.startTime))

  const sourceFiles = []
  let cursorMs = 0
  for (const segment of sorted) {
    const durationMs = toDurationMs(segment)
    const fileStartTimeMs = toTimestampMs(segment.startTime)
    const logicalStartMs = cursorMs
    const logicalEndMs = logicalStartMs + durationMs
    sourceFiles.push({
      id: segment.id ?? `${segment.fileName ?? 'segment'}-${logicalStartMs}`,
      filePath: segment.filePath ?? '',
      fileName: segment.fileName ?? '',
      startTime: segment.startTime ?? new Date(fileStartTimeMs),
      startTimeMs: fileStartTimeMs,
      duration: typeof segment.duration === 'number' ? segment.duration : durationMs / 1000,
      durationMs,
      logicalStartMs,
      logicalEndMs
    })
    cursorMs = logicalEndMs
  }
  return sourceFiles
}

function buildBoundaries(sourceFiles) {
  const boundaries = []
  for (let index = 0; index < sourceFiles.length - 1; index += 1) {
    const current = sourceFiles[index]
    const next = sourceFiles[index + 1]
    boundaries.push({
      index,
      logicalTimeMs: current.logicalEndMs,
      previousFileId: current.id,
      nextFileId: next.id
    })
  }
  return boundaries
}

function findSourceFile(sourceFiles, logicalTimeMs) {
  if (sourceFiles.length === 0) {
    return null
  }
  for (const file of sourceFiles) {
    if (logicalTimeMs < file.logicalEndMs) {
      return file
    }
  }
  return sourceFiles[sourceFiles.length - 1]
}

export class VirtualClip {
  constructor({ id, sourceFiles }) {
    this.id = id
    this.sourceFiles = [...sourceFiles]
    this.totalDurationMs = this.sourceFiles.reduce((acc, file) => acc + file.durationMs, 0)
    this.totalDuration = this.totalDurationMs / 1000
    this.boundaries = buildBoundaries(this.sourceFiles)
    this.startTimeMs = this.sourceFiles[0]?.startTimeMs ?? 0
    this.endTimeMs = this.startTimeMs + this.totalDurationMs
  }

  mapTime(logicTimeMs) {
    if (this.sourceFiles.length === 0) {
      return null
    }
    const clampedLogicTimeMs = clampMs(Number(logicTimeMs) || 0, 0, this.totalDurationMs)
    const targetFile = findSourceFile(this.sourceFiles, clampedLogicTimeMs)
    const offsetMs = clampMs(clampedLogicTimeMs - targetFile.logicalStartMs, 0, targetFile.durationMs)
    const boundary = this.boundaries.find(item => item.logicalTimeMs === clampedLogicTimeMs)
    return {
      file: targetFile,
      offsetMs,
      logicalTimeMs: clampedLogicTimeMs,
      atBoundary: Boolean(boundary),
      boundary: boundary ?? null
    }
  }

  toTimecode(logicTimeMs) {
    const mapping = this.mapTime(logicTimeMs)
    return formatTimecode(mapping?.logicalTimeMs ?? 0)
  }

  calculateRange(startMs, endMs) {
    const safeStart = Number(startMs) || 0
    const safeEnd = Number(endMs) || 0
    const rangeStartMs = clampMs(Math.min(safeStart, safeEnd), 0, this.totalDurationMs)
    const rangeEndMs = clampMs(Math.max(safeStart, safeEnd), 0, this.totalDurationMs)
    const durationMs = Math.max(0, rangeEndMs - rangeStartMs)
    const boundaryMarkers = this.boundaries.filter(
      item => item.logicalTimeMs >= rangeStartMs && item.logicalTimeMs <= rangeEndMs
    )
    return {
      startMs: rangeStartMs,
      endMs: rangeEndMs,
      durationMs,
      startTimecode: formatTimecode(rangeStartMs),
      endTimecode: formatTimecode(rangeEndMs),
      durationTimecode: formatTimecode(durationMs),
      startMapping: this.mapTime(rangeStartMs),
      endMapping: this.mapTime(rangeEndMs),
      boundaryMarkers,
      coversBoundary: boundaryMarkers.length > 0
    }
  }

  splitRangeIntoFileSlices(startMs, endMs) {
    const range = this.calculateRange(startMs, endMs)
    if (range.durationMs <= 0 || this.sourceFiles.length === 0) {
      return []
    }
    const slices = []
    for (const file of this.sourceFiles) {
      const sliceStart = Math.max(range.startMs, file.logicalStartMs)
      const sliceEnd = Math.min(range.endMs, file.logicalEndMs)
      if (sliceEnd <= sliceStart) {
        continue
      }
      const inpointMs = sliceStart - file.logicalStartMs
      const outpointMs = sliceEnd - file.logicalStartMs
      slices.push({
        fileId: file.id,
        filePath: file.filePath,
        logicalStartMs: sliceStart,
        logicalEndMs: sliceEnd,
        inpointMs,
        outpointMs,
        durationMs: outpointMs - inpointMs
      })
    }
    return slices
  }
}

export function assembleVirtualClip(segments, options = {}) {
  const sourceFiles = buildSourceFiles(segments)
  const id = options.id ?? `${DEFAULT_CLIP_ID_PREFIX}-${randomUUID()}`
  return new VirtualClip({ id, sourceFiles })
}
