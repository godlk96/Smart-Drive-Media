import { HarmonyCoreBridge } from '../../../../src/harmony/coreBridge.js'

export function createBridge(options = {}) {
  return new HarmonyCoreBridge(options)
}
