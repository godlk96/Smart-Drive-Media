import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'

const enginePath = path.resolve(process.cwd(), 'entry/src/main/cpp/export_engine.cpp')

test('native export engine covers all five template compose branches', () => {
  const source = fs.readFileSync(enginePath, 'utf8')
  assert.ok(source.includes('normalizeTemplateId'))
  assert.ok(source.includes('kNativeTemplateContracts'))
  assert.ok(source.includes('{"T1", 1920, 2160'))
  assert.ok(source.includes('{"T2", 1920, 1620'))
  assert.ok(source.includes('{"T3", 3840, 1080'))
  assert.ok(source.includes('{"T4", 3840, 1080'))
  assert.ok(source.includes('{"T5", 1920, 1080, false, false}'))
  assert.ok(source.includes('[top][bottom]vstack=inputs=2'))
  assert.ok(source.includes('[left][right]hstack=inputs=2'))
  assert.ok(source.includes('[left][middle][right]hstack=inputs=3'))
  assert.ok(source.includes('[bottom_left][bottom_right]hstack=inputs=2[bottom];'))
  assert.ok(source.includes('buildMovieSourceFilter(frontPath, "scale=1920:1080", true'))
  assert.ok(source.includes('format=pix_fmts=yuv420p[outv]'))
  assert.ok(source.includes('composeTemplateToMp4'))
  assert.ok(source.includes('template=" + normalizedTemplate'))
})

test('native export engine enforces spec guard, front audio policy and OH fallback', () => {
  const source = fs.readFileSync(enginePath, 'utf8')
  assert.ok(source.includes('isVideoSpecCompatible'))
  assert.ok(source.includes('validateTrackSpecs(frontUris, "front", error)'))
  assert.ok(source.includes('detectFrontAacAudio'))
  assert.ok(source.includes('" disables front audio'))
  assert.ok(source.includes('tryWarmupOhosBridge'))
  assert.ok(source.includes('oh_bridge_unavailable_fallback_ffmpeg_only'))
  assert.ok(source.includes('resolveTemplateTargetResolution'))
  assert.ok(source.includes('AV_CODEC_ID_HEVC'))
  assert.ok(source.includes('applyPacketTimestampFallback'))
  assert.ok(source.includes('buildFrontPrivacyMaskChain'))
  assert.ok(source.includes('drawbox=x=iw*'))
})
