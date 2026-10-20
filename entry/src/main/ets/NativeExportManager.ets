import common from '@ohos.app.ability.common'
import { ExportSnapshot } from './model/Models'
import { ExportJobEvent, sharedExportManager } from './service/ExportManager'

/** 导出结果：作品 id + sidecar 是否落盘（false = 降级卡片，调用方据此如实告知用户）。 */
export interface ExportOutcome {
  workId: string
  metaSaved: boolean
}

export async function startNativeExport(
  snapshot: ExportSnapshot,
  context: common.UIAbilityContext,
  onEvent?: (event: ExportJobEvent) => void,
  overwriteWorkId?: string
): Promise<ExportOutcome> {
  const jobId = await sharedExportManager.start(snapshot, context, overwriteWorkId)
  return await new Promise<ExportOutcome>((resolve, reject) => {
    let settled = false
    const timeoutTimer = setTimeout(() => {
      if (!settled) {
        settled = true
        sharedExportManager.cancel(jobId)
        reject(new Error('导出超时，已取消当前任务，请稍后重试'))
      }
    }, 180000)

    sharedExportManager.subscribe(jobId, (event: ExportJobEvent) => {
      if (onEvent) {
        onEvent(event)
      }
      if (event.status.startsWith('导出失败：') || event.status === '已取消导出') {
        if (!settled) {
          settled = true
          clearTimeout(timeoutTimer)
          reject(new Error(event.status.replace('导出失败：', '')))
        }
        return
      }
      if (event.status.startsWith('已保存：')) {
        if (!settled) {
          settled = true
          clearTimeout(timeoutTimer)
          resolve({ workId: event.status.replace('已保存：', ''), metaSaved: event.metaSaved === true })
        }
      }
    })
  })
}

export function cancelNativeExport(jobId?: string): void {
  if (jobId) {
    sharedExportManager.cancel(jobId)
  } else {
    sharedExportManager.cancelAll()
  }
}
