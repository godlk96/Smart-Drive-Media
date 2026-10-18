import fs from '@ohos.file.fs'

/** 每个复制任务仅持有一个缓冲区；只有短写时才复制剩余部分。 */
export async function copyExportFileData(
  sourceFd: number,
  targetFd: number,
  totalBytes: number,
  onProgress: (copied: number, total: number) => void,
  isCancelled: () => boolean
): Promise<number> {
  const buffer = new ArrayBuffer(1024 * 1024)
  let copied = 0
  onProgress(0, totalBytes)
  while (true) {
    if (isCancelled()) {
      throw new Error('已取消导出')
    }
    const readLength = await fs.read(sourceFd, buffer)
    if (readLength <= 0) {
      break
    }
    let written = 0
    while (written < readLength) {
      if (isCancelled()) {
        throw new Error('已取消导出')
      }
      const data = written === 0 ? buffer : buffer.slice(written, readLength)
      const length = await fs.write(targetFd, data, { length: readLength - written })
      if (length <= 0 || length > readLength - written) {
        throw new Error('文件写入未完成')
      }
      written += length
      copied += length
      onProgress(copied, totalBytes)
    }
  }
  if (isCancelled()) {
    throw new Error('已取消导出')
  }
  if (totalBytes > 0 && copied !== totalBytes) {
    throw new Error(`源文件长度变化，复制不完整：${copied}/${totalBytes} 字节`)
  }
  return copied
}
