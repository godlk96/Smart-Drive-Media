import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'

const enginePath = path.resolve(process.cwd(), 'entry/src/main/cpp/export_engine.cpp')

test('native export engine covers all four template compose branches', () => {
  const source = fs.readFileSync(enginePath, 'utf8')
  assert.ok(source.includes('normalizeTemplateId'))
  assert.ok(source.includes('templateId == "T1"'))
  assert.ok(source.includes('templateId == "T2"'))
  assert.ok(source.includes('templateId == "T3"'))
  assert.ok(source.includes('templateId == "T4"'))
  assert.ok(source.includes('composeTemplateToMp4'))
  assert.ok(source.includes('template=" + normalizedTemplate'))
})
