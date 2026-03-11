import UIAbility from '@ohos.app.ability.UIAbility'
import window from '@ohos.window'
import { debugLog, getRuntimeLogPath, initRuntimeLog } from '../utils/Logger'

export default class EntryAbility extends UIAbility {
  onWindowStageCreate(windowStage: window.WindowStage): void {
    const filesDir = this.context.filesDir ?? '/data/storage/el2/base/files'
    initRuntimeLog(filesDir)
      .then(() => {
        debugLog('应用', `日志初始化完成，路径=${getRuntimeLogPath()}`)
      })
      .catch((error: Error) => {
        debugLog('应用', `日志初始化失败：${error.message}`)
      })
    debugLog('应用', '窗口创建完成，加载首页')
    try {
      windowStage.loadContent('pages/Index')
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('应用', `首页加载失败：${message}`)
    }
  }
}
