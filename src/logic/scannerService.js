/**
 * (扫描员) 负责指挥扫描任务，调用解析器识别视频，并把碎片文件聚合成完整的“行程”。
 */
import { parseDvrFile, isDvrCandidate } from './fileParser.js'
import { aggregateTrips } from './tripAggregator.js'

export class ScannerService {
  constructor({ repository, taskRunner }) {
    this.repository = repository
    this.taskRunner = taskRunner
  }

  async scan(fileEntries) {
    return this.taskRunner.run(async () => {
      const candidates = fileEntries.filter(item => isDvrCandidate(item.filePath))
      const segments = candidates
        .map(item => parseDvrFile(item.filePath, item.durationSec))
        .filter(Boolean)

      const trips = aggregateTrips(segments)
      this.repository.saveAll(trips)
      return this.repository.getAllDesc()
    })
  }
}
