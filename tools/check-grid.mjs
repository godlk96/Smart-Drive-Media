/**
 * 用真实时间戳复算"墙钟网格"，核对一个矛盾：
 *   日志里 09-11 16:58:56 的切片播完（end=60000）后，立刻载入了 09-12 12:02:03 的切片，
 *   像是"第 2 个槽位就在 60s"。但按 buildTimeGrid 的墙钟 min/max 语义，
 *   这两个时间戳相隔约 19 小时，第二个切片应该落在 ~68,580,000ms 的槽位。
 * 如果这里算出的是 19 小时网格，那说明真机上的时间戳并不是文件名里的日期时间
 *   （或真机跑的代码与我读到的不同），必须先弄清楚再解读那份日志。
 *
 * 用法：node tools/check-grid.mjs
 */

import { existsSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const ROOT = resolve(import.meta.dirname, '..')
const MATH = join(ROOT, '.offline-test-build/entry/src/main/ets/media/TimelineMath.mjs')
if (!existsSync(MATH)) {
  console.error('先运行 node tools/offline-test.mjs')
  process.exit(1)
}
const { buildTimeGrid, buildSegmentSpans, segmentAt, SLICE_MS } = await import(
  pathToFileURL(MATH).href
)

function clip(camera, isoText, uri) {
  return {
    fileName: uri,
    uri: uri,
    date: isoText.slice(0, 10),
    time: isoText.slice(11),
    camera: camera,
    timestamp: new Date(isoText).getTime()
  }
}

function report(label, isoA, isoB) {
  const a = new Date(isoA).getTime()
  const b = new Date(isoB).getTime()
  const clips = [
    clip('Front', isoA, 'A_front.mp4'),
    clip('Front', isoB, 'B_front.mp4')
  ]
  const grid = buildTimeGrid(clips)
  const spans = buildSegmentSpans(clips, 'Front', grid)
  const diffMin = (b - a) / 60000
  console.log(`\n=== ${label} ===`)
  console.log(`时间戳间隔 = ${diffMin.toFixed(1)} 分钟`)
  console.log(`grid.startMs=${grid.startMs} sliceCount=${grid.sliceCount} durationMs=${grid.durationMs} (${(grid.durationMs / 3600000).toFixed(1)} 小时)`)
  for (let i = 0; i < spans.length; i++) {
    console.log(`  span[${i}] startMs=${spans[i].startMs} durationMs=${spans[i].durationMs} uri=${spans[i].uri}`)
  }
  const t = segmentAt(spans, 60000)
  console.log(`segmentAt(60000) → kind=${t.kind} index=${t.index} offset=${t.offsetMs}`)
  const t2 = segmentAt(spans, 60001)
  console.log(`segmentAt(60001) → kind=${t2.kind} index=${t2.index}`)
  return { grid, spans }
}

console.log('SLICE_MS =', SLICE_MS)
report('日志里的那一对：09-11 16:58:56 → 09-12 12:02:03', '2026-09-11T16:58:56', '2026-09-12T12:02:03')
report('对照：真正相邻的两分钟（03-06 22:20:38 → 22:21:38）', '2026-03-06T22:20:38', '2026-03-06T22:21:38')
