/**
 * (门卫) 负责被动监听系统相册或华为分享目录的新文件，触发扫描。
 */
import { getDefaultScanTargets } from '../model/scanTargets.js'

export class PassiveImportController {
  constructor({ scannerService, fileSource }) {
    this.scannerService = scannerService
    this.fileSource = fileSource
  }

  async start() {
    const targets = getDefaultScanTargets()
    const fileEntries = await this.fileSource.listFiles(targets)
    return this.scannerService.scan(fileEntries)
  }
}
