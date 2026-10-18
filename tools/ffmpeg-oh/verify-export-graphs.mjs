import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdirSync } from 'node:fs'
import { resolve } from 'node:path'
import { performance } from 'node:perf_hooks'

const root = resolve(import.meta.dirname, '../..')
const toWsl = path => path.replaceAll('\\', '/').replace(/^([A-Za-z]):/, (_, drive) => `/mnt/${drive.toLowerCase()}`)
const repo = toWsl(root)
const ffroot = process.env.EXPORT_FFMPEG_ROOT ?? '/home/gzr/ffx86-src'
const sample = toWsl(resolve(process.argv[2] ?? `${root}/media_resource/DVR_LoopRecording_2026-09-11_16-58-56_front_camera.mp4`))
mkdirSync(resolve(root, 'local-artifacts/export-validation'), { recursive: true })
const run = (args, options = {}) => {
  const result = spawnSync('wsl.exe', ['--exec', ...args], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, ...options })
  assert.equal(result.status, 0, result.stderr || result.error?.message || result.stdout)
  return result.stdout
}
const executable = `${repo}/local-artifacts/export-validation/export-graph-test`
run(['g++', '-std=c++17', '-O1', '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections',
  `-I${repo}/tools/ffmpeg-oh/test-include`, `-I${ffroot}`, `${repo}/tools/ffmpeg-oh/export-graph-test.cpp`,
  '-o', executable,
  ...['avfilter', 'avformat', 'avcodec', 'swscale', 'swresample', 'avutil'].map(lib => `${ffroot}/lib${lib}/lib${lib}.a`),
  '-pthread', '-ldl', '-lm'])
console.log(run([`${ffroot}/ffmpeg`, '-version']).split('\n')[0])
const graphs = run([executable, sample, `${repo}/local-artifacts/export-validation/repeated-input.mp4`])
  .trim().split('\n').map(line => line.split('\t'))
  .filter(([name]) => !process.env.EXPORT_GRAPH_MATCH || new RegExp(process.env.EXPORT_GRAPH_MATCH).test(name))
assert.ok(graphs.length > 0, 'No matching graphs')
console.log('PASS native queued cancellation and concat byte progress')
for (const [name, kind, graph] of graphs) {
  if (kind === 'audio') assert.doesNotMatch(graph, /:seek_point=/, 'AAC samples must retain their decode history')
  const baseline = graph.replace(/:seek_point=[0-9.e+-]+/g, '').replace(/:dec_threads=[0-9]+/g, '')
  const output = []
  const elapsed = []
  for (const value of [baseline, graph]) {
    const start = performance.now()
    const lines = run([`${ffroot}/ffmpeg`, '-hide_banner', '-loglevel', 'error', '-filter_complex_threads', '4',
      '-filter_complex', kind === 'video' ? `sws_flags=bicubic+accurate_rnd+bitexact;${value}` : value, '-map', kind === 'video' ? '[outv]' : '[outa]',
      '-f', kind === 'video' ? 'framemd5' : 'hash', '-'])
    output.push(lines.split('\n').filter(line => line.length > 0 && !line.startsWith('#')).join('\n'))
    elapsed.push(((performance.now() - start) / 1000).toFixed(3))
  }
  assert.ok(output[0].length > 0, `${name} ${kind}: empty output`)
  if (kind === 'video' && output[1] !== output[0]) {
    const diagnosticGraphs = [baseline, graph.replace(/:seek_point=[0-9.e+-]+/g, '')]
    const hashes = diagnosticGraphs.map(value => run([`${ffroot}/ffmpeg`, '-hide_banner', '-loglevel', 'error',
      '-filter_complex_threads', '4', '-filter_complex', `sws_flags=bicubic+accurate_rnd+bitexact;${value}`, '-map', '[outv]', '-f', 'framemd5', '-'])
      .split('\n').filter(line => line.length > 0 && !line.startsWith('#')).join('\n'))
    console.log('Video diagnostic:', { baselineRepeatIdentical: hashes[0] === output[0],
      sameThreadsSeekIdentical: hashes[1] === output[1], sameThreadsBaselineIdentical: hashes[1] === output[0] })
  }
  if (kind === 'audio' && output[1] !== output[0]) {
    const samples = [baseline, graph].map(value => {
      const result = spawnSync('wsl.exe', ['--exec', `${ffroot}/ffmpeg`, '-hide_banner', '-loglevel', 'error',
        '-filter_complex', value, '-map', '[outa]', '-f', 'f32le', '-'], { maxBuffer: 16 * 1024 * 1024 })
      assert.equal(result.status, 0, result.stderr.toString())
      return result.stdout
    })
    let maximumDifference = 0
    let firstDifference = -1
    let changedSamples = 0
    for (let offset = 0; offset < Math.min(samples[0].length, samples[1].length); offset += 4) {
      const difference = Math.abs(samples[0].readFloatLE(offset) - samples[1].readFloatLE(offset))
      if (difference > 0) {
        if (firstDifference < 0) firstDifference = offset / 4
        changedSamples++
        maximumDifference = Math.max(maximumDifference, difference)
      }
    }
    console.log('Audio diagnostic:', { bytes: samples.map(value => value.length), firstDifference, changedSamples, maximumDifference })
  }
  assert.equal(output[1], output[0], `${name} ${kind}: content or timestamps changed`)
  console.log(`PASS ${name} ${kind}: identical; baseline=${elapsed[0]}s seek=${elapsed[1]}s`)
}
console.log(`Actual export filter graphs: ${graphs.length}/${graphs.length} passed`)
