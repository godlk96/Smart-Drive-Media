/**
 * (导出页大脑) 实时转换导出进度状态，供 UI 显示进度条和提示文字。
 */
export class ExportStatusViewModel {
  constructor({ exportJobState }) {
    this.exportJobState = exportJobState
    this.events = []
  }

  start(outputPath) {
    const snapshot = this.exportJobState.start(outputPath)
    this.events.push({
      type: 'start',
      status: snapshot.status,
      progress: snapshot.progress,
      outputPath: snapshot.outputPath,
      timestamp: new Date()
    })
    return this.getState()
  }

  progress(value) {
    const snapshot = this.exportJobState.updateProgress(value)
    this.events.push({
      type: 'progress',
      status: snapshot.status,
      progress: snapshot.progress,
      timestamp: new Date()
    })
    return this.getState()
  }

  success() {
    const snapshot = this.exportJobState.succeed()
    this.events.push({
      type: 'success',
      status: snapshot.status,
      progress: snapshot.progress,
      timestamp: new Date()
    })
    return this.getState()
  }

  fail(message) {
    const snapshot = this.exportJobState.fail(message)
    this.events.push({
      type: 'failed',
      status: snapshot.status,
      progress: snapshot.progress,
      errorMessage: snapshot.errorMessage,
      timestamp: new Date()
    })
    return this.getState()
  }

  getState() {
    const snapshot = this.exportJobState.snapshot()
    return {
      statusText: snapshot.status,
      progressText: `${snapshot.progress}%`,
      errorText: snapshot.errorMessage,
      outputPath: snapshot.outputPath,
      trace: [...this.events]
    }
  }
}
