/**
 * (字典) 定义了通用的常量，比如摄像头的枚举值（Front, Back, Left...）。
 */
export const CameraPosition = Object.freeze({
  FRONT: 'Front',
  BACK: 'Back',
  LEFT: 'Left',
  RIGHT: 'Right',
  LEFT_FRONT: 'LeftFront',
  RIGHT_FRONT: 'RightFront',
  UNKNOWN: 'Unknown'
})

const CAMERA_ALIAS = new Map([
  ['front', CameraPosition.FRONT],
  ['back', CameraPosition.BACK],
  ['rear', CameraPosition.BACK],
  ['left', CameraPosition.LEFT],
  ['leftrear', CameraPosition.LEFT],
  ['left_rear', CameraPosition.LEFT],
  ['right', CameraPosition.RIGHT],
  ['rightrear', CameraPosition.RIGHT],
  ['right_rear', CameraPosition.RIGHT],
  ['leftfront', CameraPosition.LEFT_FRONT],
  ['left_front', CameraPosition.LEFT_FRONT],
  ['frontleft', CameraPosition.LEFT_FRONT],
  ['rightfront', CameraPosition.RIGHT_FRONT],
  ['right_front', CameraPosition.RIGHT_FRONT],
  ['frontright', CameraPosition.RIGHT_FRONT]
])

export function normalizeCameraPosition(rawValue) {
  const normalized = String(rawValue ?? '')
    .toLowerCase()
    .replace(/[^a-z_]/g, '')

  return CAMERA_ALIAS.get(normalized) ?? CameraPosition.UNKNOWN
}
