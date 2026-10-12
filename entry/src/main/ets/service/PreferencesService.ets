import preferences from '@ohos.data.preferences'
import common from '@ohos.app.ability.common'
import { debugLog } from '../utils/Logger'

export interface PrivacySettings {
  hideSpeed: boolean;
  hideVin: boolean;
  hideTime: boolean;
}

const PREF_STORE_NAME = 'smartdrive_preferences'
const KEY_LAST_TRIP_ID = 'pref_last_trip_id'
const KEY_TEMPLATE_ID = 'pref_template_id'
const KEY_HIDE_SPEED = 'pref_hide_speed'
const KEY_HIDE_VIN = 'pref_hide_vin'
const KEY_HIDE_TIME = 'pref_hide_time'

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

  public async getTemplatePreference(defaultTemplate: string = 'T2'): Promise<string> {
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

  public async savePrivacySettings(settings: PrivacySettings): Promise<void> {
    this.memoryStore.set(KEY_HIDE_SPEED, settings.hideSpeed)
    this.memoryStore.set(KEY_HIDE_VIN, settings.hideVin)
    this.memoryStore.set(KEY_HIDE_TIME, settings.hideTime)
    const store = await this.getPreferencesStore()
    if (store) {
      try {
        await store.put(KEY_HIDE_SPEED, settings.hideSpeed)
        await store.put(KEY_HIDE_VIN, settings.hideVin)
        await store.put(KEY_HIDE_TIME, settings.hideTime)
        await store.flush()
      } catch (e) {
        debugLog('Preferences', `保存privacySettings失败: ${e}`)
      }
    }
  }

  public async getPrivacySettings(): Promise<PrivacySettings> {
    const store = await this.getPreferencesStore()
    if (store) {
      try {
        const hideSpeed = Boolean(await store.get(KEY_HIDE_SPEED, true))
        const hideVin = Boolean(await store.get(KEY_HIDE_VIN, true))
        const hideTime = Boolean(await store.get(KEY_HIDE_TIME, true))
        return { hideSpeed, hideVin, hideTime }
      } catch (e) {
        debugLog('Preferences', `读取privacySettings失败: ${e}`)
      }
    }
    return {
      hideSpeed: Boolean(this.memoryStore.get(KEY_HIDE_SPEED) ?? true),
      hideVin: Boolean(this.memoryStore.get(KEY_HIDE_VIN) ?? true),
      hideTime: Boolean(this.memoryStore.get(KEY_HIDE_TIME) ?? true)
    }
  }
}
