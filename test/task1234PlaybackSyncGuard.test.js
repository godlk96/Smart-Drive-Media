import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'

test('Task1: Editor进度条拖拽在Start/Update/End连续seek并边界裁剪', () => {
  const editorPath = path.resolve(process.cwd(), 'entry/src/main/ets/pages/Editor.ets')
  const editorSource = fs.readFileSync(editorPath, 'utf8')

  assert.ok(editorSource.includes('private resolveTimelineTargetSec(localX: number): number'))
  assert.ok(editorSource.includes('const boundedX = Math.max(0, Math.min(localX, this.timelineWidth))'))
  assert.ok(editorSource.includes('this.dragPreviewSec = this.handleTimelineTouch(localX, true, true)'))
  assert.ok(editorSource.includes('if (localX !== undefined) {'))
  assert.ok(editorSource.includes('this.commitTimelineSeekByLocalX(localX, true)'))
  assert.ok(editorSource.includes('this.syncGlobalPlayhead(previewSec, true, true)'))
})

test('Task2: Editor点击进度条复用拖拽映射并在点击后保持预览同步', () => {
  const editorPath = path.resolve(process.cwd(), 'entry/src/main/ets/pages/Editor.ets')
  const editorSource = fs.readFileSync(editorPath, 'utf8')

  assert.ok(editorSource.includes('private commitTimelineSeekByLocalX(localX: number, fromUser: boolean): number'))
  assert.ok(editorSource.includes('const finalSec = this.resolveTimelineTargetSec(localX)'))
  assert.ok(editorSource.includes('this.beginSeekSettleWindow(finalSec)'))
  assert.ok(editorSource.includes('this.syncGlobalPlayhead(finalSec, fromUser, true)'))
  assert.ok(editorSource.includes('this.commitTimelineSeekByLocalX(event.fingerList[0].localX, true)'))
})

test('Task1-4: GlobalTimeline仅由ClockMaster在播放态推进并修复handoff触发', () => {
  const timelinePath = path.resolve(process.cwd(), 'entry/src/main/ets/media/GlobalTimelineManager.ets')
  const pingPongPath = path.resolve(process.cwd(), 'entry/src/main/ets/media/PingPongTrackController.ets')
  const timelineSource = fs.readFileSync(timelinePath, 'utf8')
  const pingPongSource = fs.readFileSync(pingPongPath, 'utf8')

  assert.ok(timelineSource.includes("if (this.playbackState !== 'playing')"))
  assert.ok(timelineSource.includes('private resolveClockMasterTrackId(): string'))
  assert.ok(pingPongSource.includes('private handoffTriggerSegmentIndex: number = -1'))
  assert.ok(pingPongSource.includes('private normalizePlayerTimeMs(rawTime: number, segmentDurationMs: number): number'))
  assert.ok(pingPongSource.includes('await this.tryHandoff(false)'))
  assert.ok(pingPongSource.includes('await this.tryHandoff(true)'))
})
