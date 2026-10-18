/**
 * 「我的剪辑」作品记录的服务层。
 *
 * 薄封装：读写全交给 PreferencesService，列表变换全交给 EditRecord 的纯函数。
 * 本层只做三件事 —— 串行化读改写、挑出要改的那条、把「落盘是否成功」如实往上传。
 *
 * 注意：本文件导入 PreferencesService（→ @ohos.data.preferences），
 * **不是纯模块**，因此不能进 tools/offline-test.mjs 的 SUITES（离线桩遇裸导入会抛错）；
 * 它只进 tools/typecheck-player.mjs 的 deps。
 */

import common from '@ohos.app.ability.common'
import { EditRecord, findRecordById, findLatestRecordForTrip, removeRecords,
  upsertRecord } from '../model/EditRecord'
import { PreferencesService } from './PreferencesService'
import { debugLog } from '../utils/Logger'

export class EditHistoryService {
  private static instance: EditHistoryService | null = null

  public static getInstance(): EditHistoryService {
    if (!EditHistoryService.instance) {
      EditHistoryService.instance = new EditHistoryService()
    }
    return EditHistoryService.instance
  }

  /** 转调 PreferencesService。App 启动时注入一次 context 即可。 */
  public async setContext(context: common.UIAbilityContext | null): Promise<void> {
    PreferencesService.getInstance().setContext(context)
  }

  public async list(): Promise<Array<EditRecord>> {
    return PreferencesService.getInstance().loadEditRecords()
  }

  public async findById(id: string): Promise<EditRecord | undefined> {
    const records = await this.list()
    return findRecordById(records, id)
  }

  /** 覆盖目标：「这趟行程最近导出过的那一条」。 */
  public async latestForTrip(tripId: string): Promise<EditRecord | undefined> {
    const records = await this.list()
    return findLatestRecordForTrip(records, tripId)
  }

  /**
   * 写入一条记录（同 id 覆盖，否则追加）。
   * 返回是否落盘成功；失败时记录仍在内存里，本次会话可见。
   */
  public async upsert(record: EditRecord): Promise<boolean> {
    const records = await this.list()
    const next = upsertRecord(records, record)
    const saved = await PreferencesService.getInstance().saveEditRecords(next)
    if (!saved) {
      debugLog('我的剪辑', `记录落盘失败，仅留在内存: ${record.id}`)
    }
    return saved
  }

  public async remove(ids: Array<string>): Promise<boolean> {
    if (ids.length === 0) {
      return true
    }
    const records = await this.list()
    const next = removeRecords(records, ids)
    return PreferencesService.getInstance().saveEditRecords(next)
  }

  /**
   * 补写封面缓存路径。
   *
   * 刻意在「路径没变」时直接返回 true 而不写盘：这个方法会被列表渲染逐条调用，
   * 每调一次就 flush 一遍整个偏好文件的话，滚动列表会变成持续写盘。
   */
  public async updateCoverPath(id: string, coverPath: string): Promise<boolean> {
    if (coverPath.length === 0) {
      return true
    }
    const records = await this.list()
    const target = findRecordById(records, id)
    if (!target || target.coverPath === coverPath) {
      return true
    }
    target.coverPath = coverPath
    return PreferencesService.getInstance().saveEditRecords(records)
  }
}
