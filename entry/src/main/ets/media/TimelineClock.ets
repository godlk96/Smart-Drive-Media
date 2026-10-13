/**
 * TimelineClock —— 预览页**唯一**的时间源。
 *
 * 设计原则（对应 docs/预览播放器简化重构方案.md 三.1）：
 *   - 全局只有一个 playheadMs，UI 只是它的订阅者；
 *   - 拖动期间由 dragPreviewMs 提供"预览值"，**绝不动任何 player**；
 *   - 松手只调用一次 seek()，因此不存在"被旧回调拽回去"；
 *   - 唯一能让播放头倒退的入口是 seek()，advanceFromMaster() 只允许前进。
 *
 * 这个文件刻意不依赖任何 @ohos / ArkUI 能力，因此可被离线单测覆盖
 * （见 tools/offline-test.mjs 与 ohosTest/ets/test/TimelineClockCases.ets）。
 *
 * 关于"迟到的进度回调"：
 *   时钟只能拒绝**倒退**。从旧位置迟到的**前进**回调（例如 seek 到 5s 后
 *   旧位置 55s 的 timeUpdate 才到）无法在这里区分——那必须由对账器负责：
 *   切段/seek 期间该轨不上报进度，只有目标段真正就绪后才恢复上报。
 *   seekGeneration() 就是给对账器用的"轮次"标记。
 */

import { clampMs } from './TimelineMath'

/** 时钟状态的一次快照。每次变更都会产生一个新对象（避免外部持有可变引用）。 */
export class ClockSnapshot {
  playheadMs: number = 0
  durationMs: number = 0
  playing: boolean = false
  rate: number = 1
  dragging: boolean = false
}

export class TimelineClock {
  private playheadMs: number = 0
  private durationMs: number = 0
  private playing: boolean = false
  private rate: number = 1
  private dragging: boolean = false
  private dragPreviewMs: number = 0
  private seekGeneration: number = 0
  private listeners: Array<(snapshot: ClockSnapshot) => void> = []

  getPlayheadMs(): number {
    return this.playheadMs
  }

  getDurationMs(): number {
    return this.durationMs
  }

  isPlaying(): boolean {
    return this.playing
  }

  getRate(): number {
    return this.rate
  }

  isDragging(): boolean {
    return this.dragging
  }

  /** 每次 seek() 自增。对账器用它丢弃"上一轮 seek 期间"产生的迟到回调。 */
  getSeekGeneration(): number {
    return this.seekGeneration
  }

  /** UI 唯一读入口：拖动时显示预览值，否则显示真实值。 */
  getVisibleMs(): number {
    return this.dragging ? this.dragPreviewMs : this.playheadMs
  }

  getSnapshot(): ClockSnapshot {
    const snapshot = new ClockSnapshot()
    snapshot.playheadMs = this.getVisibleMs()
    snapshot.durationMs = this.durationMs
    snapshot.playing = this.playing
    snapshot.rate = this.rate
    snapshot.dragging = this.dragging
    return snapshot
  }

  /** 订阅时钟变化，返回取消订阅函数。 */
  subscribe(listener: (snapshot: ClockSnapshot) => void): () => void {
    this.listeners.push(listener)
    return () => {
      const index = this.listeners.indexOf(listener)
      if (index >= 0) {
        this.listeners.splice(index, 1)
      }
    }
  }

  /**
   * 设置总时长。**不**改变播放/拖动状态，只做钳制后广播。
   * 时长变化时播放头必须跟着收窄，否则会出现"播放头在总时长之外"的幽灵状态。
   */
  setDuration(durationMs: number): void {
    const next = durationMs > 0 ? durationMs : 0
    const changed = next !== this.durationMs || this.playheadMs > next
    this.durationMs = next
    if (this.playheadMs > next) {
      this.playheadMs = next
    }
    if (this.dragging && this.dragPreviewMs > next) {
      this.dragPreviewMs = next
    }
    if (changed) {
      this.emit()
    }
  }

  /**
   * 唯一的跳转入口。拖动松手、点击进度条、切片段、切模板全走这里。
   * 它会**结束拖动**，因为一次 seek 就意味着"预览值已被采纳为真实值"。
   */
  seek(ms: number): void {
    const next = clampMs(ms, this.durationMs)
    this.seekGeneration += 1
    this.dragging = false
    this.dragPreviewMs = next
    this.playheadMs = next
    this.emit()
  }

  /** 拖拽中：只改 UI 预览值，绝不动任何 player。 */
  setDragPreview(ms: number): void {
    const next = clampMs(ms, this.durationMs)
    const changed = !this.dragging || next !== this.dragPreviewMs
    this.dragging = true
    this.dragPreviewMs = next
    if (changed) {
      this.emit()
    }
  }

  /**
   * 取消拖动（手势被系统打断、组件销毁等）。
   * 播放头回到真实值，不产生 seek —— 因为用户并没有"确认"这个位置。
   */
  cancelDrag(): void {
    if (!this.dragging) {
      return
    }
    this.dragging = false
    this.emit()
  }

  /**
   * 唯一的"自动推进"入口：只有主轨的 timeUpdate 调它。
   * 只接受**前进**：正常向前播放时播放头永不倒退，倒退只能来自 seek()。
   * 这条不变式让"被旧回调拽回去"这一类 bug 在时钟层就消失。
   */
  advanceFromMaster(globalMs: number): void {
    if (!this.playing || this.dragging) {
      return
    }
    const next = clampMs(globalMs, this.durationMs)
    if (next <= this.playheadMs) {
      return
    }
    this.playheadMs = next
    this.emit()
  }

  setPlaying(playing: boolean): void {
    if (this.playing === playing) {
      return
    }
    this.playing = playing
    this.emit()
  }

  setRate(rate: number): void {
    const next = rate > 0 ? rate : 1
    if (this.rate === next) {
      return
    }
    this.rate = next
    this.emit()
  }

  /** 释放：清空订阅者。避免页面销毁后仍被回调持有。 */
  release(): void {
    this.listeners = []
    this.dragging = false
    this.playing = false
  }

  private emit(): void {
    const snapshot = this.getSnapshot()
    const listeners = this.listeners.slice()
    for (let i = 0; i < listeners.length; i++) {
      listeners[i](snapshot)
    }
  }
}
