import test from 'node:test'
import assert from 'node:assert/strict'
import { assembleVirtualClip } from '../src/logic/virtualTimeline.js'

function createSegment({ id, fileName, secondOffset, duration }) {
  return {
    id,
    fileName,
    filePath: `/clips/${fileName}`,
    startTime: new Date(`2026-03-10T10:00:${String(secondOffset).padStart(2, '0')}.000Z`),
    duration
  }
}

test('assembleVirtualClip 按开始时间拼接并计算总时长', () => {
  const clip = assembleVirtualClip([
    createSegment({ id: 'b', fileName: 'b.mp4', secondOffset: 10, duration: 15 }),
    createSegment({ id: 'a', fileName: 'a.mp4', secondOffset: 0, duration: 10 }),
    createSegment({ id: 'c', fileName: 'c.mp4', secondOffset: 30, duration: 5 })
  ], { id: 'clip-1' })

  assert.equal(clip.id, 'clip-1')
  assert.equal(clip.sourceFiles.length, 3)
  assert.deepEqual(clip.sourceFiles.map(item => item.id), ['a', 'b', 'c'])
  assert.equal(clip.totalDurationMs, 30_000)
  assert.equal(clip.totalDuration, 30)
})

test('VirtualClip.mapTime 返回逻辑到物理映射并识别边界', () => {
  const clip = assembleVirtualClip([
    createSegment({ id: 'seg-a', fileName: 'a.mp4', secondOffset: 0, duration: 12 }),
    createSegment({ id: 'seg-b', fileName: 'b.mp4', secondOffset: 12, duration: 8 })
  ], { id: 'clip-2' })

  const middle = clip.mapTime(15_000)
  assert.equal(middle.file.id, 'seg-b')
  assert.equal(middle.offsetMs, 3_000)
  assert.equal(middle.atBoundary, false)

  const boundary = clip.mapTime(12_000)
  assert.equal(boundary.file.id, 'seg-b')
  assert.equal(boundary.offsetMs, 0)
  assert.equal(boundary.atBoundary, true)
  assert.equal(boundary.boundary.previousFileId, 'seg-a')
  assert.equal(boundary.boundary.nextFileId, 'seg-b')
})

test('VirtualClip.calculateRange 计算选区时长时间码和边界元数据', () => {
  const clip = assembleVirtualClip([
    createSegment({ id: 'seg-1', fileName: '1.mp4', secondOffset: 0, duration: 10 }),
    createSegment({ id: 'seg-2', fileName: '2.mp4', secondOffset: 10, duration: 10 }),
    createSegment({ id: 'seg-3', fileName: '3.mp4', secondOffset: 20, duration: 10 })
  ], { id: 'clip-3' })

  const range = clip.calculateRange(25_000, 5_000)
  assert.equal(range.startMs, 5_000)
  assert.equal(range.endMs, 25_000)
  assert.equal(range.durationMs, 20_000)
  assert.equal(range.startTimecode, '00:05')
  assert.equal(range.endTimecode, '00:25')
  assert.equal(range.durationTimecode, '00:20')
  assert.equal(range.startMapping.file.id, 'seg-1')
  assert.equal(range.endMapping.file.id, 'seg-3')
  assert.equal(range.coversBoundary, true)
  assert.deepEqual(range.boundaryMarkers.map(item => item.logicalTimeMs), [10_000, 20_000])
})

test('VirtualClip.splitRangeIntoFileSlices 返回跨边界切片与inpoint/outpoint', () => {
  const clip = assembleVirtualClip([
    createSegment({ id: 'seg-a', fileName: 'a.mp4', secondOffset: 0, duration: 20 }),
    createSegment({ id: 'seg-b', fileName: 'b.mp4', secondOffset: 20, duration: 20 })
  ], { id: 'clip-4' })
  const slices = clip.splitRangeIntoFileSlices(15_000, 45_000)
  assert.equal(slices.length, 2)
  assert.equal(slices[0].fileId, 'seg-a')
  assert.equal(slices[0].inpointMs, 15_000)
  assert.equal(slices[0].outpointMs, 20_000)
  assert.equal(slices[1].fileId, 'seg-b')
  assert.equal(slices[1].inpointMs, 0)
  assert.equal(slices[1].outpointMs, 20_000)
})
