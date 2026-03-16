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
    sharedExportManager.subscribe(jobId, (event: ExportJobEvent) => {
      if (onEvent) {
        onEvent(event)
      }
      if (event.status.startsWith('导出失败：')) {
        reject(new Error(event.status.replace('导出失败：', '')))
        return
      }
      if (event.status.startsWith('导出完成：')) {
        resolve(event.status.replace('导出完成：', ''))
      }
    })
  })
}
