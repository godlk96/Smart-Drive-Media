/**
 * (排版师) 根据横屏或竖屏，计算播放器和时间轴的布局比例。
 */
export const Orientation = Object.freeze({
  PORTRAIT: 'portrait',
  LANDSCAPE: 'landscape'
})

export function getEditorLayout(orientation) {
  if (orientation === Orientation.LANDSCAPE) {
    return {
      preview: { region: 'left', ratio: 0.6 },
      timeline: { region: 'right', ratio: 0.4 },
      layers: [
        { id: 'preview', ratio: 0.58 },
        { id: 'control', ratio: 0.14 },
        { id: 'timeline', ratio: 0.14 },
        { id: 'drawer', ratio: 0.14 }
      ]
    }
  }

  return {
    preview: { region: 'top', ratio: 0.35 },
    timeline: { region: 'bottom', ratio: 0.65 },
    layers: [
      { id: 'preview', ratio: 0.52 },
      { id: 'control', ratio: 0.12 },
      { id: 'timeline', ratio: 0.16 },
      { id: 'drawer', ratio: 0.2 }
    ]
  }
}
