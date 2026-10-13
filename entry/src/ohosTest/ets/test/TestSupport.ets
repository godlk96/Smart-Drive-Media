/**
 * 测试用例的公共支撑。
 *
 * 刻意**不含 hypium 依赖**，因此同一份用例可以同时被两条路径执行：
 *   1. 设备上：各 *.test.ets 用 hypium 包装它（entry/src/ohosTest）
 *   2. 本机离线：tools/offline-test.mjs 直接把 .ets 复制成 .ts 后 import 并执行
 *
 * 用例逻辑只写一份，避免"设备上过的测试"和"本地过的测试"漂移。
 * 每个用例的 run() 返回 '' 表示通过，否则返回失败原因。
 */

export class TimelineCase {
  name: string = ''
  run: () => string = () => ''
}

export function expectNumber(actual: number, expected: number, label: string): string {
  if (actual !== expected) {
    return `${label}: 期望 ${expected}，实际 ${actual}`
  }
  return ''
}

export function expectString(actual: string, expected: string, label: string): string {
  if (actual !== expected) {
    return `${label}: 期望 "${expected}"，实际 "${actual}"`
  }
  return ''
}

export function expectTrue(condition: boolean, label: string): string {
  if (!condition) {
    return `${label}: 期望为真，实际为假`
  }
  return ''
}

export function expectFalse(condition: boolean, label: string): string {
  if (condition) {
    return `${label}: 期望为假，实际为真`
  }
  return ''
}

export function firstError(errors: Array<string>): string {
  for (let i = 0; i < errors.length; i++) {
    if (errors[i].length > 0) {
      return errors[i]
    }
  }
  return ''
}
