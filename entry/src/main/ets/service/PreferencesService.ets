import preferences from '@ohos.data.preferences'
import common from '@ohos.app.ability.common'
import { debugLog } from '../utils/Logger'
import { EditRecord, parseEditRecords, serializeEditRecords } from '../model/EditRecord'

const PREF_STORE_NAME = 'smartdrive_preferences'
const KEY_LAST_TRIP_ID = 'pref_last_trip_id'
const KEY_TEMPLATE_ID = 'pref_template_id'
/** 全部作品记录序列化成**一个** JSON 数组字符串，存在一个 key 下。 */
const KEY_EDIT_RECORDS = 'pref_edit_records'

export class PreferencesService {
  private static instance: PreferencesService | null = null
  private context: common.UIAbilityContext | null = null
  private memoryStore: Map<string, string | number | boolean> = new Map()

  public static getInstance(): PreferencesService {
    if (!PreferencesService.instance) {
      PreferencesService.instance = new PreferencesService()
    }
    return PreferencesService.instance
  }

  public setContext(context: common.UIAbilityContext | null): void {
    this.context = context
  }

  private async getPreferencesStore(): Promise<preferences.Preferences | null> {
    if (!this.context) {
      return null
    }
    try {
      return await preferences.getPreferences(this.context, PREF_STORE_NAME)
    } catch (e) {
      debugLog('Preferences', `获取Preferences实例失败，使用内存降级: ${e}`)
      return null
    }
  }

  public async saveLastTripId(tripId: string): Promise<void> {
    this.memoryStore.set(KEY_LAST_TRIP_ID, tripId)
    const store = await this.getPreferencesStore()
    if (store) {
      try {
        await store.put(KEY_LAST_TRIP_ID, tripId)
        await store.flush()
      } catch (e) {
        debugLog('Preferences', `保存lastTripId失败: ${e}`)
      }
    }
  }

  public async getLastTripId(): Promise<string> {
    const store = await this.getPreferencesStore()
    if (store) {
      try {
        const val = await store.get(KEY_LAST_TRIP_ID, '')
        return String(val ?? '')
      } catch (e) {
        debugLog('Preferences', `读取lastTripId失败: ${e}`)
      }
    }
    return String(this.memoryStore.get(KEY_LAST_TRIP_ID) ?? '')
  }

  public async saveTemplatePreference(templateId: string): Promise<void> {
    this.memoryStore.set(KEY_TEMPLATE_ID, templateId)
    const store = await this.getPreferencesStore()
    if (store) {
      try {
        await store.put(KEY_TEMPLATE_ID, templateId)
        await store.flush()
      } catch (e) {
        debugLog('Preferences', `保存templatePreference失败: ${e}`)
      }
    }
  }

  public async getTemplatePreference(defaultTemplate: string = 'T5'): Promise<string> {
    const store = await this.getPreferencesStore()
    if (store) {
      try {
        const val = await store.get(KEY_TEMPLATE_ID, defaultTemplate)
        return String(val || defaultTemplate)
      } catch (e) {
        debugLog('Preferences', `读取templatePreference失败: ${e}`)
      }
    }
    return String(this.memoryStore.get(KEY_TEMPLATE_ID) || defaultTemplate)
  }

  /** 记录列表是否真的落盘（有 context 才算）。false 时写入只在内存里活着。 */
  public isPersistent(): boolean {
    return this.context !== null
  }

  /**
   * 读取全部作品记录。
   *
   * 与 lastTripId 那种「静默降级成默认值」不同：这里失败必须留下明确的日志，
   * 因为记录丢失对用户是可见的数据损失，不能让它看起来像「本来就没作品」。
   * 读不到就返回空列表让页面能开，但日志里要能看出是故障而不是空历史。
   */
  public async loadEditRecords(): Promise<Array<EditRecord>> {
    const store = await this.getPreferencesStore()
    if (!store) {
      debugLog('偏好设置', '历史记录读取失败（无偏好实例），本次以空列表继续')
      return parseEditRecords(String(this.memoryStore.get(KEY_EDIT_RECORDS) ?? ''))
    }
    try {
      const val = await store.get(KEY_EDIT_RECORDS, '')
      return parseEditRecords(String(val ?? ''))
    } catch (e) {
      debugLog('偏好设置', `历史记录读取失败: ${e}`)
      return parseEditRecords(String(this.memoryStore.get(KEY_EDIT_RECORDS) ?? ''))
    }
  }

  /**
   * 写入全部作品记录。返回是否真正落盘成功 —— 调用方据此提示
   * 「历史记录暂时不可用」，而不是假装成功。
   *
   * 内存 Map 无论成败都同步更新，作为同进程内的兜底读源：即便落盘失败，
   * 这一次会话里刚导出的作品仍然能在「我的剪辑」里看到。
   */
  public async saveEditRecords(records: Array<EditRecord>): Promise<boolean> {
    const raw = serializeEditRecords(records)
    this.memoryStore.set(KEY_EDIT_RECORDS, raw)
    const store = await this.getPreferencesStore()
    if (!store) {
      debugLog('偏好设置', '历史记录保存失败（无偏好实例），仅保留在内存中')
      return false
    }
    try {
      await store.put(KEY_EDIT_RECORDS, raw)
      await store.flush()
      return true
    } catch (e) {
      debugLog('偏好设置', `历史记录保存失败: ${e}`)
      return false
    }
  }
}
