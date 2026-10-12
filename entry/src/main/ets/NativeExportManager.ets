import common from '@ohos.app.ability.common'
import { ExportSnapshot } from './model/Models'
import { ExportJobEvent, sharedExportManager } from './service/ExportManager'

export async function startNativeExport(
  snapshot: ExportSnapshot,
  context: common.UIAbilityContext,
  onEvent?: (event: ExportJobEvent) => void
): Promise<string> {
  const jobId = await sharedExportManager.start(snapshot, context)
  return await new Promise<string>((resolve, reject) => {
    let settled = false
    const timeoutTimer = setTimeout(() => {
      if (!settled) {
        settled = true
        reject(new Error('导出超时，请重试'))
      }
    }, 180000)

    sharedExportManager.subscribe(jobId, (event: ExportJobEvent) => {
      if (onEvent) {
        onEvent(event)
      }
      if (event.status.startsWith('导出失败：')) {
        if (!settled) {
          settled = true
          clearTimeout(timeoutTimer)
          reject(new Error(event.status.replace('导出失败：', '')))
        }
        return
      }
      if (event.status.startsWith('导出完成：') || event.status.startsWith('相册保存成功：')) {
        if (!settled) {
          settled = true
          clearTimeout(timeoutTimer)
          resolve(event.status.replace('导出完成：', '').replace('相册保存成功：', ''))
        }
      }
    })
  })
}
