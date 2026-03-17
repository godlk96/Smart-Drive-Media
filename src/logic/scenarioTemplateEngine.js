const DEFAULT_TEMPLATE_ID = 'T2'

const TEMPLATE_REGISTRY = Object.freeze({
  T1: Object.freeze({
    id: 'T1',
    title: '防追尾双录',
    aspectRatio: '16:9',
    outputSize: Object.freeze({ width: 1920, height: 1080 }),
    slots: Object.freeze([
      Object.freeze({ id: 'top', track: 'Front', rect: Object.freeze({ x: 0, y: 0, width: 1, height: 0.5 }), radius: 0 }),
      Object.freeze({ id: 'bottom', track: 'Back', rect: Object.freeze({ x: 0, y: 0.5, width: 1, height: 0.5 }), radius: 0 })
    ]),
    guides: Object.freeze([])
  }),
  T2: Object.freeze({
    id: 'T2',
    title: '避险防加塞',
    aspectRatio: '32:27',
    outputSize: Object.freeze({ width: 1920, height: 1620 }),
    slots: Object.freeze([
      Object.freeze({ id: 'top', track: 'Front', rect: Object.freeze({ x: 0, y: 0, width: 1, height: 0.6667 }), radius: 0 }),
      Object.freeze({ id: 'bottomLeft', track: 'Left', rect: Object.freeze({ x: 0, y: 0.6667, width: 0.5, height: 0.3333 }), radius: 0 }),
      Object.freeze({ id: 'bottomRight', track: 'Right', rect: Object.freeze({ x: 0.5, y: 0.6667, width: 0.5, height: 0.3333 }), radius: 0 })
    ]),
    guides: Object.freeze([])
  }),
  T3: Object.freeze({
    id: 'T3',
    title: '侧向防开门杀',
    aspectRatio: '16:9',
    outputSize: Object.freeze({ width: 1920, height: 1080 }),
    slots: Object.freeze([
      Object.freeze({ id: 'left', track: 'Left', rect: Object.freeze({ x: 0, y: 0, width: 0.5, height: 1 }), radius: 0 }),
      Object.freeze({ id: 'right', track: 'Right', rect: Object.freeze({ x: 0.5, y: 0, width: 0.5, height: 1 }), radius: 0 })
    ]),
    guides: Object.freeze([
      Object.freeze({
        id: 'divider',
        rect: Object.freeze({ x: 0.4974, y: 0, width: 0.0052, height: 1 }),
        color: 'black'
      })
    ])
  }),
  T4: Object.freeze({
    id: 'T4',
    title: '沉浸式旅拍',
    aspectRatio: '16:9',
    outputSize: Object.freeze({ width: 1920, height: 1080 }),
    slots: Object.freeze([
      Object.freeze({ id: 'left', track: 'LeftFront', rect: Object.freeze({ x: 0, y: 0, width: 0.3333, height: 1 }), radius: 0 }),
      Object.freeze({ id: 'center', track: 'Front', rect: Object.freeze({ x: 0.3333, y: 0, width: 0.3334, height: 1 }), radius: 0 }),
      Object.freeze({ id: 'right', track: 'RightFront', rect: Object.freeze({ x: 0.6667, y: 0, width: 0.3333, height: 1 }), radius: 0 })
    ]),
    guides: Object.freeze([
      Object.freeze({
        id: 'dividerLeft',
        rect: Object.freeze({ x: 0.332, y: 0, width: 0.0026, height: 1 }),
        color: 'white'
      }),
      Object.freeze({
        id: 'dividerRight',
        rect: Object.freeze({ x: 0.6654, y: 0, width: 0.0026, height: 1 }),
        color: 'white'
      })
    ])
  }),
  T5: Object.freeze({
    id: 'T5',
    title: '单前视',
    aspectRatio: '16:9',
    outputSize: Object.freeze({ width: 1920, height: 1080 }),
    slots: Object.freeze([
      Object.freeze({ id: 'top', track: 'Front', rect: Object.freeze({ x: 0, y: 0, width: 1, height: 1 }), radius: 0 })
    ]),
    guides: Object.freeze([])
  })
})

const TRACK_FALLBACK = Object.freeze({
  Front: ['Front', 'LeftFront', 'RightFront', 'Left', 'Right'],
  Back: ['Back', 'Right', 'Left', 'RightFront', 'LeftFront', 'Front'],
  Left: ['Left', 'Right', 'LeftFront', 'RightFront', 'Front'],
  Right: ['Right', 'Left', 'RightFront', 'LeftFront', 'Front'],
  LeftFront: ['LeftFront', 'Left', 'Front', 'RightFront', 'Right'],
  RightFront: ['RightFront', 'Right', 'Front', 'LeftFront', 'Left']
})

function toEven(value) {
  const floored = Math.max(2, Math.floor(value))
  return floored % 2 === 0 ? floored : floored - 1
}

function rectToPixels(rect, outputSize) {
  return {
    x: Math.max(0, Math.floor(rect.x * outputSize.width)),
    y: Math.max(0, Math.floor(rect.y * outputSize.height)),
    width: toEven(rect.width * outputSize.width),
    height: toEven(rect.height * outputSize.height)
  }
}

function resolveTrack(track, availableTracks) {
  const preferred = TRACK_FALLBACK[track] ?? [track]
  const found = preferred.find(item => availableTracks.includes(item))
  if (found) {
    return found
  }
  if (track !== 'Back') {
    const nonBack = availableTracks.find(item => item !== 'Back')
    if (nonBack) {
      return nonBack
    }
    return track
  }
  return availableTracks[0] ?? track
}

export function getScenarioTemplate(templateId) {
  return TEMPLATE_REGISTRY[templateId] ?? TEMPLATE_REGISTRY[DEFAULT_TEMPLATE_ID]
}

export function getScenarioTemplateCards() {
  return Object.values(TEMPLATE_REGISTRY).map(template => ({
    id: template.id,
    title: template.title,
    aspectRatio: template.aspectRatio
  }))
}

export function buildScenarioPreview(templateId, availableTracks = []) {
  const template = getScenarioTemplate(templateId)
  const slots = template.slots.map(slot => ({
    id: slot.id,
    track: resolveTrack(slot.track, availableTracks),
    rect: { ...slot.rect },
    radius: slot.radius
  }))
  return {
    templateId: template.id,
    title: template.title,
    aspectRatio: template.aspectRatio,
    outputSize: { ...template.outputSize },
    slots,
    guides: template.guides.map(guide => ({
      id: guide.id,
      rect: { ...guide.rect },
      color: guide.color
    }))
  }
}

export function buildTemplateFilterComplex({
  templateId,
  streamLabelByTrack = {},
  privacyFilter = ''
}) {
  const template = getScenarioTemplate(templateId)
  const availableTracks = Object.keys(streamLabelByTrack).filter(key => Boolean(streamLabelByTrack[key]))
  const outputSize = template.outputSize
  const slotNodes = []
  const overlayNodes = []
  const guideNodes = []
  const streamRefs = []
  const strictTrackBinding = template.id === 'T5'

  template.slots.forEach((slot, index) => {
    const rect = rectToPixels(slot.rect, outputSize)
    const sourceTrack = resolveTrack(slot.track, availableTracks)
    const fallbackTrack =
      sourceTrack !== 'Back'
        ? availableTracks.find(item => item !== 'Back') ?? availableTracks[0]
        : availableTracks[0]
    const streamLabel = strictTrackBinding
      ? streamLabelByTrack[sourceTrack] ?? '[0:v]'
      : streamLabelByTrack[sourceTrack] ?? streamLabelByTrack[fallbackTrack] ?? '[0:v]'
    const slotLabel = `[slot_${index}]`
    const prepared = `${streamLabel}setpts=PTS-STARTPTS,scale=${rect.width}:${rect.height}:force_original_aspect_ratio=increase,crop=${rect.width}:${rect.height}${slotLabel}`
    slotNodes.push(prepared)
    streamRefs.push({ label: slotLabel, rect, radius: slot.radius })
  })

  const canvasLabel = '[canvas]'
  const canvas = `color=c=black:s=${outputSize.width}x${outputSize.height}:r=30${canvasLabel}`
  let previousLabel = canvasLabel
  streamRefs.forEach((item, index) => {
    const nextLabel = index === streamRefs.length - 1 && template.guides.length === 0 ? '[layout_v]' : `[overlay_${index}]`
    overlayNodes.push(
      `${previousLabel}${item.label}overlay=${item.rect.x}:${item.rect.y}${
        item.radius > 0 ? `:format=auto` : ''
      }${nextLabel}`
    )
    previousLabel = nextLabel
  })

  template.guides.forEach((guide, index) => {
    const rect = rectToPixels(guide.rect, outputSize)
    const color = guide.color === 'white' ? 'white' : 'black'
    const nextLabel =
      index === template.guides.length - 1 ? '[layout_v]' : `[guide_${index}]`
    guideNodes.push(
      `${previousLabel}drawbox=x=${rect.x}:y=${rect.y}:w=${rect.width}:h=${rect.height}:color=${color}:t=fill${nextLabel}`
    )
    previousLabel = nextLabel
  })

  const baseGraph = [canvas, ...slotNodes, ...overlayNodes, ...guideNodes]
  if (!privacyFilter) {
    return `${baseGraph.join(';')}`
  }
  const privacyGraph = `[layout_v]${privacyFilter}[v]`
  return `${baseGraph.join(';')};${privacyGraph}`
}
