import UIAbility from '@ohos.app.ability.UIAbility'
import window from '@ohos.window'
import { debugLog } from '../utils/Logger'

export default class EntryAbility extends UIAbility {
  onWindowStageCreate(windowStage: window.WindowStage): void {
    debugLog('应用', '窗口创建完成，加载首页')
    try {
      windowStage.loadContent('pages/Index')
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('应用', `首页加载失败：${message}`)
    }
  }
}
