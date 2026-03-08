import test from 'node:test'
import assert from 'node:assert/strict'
import { runSecurityAudit } from '../src/logic/securityAudit.js'
import { createDefaultPrivacyConfig } from '../src/logic/privacyConfig.js'

test('runSecurityAudit passes for local processing with minimal permissions', () => {
  const result = runSecurityAudit({
    processingMode: 'local_only',
    requestedPermissions: ['ohos.permission.READ_MEDIA', 'ohos.permission.READ_IMAGEVIDEO'],
    privacyConfig: createDefaultPrivacyConfig()
  })

  assert.equal(result.passed, true)
  assert.equal(result.details.localOnly, true)
  assert.equal(result.details.minimalPermissionOnly, true)
  assert.equal(result.details.defaultPrivacyOn, true)
})
