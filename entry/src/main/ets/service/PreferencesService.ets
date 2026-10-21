import preferences from '@ohos.data.preferences'
import common from '@ohos.app.ability.common'
import { debugLog } from '../utils/Logger'

const PREF_STORE_NAME = 'smartdrive_preferences'
const KEY_LAST_TRIP_ID = 'pref_last_trip_id'
const KEY_TEMPLATE_ID = 'pref_template_id'

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

  public async getTemplatePreference(defaultTemplate: string = 'T1'): Promise<string> {
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
}
