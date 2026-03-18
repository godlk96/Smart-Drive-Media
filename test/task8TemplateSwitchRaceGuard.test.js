import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'

const editorPreviewAreaPath = path.resolve(process.cwd(), 'entry/src/main/ets/components/EditorPreviewArea.ets')
const editorPagePath = path.resolve(process.cwd(), 'entry/src/main/ets/pages/Editor.ets')

test('Task8: surface握手完成后再触发prepared/playing阶段回调', () => {
  const source = fs.readFileSync(editorPreviewAreaPath, 'utf8')
  assert.equal(source.includes('private startSurfaceHandshake(renderItems: Array<TrackRenderItem>): void'), true)
  assert.equal(source.includes('private waitSurfaceHandshake(timeoutMs: number): Promise<void>'), true)
  assert.equal(source.includes('onSurfaceReady: () => this.markTrackSurfaceReady(item.key)'), true)

  const waitIndex = source.indexOf('await this.waitSurfaceHandshake(1800)')
  const playingStageIndex = source.indexOf("this.notifyTemplateSwitchStageReady(currentTaskId, 'playing')")
  const preparedStageIndex = source.indexOf("this.notifyTemplateSwitchStageReady(currentTaskId, 'prepared')")
  assert.equal(waitIndex >= 0, true)
  assert.equal(playingStageIndex > waitIndex, true)
  assert.equal(preparedStageIndex > waitIndex, true)
})

test('Task8: 模板切换存在finally超时解锁与乱序回调防护', () => {
  const source = fs.readFileSync(editorPagePath, 'utf8')
  assert.equal(source.includes('private startTemplateSwitchPreparedWatchdog(taskId: number): void'), true)
  assert.equal(source.includes('private resolveTemplateSwitchPreparedWait(taskId: number): void'), true)
  assert.equal(source.includes('if (waitPreviewPrepared) {'), true)
  assert.equal(source.includes('this.startTemplateSwitchPreparedWatchdog(taskId)'), true)
  assert.equal(source.includes('if (taskId <= 0 || taskId !== this.switchTaskId) {'), true)
})
