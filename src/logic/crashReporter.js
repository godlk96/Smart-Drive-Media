/**
 * (黑匣子) 捕获程序错误，并自动把敏感信息（如 VIN 码）打码后记录日志。
 */
export class CrashReporter {
  constructor() {
    this.records = []
  }

  capture(error, context = {}) {
    const safeContext = { ...context }
    if (safeContext.vin) {
      safeContext.vin = '***'
    }
    if (safeContext.gps) {
      safeContext.gps = '***'
    }
    const record = {
      message: String(error?.message ?? error ?? 'unknown_error'),
      name: String(error?.name ?? 'Error'),
      context: safeContext,
      timestamp: new Date()
    }
    this.records.push(record)
    return record
  }

  getRecords() {
    return [...this.records]
  }
}
