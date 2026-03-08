/**
 * (仓库) 负责将行程数据保存到内存或数据库中，并提供查询功能。
 */
export class TripRepository {
  #trips = []

  saveAll(trips) {
    this.#trips = [...trips]
  }

  getAllDesc() {
    return [...this.#trips].sort((a, b) => b.startTime - a.startTime)
  }
}
