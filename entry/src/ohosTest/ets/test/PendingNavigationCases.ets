/**
 * `PendingNavigation` 模块级一次性标记的用例。
 *
 * 不含 hypium 依赖，同一份用例既跑设备也跑 tools/offline-test.mjs。
 * run() 返回 '' 表示通过。
 *
 * 为什么这些用例值得钉死：这个标记跨页面传递「导出后回首页要切到我的剪辑」这一意图，
 * 一旦消费语义写错（该复位不复位 / 重复请求被当成计数 / 消费后又残留），
 * 用户要么被莫名其妙地甩到「我的剪辑」，要么导出后回首页看不到新作品。
 *
 * **顺序无关**：模块里是可变状态，每个用例第一步都先 `consumeOpenMyEdits()`
 * 把标记归一到 false，再布置自己的场景，绝不依赖用例执行顺序。
 */

import { requestOpenMyEdits, consumeOpenMyEdits } from '../../../main/ets/constants/PendingNavigation'
import { TimelineCase, expectTrue, expectFalse, firstError } from './TestSupport'

function makeCase(name: string, run: () => string): TimelineCase {
  const item = new TimelineCase()
  item.name = name
  item.run = run
  return item
}

export function pendingNavigationCases(): Array<TimelineCase> {
  const cases: Array<TimelineCase> = []

  cases.push(makeCase('未请求时消费返回 false', () => {
    consumeOpenMyEdits() // 归一化：清掉上一个用例可能留下的标记
    return expectFalse(consumeOpenMyEdits(), '空态')
  }))

  cases.push(makeCase('请求后消费返回 true', () => {
    consumeOpenMyEdits()
    requestOpenMyEdits()
    return expectTrue(consumeOpenMyEdits(), '已请求')
  }))

  cases.push(makeCase('消费一次后即复位为 false', () => {
    consumeOpenMyEdits()
    requestOpenMyEdits()
    consumeOpenMyEdits()
    return expectFalse(consumeOpenMyEdits(), '二次消费')
  }))

  cases.push(makeCase('重复请求只算一次（布尔标记而非计数）', () => {
    consumeOpenMyEdits()
    requestOpenMyEdits()
    requestOpenMyEdits()
    const first: boolean = consumeOpenMyEdits()
    const second: boolean = consumeOpenMyEdits()
    return firstError([
      expectTrue(first, '首次消费'),
      expectFalse(second, '重复请求不该累计')
    ])
  }))

  cases.push(makeCase('消费后可再次请求', () => {
    consumeOpenMyEdits()
    requestOpenMyEdits()
    consumeOpenMyEdits()
    requestOpenMyEdits()
    return expectTrue(consumeOpenMyEdits(), '再次请求')
  }))

  return cases
}
