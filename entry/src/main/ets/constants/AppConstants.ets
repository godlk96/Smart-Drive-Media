import { Permissions } from '@kit.AbilityKit'

export const PAGE_ROUTE_INDEX: string = 'pages/Index'
export const PAGE_ROUTE_EDITOR: string = 'pages/Editor'

export const REQUIRED_MEDIA_PERMISSIONS: Array<Permissions> = [
  'ohos.permission.READ_MEDIA' as Permissions,
  'ohos.permission.READ_IMAGEVIDEO' as Permissions,
  'ohos.permission.WRITE_MEDIA' as Permissions
]

export function getTemplateUiNameById(templateId: string): string {
  if (templateId === 'T1') {
    return '防追尾双录'
  }
  if (templateId === 'T2') {
    return '避险防加塞'
  }
  if (templateId === 'T3') {
    return '左右盲区'
  }
  if (templateId === 'T4') {
    return '沉浸式旅拍'
  }
  if (templateId === 'T5') {
    return '单视角'
  }
  if (templateId === 'T6') {
    return '四机位'
  }
  return ''
}

export function getTemplateResolutionById(templateId: string): string {
  if (templateId === 'T1') {
    return '1920×2160'
  }
  if (templateId === 'T2') {
    return '1920×1620'
  }
  if (templateId === 'T3' || templateId === 'T4') {
    return '3840×1080'
  }
  if (templateId === 'T5') {
    return '1920×1080'
  }
  if (templateId === 'T6') {
    return '3840×2160'
  }
  return ''
}

export function normalizeCameraNameById(camera: string): string {
  if (camera === 'FRONT') {
    return 'Front'
  }
  if (camera === 'REAR') {
    return 'Back'
  }
  if (camera === 'LEFT') {
    return 'Left'
  }
  if (camera === 'RIGHT') {
    return 'Right'
  }
  if (camera === 'LEFT_FRONT') {
    return 'LeftFront'
  }
  if (camera === 'RIGHT_FRONT') {
    return 'RightFront'
  }
  return camera
}

export function getCameraZhNameById(camera: string): string {
  if (camera === 'Front') {
    return '前'
  }
  if (camera === 'Back') {
    return '后'
  }
  if (camera === 'Left') {
    return '左后'
  }
  if (camera === 'Right') {
    return '右后'
  }
  if (camera === 'LeftFront') {
    return '左前'
  }
  if (camera === 'RightFront') {
    return '右前'
  }
  return camera
}
