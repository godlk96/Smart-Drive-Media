import common from '@ohos.app.ability.common'
import fs from '@ohos.file.fs'
import photoAccessHelper from '@ohos.file.photoAccessHelper'
import { WorkEntry } from './WorkStore'
import { copyExportFileData } from './ExportFileCopy'
import { exportPercent } from '../model/ExportProgress'
import { debugLog } from '../utils/Logger'

/**
 * 相册写入的进度基线：从 85% 起算，与导出收尾段同一档，绝不越过 99%
 * （只有 `fsync` 成功才算写完）。基线是常量而非入参 —— 这是用户主动触发的
 * 独立动作，不像导出那样承接「合成到 85%」的前序进度。
 */
const ALBUM_SAVE_BASE_PROGRESS: number = 85

/** 从成片绝对路径取相册条目的标题：去目录、去扩展名（与旧导出文件名去扩展名同义）。 */
function albumTitleFromPath(videoPath: string): string {
  const slashIndex = videoPath.lastIndexOf('/')
  const base = slashIndex >= 0 ? videoPath.slice(slashIndex + 1) : videoPath
  const dotIndex = base.lastIndexOf('.')
  return dotIndex > 0 ? base.slice(0, dotIndex) : base
}

/**
 * 把一件作品的成片（`entry.videoPath`）**显式**写入系统相册（总是新建条目）。
 *
 * 这是用户主动触发的动作，不再是导出流程的一环：导出只落 App 私有作品库，
 * 相册那份是用户点「保存到相册」时才产生的副本，App 之后不再管理它 ——
 * 不记录相册 URI、不覆盖、不删除。再点一次会新建第二条，这是预期行为。
 *
 * 契约：成功返回 `''`；失败返回给用户看的文案 `保存到相册失败：<底层原因>`，**绝不抛错**
 * （与 `HomeViewModel.playWork` 的「空串 = 成功」idiom 一致，调用方据此决定是否 toast）。
 * `onProgress(percent, detail)` 的 `detail` 是「已写入 x MB」或「x / y MB」，供浮层显示。
 *
 * 本文件导入 `@ohos.*`，**不是纯模块**，因此不能进 tools/offline-test.mjs 的 SUITES，
 * 只进 tools/typecheck-player.mjs 的 deps。
 */
export async function saveWorkToAlbum(
  context: common.UIAbilityContext,
  entry: WorkEntry,
  onProgress: (percent: number, detail: string) => void
): Promise<string> {
  const sourceUri: string = entry.videoPath
  try {
    const helper = photoAccessHelper.getPhotoAccessHelper(context)
    const srcFileUris: Array<string> = [sourceUri]
    const title = albumTitleFromPath(sourceUri)
    const photoCreationConfigs: Array<photoAccessHelper.PhotoCreationConfig> = [{
      title: title,
      fileNameExtension: 'mp4',
      photoType: photoAccessHelper.PhotoType.VIDEO,
      subtype: photoAccessHelper.PhotoSubtype.DEFAULT
    }]
    const desFileUris = await helper.showAssetsCreationDialog(srcFileUris, photoCreationConfigs)
    const created = desFileUris[0]
    if (!created || created.length === 0) {
      throw new Error('未选择相册保存位置')
    }
    const albumUri = created
    debugLog('作品库', `相册写入开始 source=${sourceUri} target=${albumUri}`)
    let srcFd: number = -1
    let dstFd: number = -1
    let totalSize: number = 0
    let copiedSize: number = 0
    const baseProgress: number = ALBUM_SAVE_BASE_PROGRESS
    try {
      try {
        const stat = await fs.stat(sourceUri)
        totalSize = Number(stat.size ?? 0)
      } catch (_) {
        totalSize = 0
      }
      const src = await fs.open(sourceUri, fs.OpenMode.READ_ONLY)
      srcFd = src.fd
      // 覆盖不再经过相册（相册那份 App 不管），因此不做 TRUNC、总是写进系统新建的空条目。
      const dst = await fs.open(albumUri, fs.OpenMode.READ_WRITE)
      dstFd = dst.fd
      try {
        // 用户主动触发的保存不可取消：`isCancelled` 恒为 false（Ruling 17）。
        await copyExportFileData(srcFd, dstFd, totalSize, (copied: number, total: number) => {
          copiedSize = copied
          const percent = total > 0 ? exportPercent(baseProgress + Math.min(1, copied / total) * (99 - baseProgress)) : baseProgress
          const detail = total > 0 ? `${(copied / 1048576).toFixed(1)} / ${(total / 1048576).toFixed(1)} MB` :
            `已写入 ${(copied / 1048576).toFixed(1)} MB`
          onProgress(percent, detail)
        }, () => false)
        if (copiedSize <= 0) {
          throw new Error('导出文件为空，未写入相册')
        }
        await fs.fsync(dstFd)
      } catch (error) {
        const copyError = error instanceof Error ? error.message : String(error)
        throw new Error(`相册写入中断（已写入 ${copiedSize}/${totalSize} 字节）：${copyError}`)
      }
    } finally {
      if (srcFd >= 0) {
        try {
          await fs.close(srcFd)
        } catch (_) {
        }
      }
      if (dstFd >= 0) {
        try {
          await fs.close(dstFd)
        } catch (error) {
          throw new Error(`相册文件关闭失败：${error instanceof Error ? error.message : String(error)}`)
        }
      }
    }
    return ''
  } catch (error) {
    return `保存到相册失败：${error instanceof Error ? error.message : String(error)}`
  }
}
