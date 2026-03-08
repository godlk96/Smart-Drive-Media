/**
 * (翻译官) 使用正则表达式解析文件名（如 DVR_2024...Front.mp4），提取日期、时间和摄像头位置。
 */
import path from 'node:path'
import { normalizeCameraPosition } from '../model/types.js'

const DVR_REGEX = /^DVR_LoopRecording_(\d{4}-\d{2}-\d{2})_(\d{2}-\d{2}-\d{2})_(.+)\.(mp4|ts|mov)$/i

export function parseDvrFile(filePath, durationSec = 60) {
  const fileName = path.basename(filePath)
  const match = fileName.match(DVR_REGEX)
  if (!match) {
    return null
  }

  const [, datePart, timePart, cameraRaw] = match
  const [year, month, day] = datePart.split('-').map(Number)
  const [hour, minute, second] = timePart.split('-').map(Number)
  const startTime = new Date(year, month - 1, day, hour, minute, second)
  if (Number.isNaN(startTime.getTime())) {
    return null
  }

  return {
    filePath,
    fileName,
    cameraPosition: normalizeCameraPosition(cameraRaw),
    startTime,
    duration: Number(durationSec) > 0 ? Number(durationSec) : 60
  }
}

export function isDvrCandidate(filePath) {
  const fileName = path.basename(filePath)
  return DVR_REGEX.test(fileName)
}
