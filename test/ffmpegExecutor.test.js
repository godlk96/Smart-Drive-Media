import test from 'node:test'
import assert from 'node:assert/strict'
import { FfmpegExecutor, parseFfmpegProgress } from '../src/logic/ffmpegExecutor.js'

test('parseFfmpegProgress parses time and calculates percent', () => {
  const line = 'frame= 152 fps=25 q=23.0 size=2048kB time=00:00:30.50 bitrate=550.0kbits/s'
  const progress = parseFfmpegProgress(line, 60)
  assert.equal(progress, 50)
})

test('FfmpegExecutor rewrites concat path and emits progress', async () => {
  const records = {
    concatContent: '',
    removedPath: '',
    args: [],
    progresses: []
  }
  const executor = new FfmpegExecutor({
    async createConcatFile(content) {
      records.concatContent = content
      return 'C:/tmp/concat-real.txt'
    },
    async removeFile(filePath) {
      records.removedPath = filePath
    },
    async runProcess({ args, onStdErrLine }) {
      records.args = args
      onStdErrLine('frame=10 time=00:00:05.00')
      onStdErrLine('frame=20 time=00:00:10.00')
    }
  })

  const command = {
    type: 'stream_copy',
    concatFileContent: "file 'a.mp4'\nfile 'b.mp4'",
    args: ['-f', 'concat', '-safe', '0', '-i', 'concat.txt', '-c', 'copy', 'out.mp4']
  }

  await executor.execute(command, {
    totalDurationSec: 20,
    onProgress: value => records.progresses.push(value)
  })

  assert.equal(records.concatContent.length > 0, true)
  assert.equal(records.args.includes('C:/tmp/concat-real.txt'), true)
  assert.equal(records.removedPath, 'C:/tmp/concat-real.txt')
  assert.deepEqual(records.progresses, [0, 25, 50, 100])
})

test('FfmpegExecutor supports multiple concat placeholders', async () => {
  const records = {
    created: [],
    removed: [],
    args: []
  }
  const executor = new FfmpegExecutor({
    async createConcatFile(content) {
      const index = records.created.length + 1
      const path = `C:/tmp/concat-${index}.txt`
      records.created.push({ content, path })
      return path
    },
    async removeFile(filePath) {
      records.removed.push(filePath)
    },
    async runProcess({ args }) {
      records.args = args
    }
  })

  await executor.execute(
    {
      type: 'transcode',
      concatFiles: [
        { placeholder: 'concat_front.txt', content: "file 'f1.mp4'" },
        { placeholder: 'concat_back.txt', content: "file 'b1.mp4'" }
      ],
      args: ['-i', 'concat_front.txt', '-i', 'concat_back.txt', 'out.mp4']
    },
    { totalDurationSec: 1 }
  )

  assert.equal(records.args.includes('C:/tmp/concat-1.txt'), true)
  assert.equal(records.args.includes('C:/tmp/concat-2.txt'), true)
  assert.deepEqual(records.removed, ['C:/tmp/concat-1.txt', 'C:/tmp/concat-2.txt'])
})
