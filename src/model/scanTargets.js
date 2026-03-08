/**
 * (路标) 定义了需要扫描的目标位置（如系统相册、Huawei Share 目录）。
 */
export const ScanTarget = Object.freeze({
  SYSTEM_ALBUM: 'system_album',
  HUAWEI_SHARE: 'huawei_share'
})

export function getDefaultScanTargets() {
  return [ScanTarget.SYSTEM_ALBUM, ScanTarget.HUAWEI_SHARE]
}
