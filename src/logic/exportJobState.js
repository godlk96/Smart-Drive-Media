/**
 * (记分牌) 记录导出任务的状态（进行中、进度百分比、成功/失败）。
 */
export class ExportJobState {
  constructor() {
    this.status = 'idle'
    this.progress = 0
    this.outputPath = ''
    this.errorMessage = ''
  }

  start(outputPath) {
    this.status = 'running'
    this.progress = 0
    this.outputPath = outputPath
    this.errorMessage = ''
    return this.snapshot()
  }

  updateProgress(progress) {
    const value = Number(progress)
    this.progress = Math.min(100, Math.max(0, Number.isFinite(value) ? value : 0))
    return this.snapshot()
  }

  succeed() {
    this.status = 'success'
    this.progress = 100
    return this.snapshot()
  }

  fail(errorMessage) {
    this.status = 'failed'
    this.errorMessage = String(errorMessage ?? 'unknown_error')
    return this.snapshot()
  }

  snapshot() {
    return {
      status: this.status,
      progress: this.progress,
      outputPath: this.outputPath,
      errorMessage: this.errorMessage
    }
  }
}
