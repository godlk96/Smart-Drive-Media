import test from 'node:test'
import assert from 'node:assert/strict'
import { MultiTrackEditorSession } from '../src/logic/multiTrackEditorSession.js'
import { CameraPosition } from '../src/model/types.js'
import { assembleVirtualClip } from '../src/logic/virtualTimeline.js'
import { buildTranscodeCommand } from '../src/logic/ffmpegPlanner.js'

function createSegment(startSecond, duration, filePath) {
  return {
    filePath,
    fileName: filePath,
    startTime: new Date(`2026-03-10T08:${String(startSecond).padStart(2, '0')}:00.000Z`),
    duration
  }
}

test('Task5: 双播放器轮转预加载并在跨边界seek时稳定切换', () => {
  const session = new MultiTrackEditorSession()
  session.loadTrip({
    videoTracks: [
      {
        cameraPosition: CameraPosition.FRONT,
        segments: [
          createSegment(0, 20, 'front-a.mp4'),
          createSegment(20, 20, 'front-b.mp4'),
          createSegment(40, 20, 'front-c.mp4')
        ]
      }
    ]
  })

  session.seekTo(18_000)
  const beforeBoundary = session.getSeamlessPlaybackState()
  assert.equal(beforeBoundary.activeFileId.includes('front-a.mp4'), true)
  assert.equal(beforeBoundary.preloadedNextFileId.includes('front-b.mp4'), true)

  session.seekTo(20_100)
  const afterBoundary = session.getSeamlessPlaybackState()
  assert.equal(afterBoundary.activeFileId.includes('front-b.mp4'), true)
  assert.equal(afterBoundary.preloadedNextFileId.includes('front-c.mp4'), true)
  assert.equal(afterBoundary.swapCount >= 1, true)
})

test('Task5: 跨文件30秒选区导出使用inpoint/outpoint拼接', () => {
  const clip = assembleVirtualClip([
    {
      id: 'a',
      filePath: 'front-a.mp4',
      fileName: 'front-a.mp4',
      startTime: new Date('2026-03-10T08:00:00.000Z'),
      duration: 20
    },
    {
      id: 'b',
      filePath: 'front-b.mp4',
      fileName: 'front-b.mp4',
      startTime: new Date('2026-03-10T08:00:20.000Z'),
      duration: 20
    },
    {
      id: 'c',
      filePath: 'front-c.mp4',
      fileName: 'front-c.mp4',
      startTime: new Date('2026-03-10T08:00:40.000Z'),
      duration: 20
    }
  ], { id: 'task5-clip' })

  const slices = clip.splitRangeIntoFileSlices(15_000, 45_000)
  const totalDurationMs = slices.reduce((sum, item) => sum + item.durationMs, 0)
  assert.equal(totalDurationMs, 30_000)
  assert.deepEqual(slices.map(item => item.fileId), ['a', 'b', 'c'])

  const command = buildTranscodeCommand({
    inputFiles: [],
    outputPath: 'out.mp4',
    privacyPlan: {
      mode: 'overlay',
      overlayMasks: [],
      cropExpression: 'crop=in_w:in_h:0:0'
    },
    socialShareMode: false,
    layoutMode: 'scenario_template',
    templateId: 'T2',
    trackInputs: {
      Front: slices.map(item => ({
        filePath: item.filePath,
        inpointMs: item.inpointMs,
        outpointMs: item.outpointMs
      }))
    }
  })

  assert.equal(command.type, 'transcode')
  assert.equal(Array.isArray(command.concatFiles), true)
  assert.equal(command.concatFiles.length, 1)
  assert.equal(command.concatFiles[0].content.includes('inpoint 15.000'), true)
  assert.equal(command.concatFiles[0].content.includes('outpoint 20.000'), true)
  assert.equal(command.concatFiles[0].content.includes("file 'front-b.mp4'"), true)
  assert.equal(command.concatFiles[0].content.includes("file 'front-c.mp4'"), true)
})
