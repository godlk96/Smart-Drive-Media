export type ExportStage = 'preparing' | 'checking' | 'concatenating' | 'encoding' | 'finalizing' |
  'completed'

export interface ExportProgressUpdate {
  percent: number
  stage: ExportStage
  detail: string
}

export interface NativeExportWork {
  percent: number
  currentFrame: number
  totalFrames: number
  stage: number
  completedUnits?: number
  totalUnits?: number
}

export function exportPercent(value: number): number {
  return isFinite(value) ? Math.max(0, Math.min(100, Math.round(value * 10) / 10)) : 0
}

export function nativeExportProgress(work: NativeExportWork): ExportProgressUpdate {
  if (work.stage === 2) {
    const fraction = work.totalFrames > 0 ? Math.max(0, Math.min(1, work.currentFrame / work.totalFrames)) : 0
    return {
      percent: work.totalFrames > 0 ? exportPercent(25 + fraction * 59.9) : Math.max(25, Math.min(84.9, work.percent)),
      stage: 'encoding',
      detail: work.totalFrames > 0 ? `已合成 ${work.currentFrame} / ${work.totalFrames} 帧` : '正在合成画面'
    }
  }
  if (work.stage === 3) {
    return { percent: 85, stage: 'finalizing', detail: '正在完成视频封装' }
  }
  const completed = Math.max(0, work.completedUnits ?? 0)
  const total = Math.max(0, work.totalUnits ?? 0)
  if (work.stage === 4) {
    return {
      percent: total > 0 ? exportPercent(22 + Math.min(1, completed / total) * 3) : Math.max(22, Math.min(25, work.percent)),
      stage: 'concatenating', detail: '正在连接视频素材'
    }
  }
  return {
    percent: total > 0 ? exportPercent(20 + Math.min(1, completed / total) * 2) : Math.max(20, Math.min(22, work.percent)),
    stage: 'checking', detail: total > 0 ? `已检查 ${completed} / ${total} 个素材` : '正在检查视频素材'
  }
}

export function exportStageText(stage: ExportStage): string {
  switch (stage) {
    case 'preparing': return '准备素材'
    case 'checking': return '检查素材'
    case 'concatenating': return '拼接素材'
    case 'encoding': return '合成视频'
    case 'finalizing': return '完成封装'
    case 'completed': return '保存完成'
  }
}
