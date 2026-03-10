import test from 'node:test'
import assert from 'node:assert/strict'
import { buildStreamCopyCommand, buildTranscodeCommand } from '../src/logic/ffmpegBuilder.js'

test('buildStreamCopyCommand creates concat + copy args', () => {
  const command = buildStreamCopyCommand(['a.mp4', 'b.mp4'], 'out.mp4')
  assert.equal(command.type, 'stream_copy')
  assert.equal(command.concatFileContent.includes("file 'a.mp4'"), true)
  assert.equal(command.args.includes('-c'), true)
  assert.equal(command.args.includes('copy'), true)
})

test('buildTranscodeCommand creates privacy filter args', () => {
  const command = buildTranscodeCommand({
    inputFiles: ['a.mp4'],
    outputPath: 'out.mp4',
    privacyPlan: {
      mode: 'overlay',
      overlayMasks: [{ x: 0.1, y: 0.9, w: 0.2, h: 0.08 }],
      cropExpression: 'crop=in_w:in_h*0.85:0:0'
    },
    socialShareMode: true,
    exportControls: {
      speed: '8.0X',
      muted: false,
      watermarkEnabled: true
    }
  })

  assert.equal(command.type, 'transcode')
  assert.equal(command.args.includes('-vf'), true)
  assert.equal(command.args.includes('6M'), true)
  assert.equal(command.args.includes('-an'), true)
  assert.equal(command.args.some(item => String(item).includes('setpts=PTS/8.00')), true)
  assert.equal(command.args.some(item => String(item).includes('Shot on AITO')), true)
})

test('buildTranscodeCommand creates front back stack args', () => {
  const command = buildTranscodeCommand({
    inputFiles: ['front1.mp4', 'front2.mp4'],
    secondaryInputFiles: ['back1.mp4', 'back2.mp4'],
    outputPath: 'out.mp4',
    privacyPlan: {
      mode: 'overlay',
      overlayMasks: [],
      cropExpression: 'crop=in_w:in_h:0:0'
    },
    socialShareMode: false,
    layoutMode: 'front_back_stack'
  })

  assert.equal(command.type, 'transcode')
  assert.equal(Array.isArray(command.concatFiles), true)
  assert.equal(command.concatFiles.length, 2)
  assert.equal(command.args.includes('-filter_complex'), true)
  assert.equal(command.args.some(item => String(item).includes('vstack=inputs=2')), true)
})

test('buildTranscodeCommand creates scenario template filter_complex args', () => {
  const command = buildTranscodeCommand({
    inputFiles: ['front.mp4'],
    outputPath: 'out.mp4',
    privacyPlan: {
      mode: 'overlay',
      overlayMasks: [{ x: 0.05, y: 0.9, w: 0.2, h: 0.08 }],
      cropExpression: 'crop=in_w:in_h:0:0'
    },
    socialShareMode: false,
    layoutMode: 'scenario_template',
    templateId: 'T4',
    exportControls: {
      speed: '4.0X',
      muted: false,
      watermarkEnabled: true
    },
    trackInputs: {
      LeftFront: ['lf.mp4'],
      Front: ['front.mp4'],
      RightFront: ['rf.mp4']
    }
  })

  assert.equal(command.type, 'transcode')
  assert.equal(command.args.includes('-filter_complex'), true)
  assert.equal(command.args.includes('[v_out]'), true)
  assert.equal(command.args.some(item => String(item).includes('color=c=black:s=1080x1920')), true)
  assert.equal(command.args.some(item => String(item).includes('drawbox=x=')), true)
  assert.equal(command.args.includes('-an'), true)
})
