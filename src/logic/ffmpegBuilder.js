/**
 * (指令员) 负责生成 FFmpeg 命令。如果只是拼接，生成 stream copy 命令；如果要打码，生成滤镜转码命令。
 */
function buildConcatFileList(inputFiles) {
  return inputFiles.map(item => `file '${item}'`).join('\n')
}

function buildOverlayFilter(plan) {
  if (!plan.overlayMasks.length) {
    return plan.cropExpression
  }

  const maskChain = plan.overlayMasks
    .map(mask => {
      const x = `in_w*${mask.x}`
      const y = `in_h*${mask.y}`
      const w = `in_w*${mask.w}`
      const h = `in_h*${mask.h}`
      return `drawbox=x=${x}:y=${y}:w=${w}:h=${h}:color=black:t=fill`
    })
    .join(',')
  return `${maskChain},${plan.cropExpression}`
}

function buildDelogoFilter(plan) {
  if (!plan.overlayMasks.length) {
    return plan.cropExpression
  }
  const chain = plan.overlayMasks
    .map(mask => {
      const x = `in_w*${mask.x}`
      const y = `in_h*${mask.y}`
      const w = `in_w*${mask.w}`
      const h = `in_h*${mask.h}`
      return `delogo=x=${x}:y=${y}:w=${w}:h=${h}`
    })
    .join(',')
  return `${chain},${plan.cropExpression}`
}

export function buildStreamCopyCommand(inputFiles, outputPath) {
  return {
    type: 'stream_copy',
    concatFileContent: buildConcatFileList(inputFiles),
    args: ['-f', 'concat', '-safe', '0', '-i', 'concat.txt', '-c', 'copy', outputPath]
  }
}

export function buildTranscodeCommand({
  inputFiles,
  secondaryInputFiles = [],
  outputPath,
  privacyPlan,
  socialShareMode,
  hardwareEncoder = 'h264_avcodec',
  layoutMode = 'single_track'
}) {
  const filter =
    privacyPlan.mode === 'delogo' ? buildDelogoFilter(privacyPlan) : buildOverlayFilter(privacyPlan)
  const bitrate = socialShareMode ? '6M' : '20M'
  if (layoutMode === 'front_back_stack') {
    return {
      type: 'transcode',
      concatFiles: [
        {
          placeholder: 'concat_front.txt',
          content: buildConcatFileList(inputFiles)
        },
        {
          placeholder: 'concat_back.txt',
          content: buildConcatFileList(secondaryInputFiles)
        }
      ],
      args: [
        '-f',
        'concat',
        '-safe',
        '0',
        '-i',
        'concat_front.txt',
        '-f',
        'concat',
        '-safe',
        '0',
        '-i',
        'concat_back.txt',
        '-filter_complex',
        `[0:v]setpts=PTS-STARTPTS[top];[1:v]setpts=PTS-STARTPTS[bottom];[top][bottom]vstack=inputs=2,${filter}[v]`,
        '-map',
        '[v]',
        '-c:v',
        hardwareEncoder,
        '-b:v',
        bitrate,
        '-preset',
        'fast',
        outputPath
      ]
    }
  }
  return {
    type: 'transcode',
    args: [
      '-i',
      inputFiles[0],
      '-vf',
      filter,
      '-c:v',
      hardwareEncoder,
      '-b:v',
      bitrate,
      '-preset',
      'fast',
      outputPath
    ]
  }
}
