import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'

test('Task4/5: 导出快照隔离与TaskPool参数透传到native', () => {
  const exportManagerPath = path.resolve(process.cwd(), 'entry/src/main/ets/service/ExportManager.ets')
  const nativeServicePath = path.resolve(process.cwd(), 'entry/src/main/ets/service/ExportNativeService.ets')
  const napiPath = path.resolve(process.cwd(), 'entry/src/main/cpp/napi_init.cpp')
  const managerSource = fs.readFileSync(exportManagerPath, 'utf8')
  const nativeSource = fs.readFileSync(nativeServicePath, 'utf8')
  const napiSource = fs.readFileSync(napiPath, 'utf8')
  assert.ok(managerSource.includes('cloneExportSnapshot'))
  assert.ok(managerSource.includes('const isolatedSnapshot = cloneExportSnapshot(snapshot)'))
  assert.ok(nativeSource.includes('buildNativeExportPayload'))
  assert.ok(nativeSource.includes('cloneRequestForExportIsolation'))
  assert.ok(nativeSource.includes('const isolatedRequest = cloneRequestForExportIsolation(request)'))
  assert.ok(nativeSource.includes('return deepCloneJson(payload)'))
  assert.equal(nativeSource.includes('frontUris: [...frontInputUris]'), false)
  assert.equal(nativeSource.includes('backUris: [...backInputUris]'), false)
  assert.equal(nativeSource.includes('sideUris: [...sideInputUris]'), false)
  assert.ok(nativeSource.includes('hideTime: request.hideGps'))
  assert.ok(napiSource.includes('request.hideTime'))
  assert.ok(napiSource.includes('"hideTime"'))
})

test('Task4/5: 前摄打码坐标与预览letterboxing映射保持一致', () => {
  const enginePath = path.resolve(process.cwd(), 'entry/src/main/cpp/export_engine.cpp')
  const previewPath = path.resolve(process.cwd(), 'entry/src/main/ets/components/EditorPreviewArea.ets')
  const nativeServicePath = path.resolve(process.cwd(), 'entry/src/main/ets/service/ExportNativeService.ets')
  const engineSource = fs.readFileSync(enginePath, 'utf8')
  const previewSource = fs.readFileSync(previewPath, 'utf8')
  const nativeSource = fs.readFileSync(nativeServicePath, 'utf8')
  assert.ok(engineSource.includes('buildFrontPrivacyMaskChain'))
  assert.ok(engineSource.includes('masks.push_back({0.58, 0.90, 0.34, 0.08});'))
  assert.ok(engineSource.includes('drawbox=x=iw*'))
  assert.ok(previewSource.includes('buildFrontPrivacyMasksBySlot'))
  assert.ok(previewSource.includes("masks.push({ key: 'time', x: 0.58, y: 0.9, width: 0.34, height: 0.08 })"))
  assert.ok(previewSource.includes('contentOffsetY = (1 - contentHeight) / 2'))
  assert.ok(nativeSource.includes('removeMaterializedTempUris'))
  assert.ok(nativeSource.includes('await fs.unlink(uri)'))
})
