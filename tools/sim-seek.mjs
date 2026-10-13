/**
 * 诊断脚本（临时）：用真实的 checkSeek() 模拟"从轨与主轨实际同步、但上报相位不同"的场景。
 *
 * 目的：验证一个纯逻辑命题 ——
 *   "对账器拿【从轨上一次上报的位置】与【时钟（=主轨上一次上报的位置）】相减得到偏差。
 *    若两条轨的 timeUpdate 上报时刻不同相，这个偏差里就含有【采样年龄差】，
 *    而 seek 无法改变采样相位，因此只要相位差 > SEEK_TOLERANCE_MS，
 *    对账器就会进入【每 DRIFT_CONFIRM_MS 一次 seek】的永久循环。"
 *
 * 模型（严格对照 SingleTrackController.applyDesired / timeUpdate 的写法）：
 *   - 两条轨的真实媒体位置恒等于墙钟时间（即它们【真的完全同步】）。
 *   - 主轨每 Pm 毫秒上报一次；从轨每 Ps 毫秒上报一次，相位 phi 可调。
 *   - 时钟只在主轨上报时前进（advanceFromMaster），因此对账 pass 发生在主轨上报时刻。
 *   - 对账时 observed = 从轨"上一次上报"的位置；wanted = 时钟。
 *   - checkSeek() 决策；seek 后 observed 被乐观置为 wanted（代码里的乐观更新），
 *     从轨真实位置也被拉到 wanted（seek 的物理效果），seek 期间上报被抑制。
 *
 * 用法：node tools/sim-seek.mjs
 */

import { existsSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const ROOT = resolve(import.meta.dirname, '..')
const MATH_MJS = join(
  ROOT,
  '.offline-test-build/entry/src/main/ets/media/TimelineMath.mjs'
)
if (!existsSync(MATH_MJS)) {
  console.error('先运行 node tools/offline-test.mjs 生成离线产物')
  process.exit(1)
}
const math = await import(pathToFileURL(MATH_MJS).href)
const { checkSeek, SEEK_TOLERANCE_MS, DRIFT_CONFIRM_MS } = math

const SEEK_SUPPRESS_MS = 200 // seek 期间 timeUpdate 被抑制的时长（保守估计）

/**
 * 模拟一段时间。返回 { seeks, maxDrift, suppressedMs }
 * @param reportPeriodMs 从轨上报周期
 * @param phaseMs        从轨上报相位（相对主轨）
 * @param durationMs     模拟总时长
 * @param periodMaster   主轨上报周期
 */
function simulate(reportPeriodMs, phaseMs, durationMs, periodMaster = 100) {
  // 从轨真实位置 = 墙钟 + slaveOffset（初始 0 = 完全同步）
  let slaveOffset = 0
  let slaveLastReportAt = -Infinity
  let observed = 0
  let lastSeekCheckAtMs = 0
  let driftHeldMs = 0
  let seekInFlightUntil = -Infinity
  let seeks = 0
  let maxDrift = 0
  let suppressedMs = 0
  let lastSeekAt = -Infinity

  const masterReportAt = (t) => t % periodMaster === 0
  const slaveReportAt = (t) => (t - phaseMs) % reportPeriodMs === 0 && t >= phaseMs

  for (let t = 1; t <= durationMs; t++) {
    // --- 从轨上报（真实位置） ---
    if (slaveReportAt(t)) {
      slaveLastReportAt = t
      if (t >= seekInFlightUntil) {
        observed = t + slaveOffset
      }
    }
    if (t < seekInFlightUntil) {
      suppressedMs += 1
    }

    // --- 主轨上报 → 时钟前进 → 对账 pass ---
    if (!masterReportAt(t)) {
      continue
    }
    const clock = t // 主轨真实位置 = t，段起点为 0

    // SingleTrackController.applyDesired 的早退条件
    if (t < seekInFlightUntil) {
      continue // seekInFlight && !forceSeek → return
    }

    const wanted = clock
    const elapsedMs = lastSeekCheckAtMs > 0 ? t - lastSeekCheckAtMs : 0
    lastSeekCheckAtMs = t
    const drift = observed - wanted
    if (Math.abs(drift) > maxDrift) maxDrift = Math.abs(drift)

    const check = checkSeek(observed, wanted, false, driftHeldMs, elapsedMs)
    driftHeldMs = check.nextDriftHeldMs
    if (check.seek) {
      seeks += 1
      lastSeekAt = t
      // issueSeek：乐观更新 + 物理上把从轨拉到 wanted + 抑制上报
      observed = wanted
      slaveOffset = wanted - t
      seekInFlightUntil = t + SEEK_SUPPRESS_MS
      // seekDone → reconcile 一次（此刻 observed == wanted，偏差 0）
      lastSeekCheckAtMs = t
      driftHeldMs = 0
    }
  }
  return {
    seeks,
    maxDrift,
    suppressedMs,
    seeksPerMinute: (seeks / (durationMs / 60000)).toFixed(1),
    lastSeekAt
  }
}

console.log(`SEEK_TOLERANCE_MS=${SEEK_TOLERANCE_MS}  DRIFT_CONFIRM_MS=${DRIFT_CONFIRM_MS}`)
console.log('场景：从轨与主轨【真实位置完全同步】，只有 timeUpdate 上报相位不同。')
console.log('理想结果：seek 次数应为 0（因为根本没有失步）。\n')

const periods = [100, 150, 250, 300, 350, 400, 500, 750, 1000]
console.log('从轨上报周期  相位差   seek次数(60s)   seek/分钟   最大观测偏差')
for (const p of periods) {
  for (const phase of [0, Math.floor(p / 3), Math.floor(p / 2), Math.floor((2 * p) / 3)]) {
    const r = simulate(p, phase, 60000)
    console.log(
      `${String(p).padStart(8)}ms ${String(phase).padStart(7)}ms ${String(r.seeks).padStart(13)} ${String(r.seeksPerMinute).padStart(11)} ${String(r.maxDrift).padStart(13)}ms`
    )
  }
}

console.log('\n--- 主轨（observed 恒等于 wanted）作为对照 ---')
{
  let driftHeld = 0
  let seeks = 0
  for (let i = 1; i <= 600; i++) {
    const check = checkSeek(i * 100, i * 100, false, driftHeld, 100)
    driftHeld = check.nextDriftHeldMs
    if (check.seek) seeks += 1
  }
  console.log(`主轨 60s 内 seek 次数 = ${seeks}`)
}
