/**
 * (安检员) 检查存储空间是否充足。
 */
export class StorageGuard {
  constructor({ reserveBytes = 200 * 1024 * 1024 } = {}) {
    this.reserveBytes = reserveBytes
  }

  validate({ requiredBytes, availableBytes }) {
    const required = Math.max(0, Number(requiredBytes) || 0)
    const available = Math.max(0, Number(availableBytes) || 0)
    const enough = available - this.reserveBytes >= required
    if (enough) {
      return { ok: true, reason: '', requiredBytes: required, availableBytes: available }
    }
    return {
      ok: false,
      reason: 'insufficient_storage',
      requiredBytes: required,
      availableBytes: available
    }
  }
}
