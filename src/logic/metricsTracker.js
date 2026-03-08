/**
 * (统计员) 记录用户行为数据（如“扫描耗时”、“导出成功率”），用于优化产品。
 */
const METRIC_KEYS = new Set([
  'scan_duration',
  'export_duration',
  'export_success',
  'feature_usage'
])

export class MetricsTracker {
  constructor() {
    this.events = []
  }

  track(name, value, tags = {}) {
    if (!METRIC_KEYS.has(name)) {
      return null
    }
    const event = {
      name,
      value,
      tags: { ...tags },
      timestamp: new Date()
    }
    this.events.push(event)
    return event
  }

  getEvents(name) {
    return this.events.filter(item => (name ? item.name === name : true))
  }
}
