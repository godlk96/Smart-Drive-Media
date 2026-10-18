import preferences from '@ohos.data.preferences'
import common from '@ohos.app.ability.common'
import { debugLog } from '../utils/Logger'
import { EditRecord, MAX_EDIT_RECORDS, MAX_EDIT_RECORDS_BYTES, fitRecordsUnderBytes,
  limitRecords, parseEditRecords, serializeEditRecords } from '../model/EditRecord'

const PREF_STORE_NAME = 'smartdrive_preferences'
const KEY_LAST_TRIP_ID = 'pref_last_trip_id'
const KEY_TEMPLATE_ID = 'pref_template_id'
/** 全部作品记录序列化成**一个** JSON 数组字符串，存在一个 key 下。 */
const KEY_EDIT_RECORDS = 'pref_edit_records'

export class PreferencesService {
  private static instance: PreferencesService | null = null
  private context: common.UIAbilityContext | null = null
  private memoryStore: Map<string, string | number | boolean> = new Map()
  /**
   * 写盘失败过一次之后，本进程内改以内存副本为唯一读源。
   *
   * 不这么做的话会出现最难解释的那种「丢数据」：`put` 失败、`get` 仍成功，
   * 于是下一次读拿到的是**失败之前**的旧列表 —— 用户刚导出的作品在同一个
   * 会话里就消失了，连重启都不用等。
   */
  private recordsOnlyInMemory: boolean = false

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
   * 上一次作品记录的写入是否真的落盘了。
   *
   * 导出成功的提示据此改写：成片确实进了相册，但记录只存在内存里、
   * 重启就没 —— 这必须告诉用户，不能让「已保存到相册」把丢历史一起盖住。
   */
  public isEditRecordsDurable(): boolean {
    return this.context !== null && !this.recordsOnlyInMemory
  }

  /**
   * 读取全部作品记录。
   *
   * 与 lastTripId 那种「静默降级成默认值」不同：这里失败必须留下明确的日志，
   * 因为记录丢失对用户是可见的数据损失，不能让它看起来像「本来就没作品」。
   * 读不到就返回空列表让页面能开，但日志里要能看出是故障而不是空历史。
   */
  public async loadEditRecords(): Promise<Array<EditRecord>> {
    if (this.recordsOnlyInMemory) {
      debugLog('偏好设置', '历史记录以内存副本为准（此前落盘失败过）')
      return parseEditRecords(String(this.memoryStore.get(KEY_EDIT_RECORDS) ?? ''))
    }
    const store = await this.getPreferencesStore()
    if (!store) {
      debugLog('偏好设置', '历史记录读取失败（无偏好实例），本次以内存副本继续')
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
   * 写入全部作品记录。返回是否真正落盘成功 —— 调用方据此告诉用户
   * 「历史记录暂时不可用」，而不是假装成功。
   *
   * 内存 Map 无论成败都同步更新；**失败一次之后它就变成唯一读源**，
   * 保证本次会话里刚导出的作品立刻能在「我的剪辑」里看到。
   *
   * 写入前按条数与体积双重裁剪（见 EditRecord 的 limitRecords /
   * fitRecordsUnderBytes）：宁可淘汰最旧的作品，也不能让写入因为超限而开始失败。
   */
  public async saveEditRecords(records: Array<EditRecord>): Promise<boolean> {
    const capped = fitRecordsUnderBytes(limitRecords(records, MAX_EDIT_RECORDS), MAX_EDIT_RECORDS_BYTES)
    const raw = serializeEditRecords(capped)
    this.memoryStore.set(KEY_EDIT_RECORDS, raw)
    const store = await this.getPreferencesStore()
    if (!store) {
      this.recordsOnlyInMemory = true
      debugLog('偏好设置', '历史记录保存失败（无偏好实例），仅保留在内存中')
      return false
    }
    try {
      await store.put(KEY_EDIT_RECORDS, raw)
      await store.flush()
      this.recordsOnlyInMemory = false
      return true
    } catch (e) {
      this.recordsOnlyInMemory = true
      debugLog('偏好设置', `历史记录保存失败: ${e}`)
      return false
    }
  }
}
