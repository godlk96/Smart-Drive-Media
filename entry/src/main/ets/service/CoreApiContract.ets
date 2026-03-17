import smartdriveExporter from 'libsmartdrive_exporter.so'

const REQUIRED_CORE_API_VERSION: string = 'core-api-v2'
let coreApiChecked: boolean = false

export function ensureCoreApiContract(): void {
  if (coreApiChecked) {
    return
  }
  const getVersion = smartdriveExporter.getCoreApiVersion as (() => string) | undefined
  if (typeof getVersion !== 'function') {
    throw new Error('smartdrive_exporter.getCoreApiVersion 未实现')
  }
  const actualVersion = String(getVersion() ?? '')
  if (actualVersion !== REQUIRED_CORE_API_VERSION) {
    throw new Error(`smartdrive_exporter 接口版本不兼容，期望=${REQUIRED_CORE_API_VERSION} 实际=${actualVersion}`)
  }
  coreApiChecked = true
}

export function tryEnsureCoreApiContract(): boolean {
  try {
    ensureCoreApiContract()
    return true
  } catch (_) {
    return false
  }
}
