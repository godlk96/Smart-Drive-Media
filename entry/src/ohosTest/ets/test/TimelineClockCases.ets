/**
 * TimelineClock 的测试用例（不含 hypium 依赖，设备与离线两条路径共用）。
 *
 * 这些用例把"唯一时间源"的**不变式**钉死，而不是只测几个快乐路径：
 *   - 只有 seek() 能让播放头倒退；
 *   - 拖动期间绝不动真实播放头；
 *   - 松手只 seek 一次；
 *   - 订阅/取消订阅不泄漏、广播过程可重入。
 * 之前"修一个冒一个"的根因就是这些不变式从未被显式表达过。
 */

import { ClockSnapshot, TimelineClock } from '../../../main/ets/media/TimelineClock'
import {
  TimelineCase,
  expectNumber,
  expectTrue,
  expectFalse,
  firstError
} from './TestSupport'

function clockWith(durationMs: number): TimelineClock {
  const clock = new TimelineClock()
  clock.setDuration(durationMs)
  return clock
}

export function timelineClockCases(): Array<TimelineCase> {
  const cases: Array<TimelineCase> = []

  cases.push({
    name: 'TimelineClock: 初始状态全为零值，速率为 1',
    run: (): string => {
      const clock = new TimelineClock()
      return firstError([
        expectNumber(clock.getPlayheadMs(), 0, 'playheadMs'),
        expectNumber(clock.getDurationMs(), 0, 'durationMs'),
        expectFalse(clock.isPlaying(), 'playing'),
        expectNumber(clock.getRate(), 1, 'rate'),
        expectFalse(clock.isDragging(), 'dragging'),
        expectNumber(clock.getVisibleMs(), 0, 'visibleMs'),
        expectNumber(clock.getSeekGeneration(), 0, 'seekGeneration')
      ])
    }
  })

  cases.push({
    name: 'TimelineClock: setDuration 收窄时播放头跟着收窄',
    run: (): string => {
      const clock = clockWith(100000)
      clock.seek(90000)
      clock.setDuration(30000)
      return firstError([
        expectNumber(clock.getDurationMs(), 30000, 'durationMs'),
        expectNumber(clock.getPlayheadMs(), 30000, '播放头被钳制到新时长')
      ])
    }
  })

  cases.push({
    name: 'TimelineClock: setDuration 负数归零',
    run: (): string => {
      const clock = new TimelineClock()
      clock.setDuration(-500)
      return firstError([expectNumber(clock.getDurationMs(), 0, 'durationMs')])
    }
  })

  cases.push({
    name: 'TimelineClock: seek 钳制到 [0, duration] 并递增轮次',
    run: (): string => {
      const clock = clockWith(60000)
      clock.seek(-100)
      const afterNegative = clock.getPlayheadMs()
      clock.seek(999999)
      const afterOverflow = clock.getPlayheadMs()
      return firstError([
        expectNumber(afterNegative, 0, '负数归零'),
        expectNumber(afterOverflow, 60000, '越界截断'),
        expectNumber(clock.getSeekGeneration(), 2, '两次 seek → 轮次 2')
      ])
    }
  })

  cases.push({
    name: 'TimelineClock: 拖动只改可见值，真实播放头不动',
    run: (): string => {
      const clock = clockWith(60000)
      clock.seek(10000)
      clock.setDragPreview(40000)
      return firstError([
        expectTrue(clock.isDragging(), 'dragging'),
        expectNumber(clock.getVisibleMs(), 40000, '可见值 = 预览值'),
        expectNumber(clock.getPlayheadMs(), 10000, '真实播放头不变'),
        expectNumber(clock.getSnapshot().playheadMs, 40000, '快照给 UI 的是预览值')
      ])
    }
  })

  cases.push({
    name: 'TimelineClock: 拖动期间主轨推进被忽略（不回跳、不抖动）',
    run: (): string => {
      const clock = clockWith(60000)
      clock.seek(10000)
      clock.setPlaying(true)
      clock.setDragPreview(40000)
      clock.advanceFromMaster(41000)
      return firstError([
        expectNumber(clock.getPlayheadMs(), 10000, '真实播放头仍不动'),
        expectNumber(clock.getVisibleMs(), 40000, '可见值仍是预览值')
      ])
    }
  })

  cases.push({
    name: 'TimelineClock: 松手只 seek 一次，一次到位且结束拖动',
    run: (): string => {
      const clock = clockWith(60000)
      clock.seek(10000)
      clock.setDragPreview(40000)
      const generationBefore = clock.getSeekGeneration()
      clock.seek(clock.getVisibleMs())
      return firstError([
        expectFalse(clock.isDragging(), 'dragging 结束'),
        expectNumber(clock.getPlayheadMs(), 40000, '播放头 = 松手位置'),
        expectNumber(clock.getVisibleMs(), 40000, '可见值 = 播放头'),
        expectNumber(clock.getSeekGeneration(), generationBefore + 1, '只递增一次')
      ])
    }
  })

  cases.push({
    name: 'TimelineClock: cancelDrag 回到真实值且不产生 seek',
    run: (): string => {
      const clock = clockWith(60000)
      clock.seek(10000)
      const generationBefore = clock.getSeekGeneration()
      clock.setDragPreview(40000)
      clock.cancelDrag()
      return firstError([
        expectFalse(clock.isDragging(), 'dragging 结束'),
        expectNumber(clock.getVisibleMs(), 10000, '可见值回到真实值'),
        expectNumber(clock.getPlayheadMs(), 10000, '真实播放头不变'),
        expectNumber(clock.getSeekGeneration(), generationBefore, '不产生 seek')
      ])
    }
  })

  cases.push({
    name: 'TimelineClock: 未拖动时 cancelDrag 是空操作',
    run: (): string => {
      const clock = clockWith(60000)
      clock.seek(10000)
      let emissions = 0
      clock.subscribe(() => {
        emissions += 1
      })
      clock.cancelDrag()
      return firstError([
        expectNumber(emissions, 0, '无广播'),
        expectNumber(clock.getPlayheadMs(), 10000, '播放头不变')
      ])
    }
  })

  cases.push({
    name: 'TimelineClock: advanceFromMaster 只允许前进（倒退被忽略）',
    run: (): string => {
      const clock = clockWith(60000)
      clock.setPlaying(true)
      clock.advanceFromMaster(30000)
      clock.advanceFromMaster(20000)
      const afterBackwards = clock.getPlayheadMs()
      clock.advanceFromMaster(30000)
      const afterEqual = clock.getPlayheadMs()
      clock.advanceFromMaster(31000)
      return firstError([
        expectNumber(afterBackwards, 30000, '倒退被忽略'),
        expectNumber(afterEqual, 30000, '相等被忽略'),
        expectNumber(clock.getPlayheadMs(), 31000, '前进被接受')
      ])
    }
  })

  cases.push({
    name: 'TimelineClock: 非播放态时 advanceFromMaster 被忽略',
    run: (): string => {
      const clock = clockWith(60000)
      clock.advanceFromMaster(30000)
      return firstError([expectNumber(clock.getPlayheadMs(), 0, '播放头不动')])
    }
  })

  cases.push({
    name: 'TimelineClock: advanceFromMaster 钳制到总时长',
    run: (): string => {
      const clock = clockWith(60000)
      clock.setPlaying(true)
      clock.advanceFromMaster(999999)
      return firstError([expectNumber(clock.getPlayheadMs(), 60000, '播放头 = 总时长')])
    }
  })

  cases.push({
    name: 'TimelineClock: seek 后从新位置继续前进（不回跳）',
    run: (): string => {
      const clock = clockWith(60000)
      clock.setPlaying(true)
      clock.advanceFromMaster(50000)
      clock.seek(5000)
      clock.advanceFromMaster(5000)
      const atSeekTarget = clock.getPlayheadMs()
      clock.advanceFromMaster(6000)
      return firstError([
        expectNumber(atSeekTarget, 5000, 'seek 后停在目标'),
        expectNumber(clock.getPlayheadMs(), 6000, '从目标继续前进')
      ])
    }
  })

  cases.push({
    name: 'TimelineClock: setPlaying 幂等，重复设置不重复广播',
    run: (): string => {
      const clock = clockWith(60000)
      let emissions = 0
      clock.subscribe(() => {
        emissions += 1
      })
      clock.setPlaying(false)
      const afterNoop = emissions
      clock.setPlaying(true)
      const afterPlay = emissions
      clock.setPlaying(true)
      return firstError([
        expectNumber(afterNoop, 0, '重复 false 无广播'),
        expectNumber(afterPlay, 1, 'true 广播一次'),
        expectNumber(emissions, 1, '重复 true 无广播')
      ])
    }
  })

  cases.push({
    name: 'TimelineClock: setRate 非法值归 1，且幂等',
    run: (): string => {
      const clock = clockWith(60000)
      let emissions = 0
      clock.subscribe(() => {
        emissions += 1
      })
      clock.setRate(1)
      const afterNoop = emissions
      clock.setRate(2)
      clock.setRate(-3)
      return firstError([
        expectNumber(afterNoop, 0, '重复 1 无广播'),
        expectNumber(emissions, 2, '两次变更各广播一次'),
        expectNumber(clock.getRate(), 1, '负速率归 1')
      ])
    }
  })

  cases.push({
    name: 'TimelineClock: 取消订阅后不再收到广播',
    run: (): string => {
      const clock = clockWith(60000)
      let first = 0
      let second = 0
      const unsubscribe = clock.subscribe(() => {
        first += 1
      })
      clock.subscribe(() => {
        second += 1
      })
      clock.seek(10000)
      unsubscribe()
      clock.seek(20000)
      return firstError([
        expectNumber(first, 1, '取消后不再收到'),
        expectNumber(second, 2, '另一个订阅者照常收到')
      ])
    }
  })

  cases.push({
    name: 'TimelineClock: 广播过程可重入（回调里新增订阅者本轮不收到、下一轮收到）',
    run: (): string => {
      const clock = clockWith(60000)
      let addedCalls = 0
      let firstRoundDone = false
      clock.subscribe(() => {
        if (!firstRoundDone) {
          firstRoundDone = true
          // 在广播过程中新增订阅者：本轮广播用的是快照，不应影响到它
          clock.subscribe(() => {
            addedCalls += 1
          })
        }
      })
      clock.seek(10000)
      const afterFirstRound = addedCalls
      clock.seek(20000)
      return firstError([
        expectNumber(afterFirstRound, 0, '本轮新增的订阅者不收到本次广播'),
        expectNumber(addedCalls, 1, '下一轮广播照常收到')
      ])
    }
  })

  cases.push({
    name: 'TimelineClock: 回调里取消订阅，本轮仍按快照投递完',
    run: (): string => {
      const clock = clockWith(60000)
      let secondCalls = 0
      const unsubscribeFirst: () => void = clock.subscribe(() => {
        unsubscribeFirst()
      })
      clock.subscribe(() => {
        secondCalls += 1
      })
      clock.seek(10000)
      const afterFirst = secondCalls
      clock.seek(20000)
      return firstError([
        expectNumber(afterFirst, 1, '本轮快照里两个都收到'),
        expectNumber(secondCalls, 2, '下一轮只剩第二个')
      ])
    }
  })

  cases.push({
    name: 'TimelineClock: 快照是独立对象，外部修改不回写时钟',
    run: (): string => {
      const clock = clockWith(60000)
      clock.seek(10000)
      const snapshot: ClockSnapshot = clock.getSnapshot()
      snapshot.playheadMs = 99999
      snapshot.durationMs = 1
      snapshot.playing = true
      return firstError([
        expectNumber(clock.getPlayheadMs(), 10000, 'playheadMs 不受影响'),
        expectNumber(clock.getDurationMs(), 60000, 'durationMs 不受影响'),
        expectFalse(clock.isPlaying(), 'playing 不受影响')
      ])
    }
  })

  cases.push({
    name: 'TimelineClock: release 清空订阅者并复位播放/拖动状态',
    run: (): string => {
      const clock = clockWith(60000)
      let emissions = 0
      clock.subscribe(() => {
        emissions += 1
      })
      clock.setPlaying(true)
      clock.setDragPreview(20000)
      const beforeRelease = emissions
      clock.release()
      clock.seek(30000)
      return firstError([
        expectTrue(beforeRelease > 0, 'release 前有广播'),
        expectNumber(emissions, beforeRelease, 'release 后不再广播'),
        expectFalse(clock.isPlaying(), 'playing 复位'),
        expectFalse(clock.isDragging(), 'dragging 复位')
      ])
    }
  })

  cases.push({
    name: 'TimelineClock: 拖动预览值同样被总时长钳制',
    run: (): string => {
      const clock = clockWith(60000)
      clock.setDragPreview(999999)
      const clamped = clock.getVisibleMs()
      clock.setDuration(20000)
      return firstError([
        expectNumber(clamped, 60000, '预览值越界截断'),
        expectNumber(clock.getVisibleMs(), 20000, '时长收窄后预览值跟着收窄')
      ])
    }
  })

  return cases
}
