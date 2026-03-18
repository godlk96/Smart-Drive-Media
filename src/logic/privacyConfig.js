/**
 * (隐私顾问) 定义隐私保护策略（如：是否隐藏车速、VIN 码），并计算遮挡区域的坐标。
 */
export function createDefaultPrivacyConfig() {
  return {
    hideSpeed: true,
    hideVin: true,
    hideGps: true,
    mode: 'overlay',
    cinematicCrop: false
  }
}

function clampCropRatio(value) {
  const ratio = Number(value)
  if (!Number.isFinite(ratio)) {
    return 0.85
  }
  return Math.min(1, Math.max(0.1, ratio))
}

export function buildPrivacyPlan(config = {}, cropRatio = 0.85) {
  const hideSpeed = Boolean(config.hideSpeed)
  const hideVin = Boolean(config.hideVin)
  const hideGps = Boolean(config.hideGps)
  const mode = config.mode === 'delogo' ? 'delogo' : 'overlay'
  const cinematicCrop = Boolean(config.cinematicCrop)

  const overlayMasks = []
  if (hideSpeed) {
    overlayMasks.push({ key: 'speed', x: 0.05, y: 0.9, w: 0.12, h: 0.08 })
  }
  if (hideVin) {
    overlayMasks.push({ key: 'vin', x: 0.28, y: 0.9, w: 0.24, h: 0.08 })
  }
  if (hideGps) {
    overlayMasks.push({ key: 'time', x: 0.58, y: 0.9, w: 0.34, h: 0.08 })
  }

  const safeCropRatio = clampCropRatio(cropRatio)
  const cropExpression = cinematicCrop
    ? 'crop=in_w:in_w*9/21:0:0'
    : `crop=in_w:in_h*${safeCropRatio.toFixed(2)}:0:0`
  const outputAspectRatio = cinematicCrop ? '21:9' : 'source'

  return {
    mode,
    hideSpeed,
    hideVin,
    hideGps,
    cinematicCrop,
    overlayMasks,
    cropExpression,
    outputAspectRatio
  }
}
