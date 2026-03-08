import UIAbility from '@ohos.app.ability.UIAbility'
import window from '@ohos.window'
import { debugLog } from '../utils/Logger'

export default class EntryAbility extends UIAbility {
  onWindowStageCreate(windowStage: window.WindowStage): void {
    debugLog('应用', '窗口创建完成，加载首页')
    windowStage.loadContent('pages/Index')
  }
}
