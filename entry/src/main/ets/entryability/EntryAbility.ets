import UIAbility from '@ohos.app.ability.UIAbility'
import window from '@ohos.window'
import { BusinessError } from '@ohos.base'
import { debugLog, getRuntimeLogPath, initRuntimeLog } from '../utils/Logger'

/**
 * 窗口底色，需与 `app.color.ed_bg`（entry/src/main/resources/base/element/color.json）保持一致。
 *
 * 为什么需要它：首页与剪辑页都只在安全区里铺自己的底色，状态栏与导航栏那两条露出的是窗口
 * 底色，系统默认是近白色（SDK 文档：浅色模式下的默认窗口底色），压在暖白页面上就是上下
 * 两道白边。把窗口底色也刷成暖白，两道缝就没了，且不动布局与业务代码。
 *
 * `setWindowBackgroundColor` 只收字符串，引用不了资源，所以这里重复了一份色值；
 * 以后改 `ed_bg` 时记得同步改这里。
 */
const WINDOW_BACKGROUND_COLOR: string = '#F3F1EC'

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
      windowStage.loadContent('pages/Index', (err: BusinessError) => {
        if (err.code) {
          debugLog('应用', `首页加载失败：${err.code} ${err.message}`)
          return
        }
        this.applyWindowBackground(windowStage)
        this.enableFullScreen(windowStage)
      })
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('应用', `首页加载失败：${message}`)
    }
  }

  /**
   * 开启全屏沉浸式布局，让内容延伸到状态栏和导航栏下方，并将底部手势条/状态栏背景设为全透明。
   */
  private enableFullScreen(windowStage: window.WindowStage): void {
    try {
      const mainWindow = windowStage.getMainWindowSync()
      mainWindow.setWindowLayoutFullScreen(true)
      const sysBarProps: window.SystemBarProperties = {
        navigationBarColor: '#00000000',
        statusBarColor: '#00000000',
        navigationBarContentColor: '#000000',
        statusBarContentColor: '#000000'
      }
      mainWindow.setWindowSystemBarProperties(sysBarProps)

      // 获取顶部状态栏避让高度（px 转 vp），存入 AppStorage 供页面精准避让
      const avoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM)
      const topHeightPx = avoidArea.topRect.height
      const topHeightVp = px2vp(topHeightPx)
      AppStorage.setOrCreate('statusBarHeight', topHeightVp > 0 ? topHeightVp : 38)
      debugLog('应用', `全屏沉浸模式与透明手势条已配置完成，状态栏高度=${topHeightVp}vp (${topHeightPx}px)`)

      mainWindow.on('avoidAreaChange', (data) => {
        if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
          const newHeightVp = px2vp(data.area.topRect.height)
          if (newHeightVp > 0) {
            AppStorage.setOrCreate('statusBarHeight', newHeightVp)
          }
        }
      })
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('应用', `设置全屏沉浸失败：${message}`)
    }
  }

  /**
   * 把窗口底色刷成与页面一致的暖白，消掉状态栏/导航栏那两条白边。
   *
   * 时序是有讲究的：SDK 文档明确要求 stage 模型下本接口必须在 `loadContent` 生效之后调用，
   * 否则不生效。之前放在 `loadContent` 之前调，真机上那两条白边纹丝不动，原因就在这里。
   * 失败不影响启动，只记日志。
   */
  private applyWindowBackground(windowStage: window.WindowStage): void {
    try {
      windowStage.getMainWindowSync().setWindowBackgroundColor(WINDOW_BACKGROUND_COLOR)
      debugLog('应用', `窗口底色已设为 ${WINDOW_BACKGROUND_COLOR}`)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog('应用', `窗口底色设置失败：${message}`)
    }
  }
}
