/**
 * (安检员) 检查权限合规性。
 */
export function runSecurityAudit({
  processingMode,
  requestedPermissions,
  privacyConfig
}) {
  const permissionSet = new Set(requestedPermissions ?? [])
  const minimalPermissionOnly =
    permissionSet.has('ohos.permission.READ_MEDIA') &&
    permissionSet.has('ohos.permission.READ_IMAGEVIDEO') &&
    permissionSet.size === 2

  const defaultPrivacyOn =
    Boolean(privacyConfig?.hideSpeed) &&
    Boolean(privacyConfig?.hideVin) &&
    Boolean(privacyConfig?.hideGps)

  const passed =
    processingMode === 'local_only' &&
    minimalPermissionOnly &&
    defaultPrivacyOn

  return {
    passed,
    details: {
      localOnly: processingMode === 'local_only',
      minimalPermissionOnly,
      defaultPrivacyOn
    }
  }
}
