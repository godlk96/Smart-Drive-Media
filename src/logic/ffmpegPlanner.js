import { buildTemplateFilterComplex } from './scenarioTemplateEngine.js'

function buildConcatFileList(inputFiles) {
  return inputFiles
    .map(item => {
      if (typeof item === 'string') {
        return `file '${item}'`
      }
      const lines = [`file '${item?.filePath ?? ''}'`]
      if (Number.isFinite(item?.inpointMs)) {
        lines.push(`inpoint ${(Math.max(0, item.inpointMs) / 1000).toFixed(3)}`)
      }
      if (Number.isFinite(item?.outpointMs)) {
        lines.push(`outpoint ${(Math.max(0, item.outpointMs) / 1000).toFixed(3)}`)
      }
      return lines.join('\n')
    })
    .join('\n')
}

function parseSpeedValue(speedLabel) {
  const speed = Number.parseFloat(String(speedLabel ?? '1.0X').replace(/x$/i, ''))
  if (!Number.isFinite(speed) || speed <= 0) {
    return 1
  }
  return speed
}

function resolveExportControls(exportControls = {}) {
  const speed = parseSpeedValue(exportControls.speed)
  const forcedMuted = speed > 1
  const muted = forcedMuted || Boolean(exportControls.muted)
  const watermarkEnabled = Boolean(exportControls.watermarkEnabled)
  return {
    speed,
    forcedMuted,
    muted,
    watermarkEnabled
  }
}

function buildPostVideoFilters(controls) {
  const filters = []
  if (controls.speed > 1) {
    filters.push(`setpts=PTS/${controls.speed.toFixed(2)}`)
  }
  if (controls.watermarkEnabled) {
    filters.push(
      "drawbox=x=w*0.62:y=h*0.92:w=w*0.34:h=h*0.06:color=black@0.45:t=fill,drawtext=text='Shot on AITO | 智驾影音':x=w*0.64:y=h*0.94:fontsize=h*0.024:fontcolor=white"
    )
  }
  return filters
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

function toFilterLabel(track, index) {
  const normalized = String(track ?? `track_${index}`)
    .replace(/[^a-zA-Z0-9]/g, '_')
    .toLowerCase()
  return `track_${normalized}_${index}`
}

function buildTrackFilterInputs(trackInputs = {}) {
  const args = []
  const filterNodes = []
  const concatFiles = []
  const streamLabelByTrack = {}
  let inputIndex = 0
  Object.entries(trackInputs).forEach(([track, files], trackIndex) => {
    if (!Array.isArray(files) || files.length === 0) {
      return
    }
    const labels = []
    const useRangeConcat = files.some(item => typeof item === 'object')
    if (useRangeConcat) {
      const placeholder = `concat_track_${toFilterLabel(track, trackIndex)}.txt`
      concatFiles.push({
        placeholder,
        content: buildConcatFileList(files)
      })
      args.push('-f', 'concat', '-safe', '0', '-i', placeholder)
      labels.push(`[${inputIndex}:v]`)
      inputIndex += 1
    } else {
      files.forEach(file => {
        args.push('-i', file)
        labels.push(`[${inputIndex}:v]`)
        inputIndex += 1
      })
    }
    const outputLabel = `[${toFilterLabel(track, trackIndex)}]`
    streamLabelByTrack[track] = outputLabel
    if (labels.length === 1) {
      filterNodes.push(`${labels[0]}setpts=PTS-STARTPTS${outputLabel}`)
      return
    }
    filterNodes.push(`${labels.join('')}concat=n=${labels.length}:v=1:a=0${outputLabel}`)
  })
  return {
    args,
    filterNodes,
    concatFiles,
    streamLabelByTrack
  }
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
  exportControls = {},
  socialShareMode,
  hardwareEncoder = 'h264_avcodec',
  layoutMode = 'single_track',
  templateId = 'T2',
  trackInputs = {}
}) {
  const filter =
    privacyPlan.mode === 'delogo' ? buildDelogoFilter(privacyPlan) : buildOverlayFilter(privacyPlan)
  const bitrate = socialShareMode ? '6M' : '20M'
  const controls = resolveExportControls(exportControls)
  const postVideoFilters = buildPostVideoFilters(controls)
  if (layoutMode === 'scenario_template') {
    const mergedTrackInputs = Object.keys(trackInputs).length
      ? trackInputs
      : {
          Front: inputFiles,
          Back: secondaryInputFiles
        }
    const built = buildTrackFilterInputs(mergedTrackInputs)
    const fallbackFiles = [...inputFiles, ...secondaryInputFiles]
    const argsInputs = built.args.length > 0 ? built.args : fallbackFiles.flatMap(file => ['-i', file])
    const streamLabelByTrack =
      Object.keys(built.streamLabelByTrack).length > 0 ? built.streamLabelByTrack : { Front: '[0:v]' }
    const templateGraph = buildTemplateFilterComplex({
      templateId,
      streamLabelByTrack,
      privacyFilter: filter
    })
    const outputLabel = postVideoFilters.length > 0 ? '[v_out]' : '[v]'
    const complex = [
      ...built.filterNodes,
      templateGraph,
      ...(postVideoFilters.length > 0 ? [`[v]${postVideoFilters.join(',')}${outputLabel}`] : [])
    ].join(';')
    return {
      type: 'transcode',
      exportControls: controls,
      concatFiles: built.concatFiles,
      args: [
        ...argsInputs,
        '-filter_complex',
        complex,
        '-map',
        outputLabel,
        '-c:v',
        hardwareEncoder,
        '-b:v',
        bitrate,
        '-preset',
        'fast',
        ...(controls.muted ? ['-an'] : []),
        outputPath
      ]
    }
  }
  const vf = [filter, ...postVideoFilters].join(',')
  return {
    type: 'transcode',
    exportControls: controls,
    args: [
      '-i',
      inputFiles[0],
      '-vf',
      vf,
      '-c:v',
      hardwareEncoder,
      '-b:v',
      bitrate,
      '-preset',
      'fast',
      ...(controls.muted ? ['-an'] : []),
      outputPath
    ]
  }
}
