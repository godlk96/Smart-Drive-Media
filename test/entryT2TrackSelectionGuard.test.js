import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'

const modelsPath = path.resolve(process.cwd(), 'entry/src/main/ets/model/Models.ets')
const exportServicePath = path.resolve(process.cwd(), 'entry/src/main/ets/service/ExportService.ets')

test('entry T2 ffmpeg policy keeps Right as back track first candidate', () => {
  const source = fs.readFileSync(modelsPath, 'utf8')
  assert.ok(
    source.includes('backTrackCandidates: [CameraPosition.RIGHT, CameraPosition.RIGHT_FRONT, CameraPosition.REAR, CameraPosition.LEFT]')
  )
  assert.ok(source.includes("{ slotId: 'top', x: 0, y: 0, width: 1, height: 0.6667 }"))
  assert.ok(source.includes("{ slotId: 'bottomLeft', x: 0, y: 0.6667, width: 0.5, height: 0.3333 }"))
  assert.ok(source.includes("{ slotId: 'bottomRight', x: 0.5, y: 0.6667, width: 0.5, height: 0.3333 }"))
})

test('entry T2 track selection does not let nativeBack override bottom right', () => {
  const source = fs.readFileSync(exportServicePath, 'utf8')
  assert.ok(source.includes("const isT2Template = definition.templateId === 'T2'"))
  assert.ok(source.includes('!ffmpegPolicy.ignoreNativeTrackSelection && !isT2Template && nativeBackUris.length > 0'))
  assert.ok(source.includes('selection.backUris = pickTrackUris(clips, backCandidates)'))
})

test('entry T5 preview binding uses single front full-screen slot', () => {
  const source = fs.readFileSync(modelsPath, 'utf8')
  assert.ok(source.includes("templateId: TemplateId.T5"))
  assert.ok(source.includes("title: '单前视'"))
  assert.ok(source.includes("{ slotId: 'top', camera: CameraPosition.FRONT }"))
  assert.ok(source.includes("{ slotId: 'top', x: 0, y: 0, width: 1, height: 1 }"))
  assert.ok(source.includes('optionalCameras: []'))
  assert.ok(source.includes('needSideTrack: false'))
  assert.ok(source.includes('sideTrackCandidates: []'))
  assert.ok(source.includes('alignSideByFrontTimeline: false'))
})
