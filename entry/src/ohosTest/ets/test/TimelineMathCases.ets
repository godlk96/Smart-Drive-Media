/**
 * 纯函数层的测试用例（**不含 hypium 依赖**，因此可以同时被两条路径执行）：
 *   1. 设备上：TimelineMath.test.ets 用 hypium 包装它（entry/src/ohosTest）
 *   2. 本机离线：tools/offline-test.mjs 直接把 .ets 复制成 .ts 后 import 并执行
 *
 * 用例逻辑只写一份，避免"设备上过的测试"和"本地过的测试"漂移。
 * 每个用例的 run() 返回 '' 表示通过，否则返回失败原因。
 */

import {
  DRIFT_CONFIRM_MS,
  SEEK_TOLERANCE_MS,
  SegmentKind,
  SegmentSpan,
  SLICE_MS,
  TimeGrid,
  buildSegmentSpans,
  buildTimeGrid,
  checkSeek,
  clampMs,
  computeGridDurationMs,
  gapHoldIndex,
  gridIndexAt,
  gridSlotStartMs,
  segmentAt,
  segmentEndMs
} from '../../../main/ets/media/TimelineMath'
import {
  MAX_PREVIEW_SLOTS,
  SlotGeometry,
  buildSlotGeometry,
  cameraForSlot,
  resolveClockCamera,
  templateAspectRatio,
  templateCameras,
  templateUsesCamera
} from '../../../main/ets/media/PreviewLayout'
import { DvrMeta } from '../../../main/ets/model/TripModels'
import { listTemplateDefinitions, resolveTemplateDefinition, toLegacyCamera } from '../../../main/ets/model/Models'
import {
  TimelineCase,
  expectNumber,
  expectString,
  expectTrue,
  firstError
} from './TestSupport'

function span(uri: string, startMs: number, durationMs: number): SegmentSpan {
  const s = new SegmentSpan()
  s.uri = uri
  s.startMs = startMs
  s.durationMs = durationMs
  return s
}

function clip(camera: string, timestamp: number, uri: string): DvrMeta {
  const meta = new DvrMeta()
  meta.camera = camera
  meta.timestamp = timestamp
  meta.uri = uri
  meta.fileName = `${camera}_${timestamp}.mp4`
  return meta
}

/**
 * 两个时间戳：t=1000 与 t=121000（中间整分钟缺失）。
 * 墙钟网格因此是 **3 个槽位**：0~60s、60~120s（无人录到）、120~180s。
 * Front 录到第 1、3 分钟；LeftFront 只录到第 1 分钟。
 */
function gridClips(): Array<DvrMeta> {
  return [
    clip('Front', 1000, 'front_0.mp4'),
    clip('Front', 121000, 'front_2.mp4'),
    clip('LeftFront', 1000, 'leftfront_0.mp4')
  ]
}

export function timelineMathCases(): Array<TimelineCase> {
  const cases: Array<TimelineCase> = []

  // ---------- segmentAt ----------
  cases.push({
    name: 'segmentAt: 空段列表返回 gap 且 index 为 -1',
    run: (): string => {
      const t = segmentAt([], 5000)
      return firstError([
        expectString(t.kind, SegmentKind.GAP, 'kind'),
        expectNumber(t.index, -1, 'index')
      ])
    }
  })

  cases.push({
    name: 'segmentAt: 段内取值给出正确偏移',
    run: (): string => {
      const segs = [span('a.mp4', 0, SLICE_MS)]
      const t = segmentAt(segs, 12345)
      return firstError([
        expectString(t.kind, SegmentKind.CONTENT, 'kind'),
        expectNumber(t.index, 0, 'index'),
        expectNumber(t.offsetMs, 12345, 'offsetMs'),
        expectNumber(t.segmentStartMs, 0, 'segmentStartMs'),
        expectNumber(t.segmentDurationMs, SLICE_MS, 'segmentDurationMs')
      ])
    }
  })

  cases.push({
    name: 'segmentAt: 段起点是 content，段终点属于下一段（半开区间）',
    run: (): string => {
      const segs = [span('a.mp4', 0, SLICE_MS), span('b.mp4', SLICE_MS, SLICE_MS)]
      const atStart = segmentAt(segs, 0)
      const atEnd = segmentAt(segs, SLICE_MS)
      return firstError([
        expectString(atStart.kind, SegmentKind.CONTENT, '起点 kind'),
        expectNumber(atStart.index, 0, '起点 index'),
        expectString(atEnd.kind, SegmentKind.CONTENT, '终点 kind'),
        expectNumber(atEnd.index, 1, '终点 index'),
        expectNumber(atEnd.offsetMs, 0, '终点 offsetMs')
      ])
    }
  })

  cases.push({
    name: 'segmentAt: 网格空洞返回 gap 且指向下一段，不跳回第 0 段',
    run: (): string => {
      // 该机位只有第 1 分钟和第 3 分钟（缺第 2 分钟）
      const segs = [span('a.mp4', 0, SLICE_MS), span('c.mp4', 2 * SLICE_MS, SLICE_MS)]
      const t = segmentAt(segs, SLICE_MS + 5000)
      return firstError([
        expectString(t.kind, SegmentKind.GAP, 'kind'),
        expectNumber(t.index, 1, 'index（下一段）'),
        expectNumber(gapHoldIndex(t), 0, 'gapHoldIndex（保持上一帧）')
      ])
    }
  })

  cases.push({
    name: 'segmentAt: 开头即空洞时 gapHoldIndex 为 -1（应显示黑场）',
    run: (): string => {
      const segs = [span('b.mp4', SLICE_MS, SLICE_MS)]
      const t = segmentAt(segs, 100)
      return firstError([
        expectString(t.kind, SegmentKind.GAP, 'kind'),
        expectNumber(t.index, 0, 'index'),
        expectNumber(gapHoldIndex(t), -1, 'gapHoldIndex')
      ])
    }
  })

  cases.push({
    name: 'segmentAt: 越过末尾返回 gap 且 index 等于段数',
    run: (): string => {
      const segs = [span('a.mp4', 0, SLICE_MS)]
      const t = segmentAt(segs, SLICE_MS * 5)
      return firstError([
        expectString(t.kind, SegmentKind.GAP, 'kind'),
        expectNumber(t.index, 1, 'index'),
        expectNumber(gapHoldIndex(t), 0, 'gapHoldIndex')
      ])
    }
  })

  cases.push({
    name: 'segmentAt: content 时 gapHoldIndex 等于自身',
    run: (): string => {
      const segs = [span('a.mp4', 0, SLICE_MS), span('b.mp4', SLICE_MS, SLICE_MS)]
      const t = segmentAt(segs, SLICE_MS + 10)
      return firstError([
        expectNumber(t.index, 1, 'index'),
        expectNumber(gapHoldIndex(t), 1, 'gapHoldIndex')
      ])
    }
  })

  cases.push({
    name: 'segmentEndMs: 等于 start + duration',
    run: (): string => {
      return expectNumber(segmentEndMs(span('a.mp4', 120000, SLICE_MS)), 180000, 'endMs')
    }
  })

  // ---------- buildSegmentSpans（索引网格语义） ----------
  cases.push({
    name: 'buildSegmentSpans: 缺一分钟时机位自己的 startMs 仍是网格位置（不是累积时长）',
    run: (): string => {
      const clips = gridClips()
      const grid = buildTimeGrid(clips)
      const front = buildSegmentSpans(clips, 'Front', grid)
      return firstError([
        expectNumber(grid.startMs, 1000, '网格起点'),
        expectNumber(grid.sliceCount, 3, '网格槽位数（中间缺的分钟仍占位）'),
        expectNumber(grid.durationMs, 3 * SLICE_MS, '网格总时长'),
        expectNumber(front.length, 2, 'Front 段数'),
        expectNumber(front[0].startMs, 0, 'front[0].startMs'),
        expectNumber(front[1].startMs, 2 * SLICE_MS, 'front[1].startMs（跳过缺失的第 2 分钟）'),
        expectString(front[1].uri, 'front_2.mp4', 'front[1].uri')
      ])
    }
  })

  cases.push({
    name: 'buildSegmentSpans: 缺不同分钟的两个机位仍共享同一时间网格（统一视角延续）',
    run: (): string => {
      const clips = gridClips()
      const grid = buildTimeGrid(clips)
      const front = buildSegmentSpans(clips, 'Front', grid)
      const leftFront = buildSegmentSpans(clips, 'LeftFront', grid)
      // 全局 t=90000（第 2 分钟）时：Front 处于空洞，LeftFront 也处于空洞
      const frontTarget = segmentAt(front, 90000)
      const leftTarget = segmentAt(leftFront, 90000)
      // 全局 t=130000（第 3 分钟）时：Front 有内容，LeftFront 没有
      const frontLater = segmentAt(front, 130000)
      const leftLater = segmentAt(leftFront, 130000)
      return firstError([
        expectString(frontTarget.kind, SegmentKind.GAP, 'front@90s'),
        expectString(leftTarget.kind, SegmentKind.GAP, 'leftFront@90s'),
        expectString(frontLater.kind, SegmentKind.CONTENT, 'front@130s'),
        expectNumber(frontLater.offsetMs, 10000, 'front@130s offset'),
        expectString(leftLater.kind, SegmentKind.GAP, 'leftFront@130s 无素材'),
        // LeftFront 只有 1 段（槽位 0）。GAP 的 index 语义是"下一个内容段的索引"，
        // 越过末尾时等于段数 1，于是 gapHoldIndex()=0 恰好指回唯一的上一段。
        // （此处曾误写为 2——那是把网格槽位序号当成了段索引，会让 gapHoldIndex 越界。）
        expectNumber(leftLater.index, 1, 'leftFront@130s 越过末尾 → 段数'),
        expectNumber(gapHoldIndex(leftLater), 0, 'leftFront@130s 保持第 0 段最后一帧')
      ])
    }
  })

  cases.push({
    name: 'buildSegmentSpans: 机位各自缺不同分钟时，同一时间戳仍落在同一全局时刻',
    run: (): string => {
      const clips = [
        clip('Front', 1000, 'f0.mp4'),
        clip('Front', 61000, 'f1.mp4'),
        clip('Front', 121000, 'f2.mp4'),
        clip('Back', 61000, 'b1.mp4'),
        clip('Back', 121000, 'b2.mp4')
      ]
      const grid = buildTimeGrid(clips)
      const front = buildSegmentSpans(clips, 'Front', grid)
      const back = buildSegmentSpans(clips, 'Back', grid)
      const f = segmentAt(front, 125000)
      const b = segmentAt(back, 125000)
      return firstError([
        expectNumber(grid.sliceCount, 3, '槽位数'),
        expectString(f.kind, SegmentKind.CONTENT, 'front@125s'),
        expectString(b.kind, SegmentKind.CONTENT, 'back@125s'),
        expectNumber(f.index, 2, 'front 段索引'),
        expectNumber(b.index, 1, 'back 段索引（它缺第 1 分钟）'),
        expectNumber(f.offsetMs, 5000, 'front 段内偏移'),
        expectNumber(b.offsetMs, 5000, 'back 段内偏移（与 front 同一时刻）')
      ])
    }
  })

  cases.push({
    name: 'buildTimeGrid: 单个切片是 1 个槽位；空数组退化为 1 个槽位',
    run: (): string => {
      const one: TimeGrid = buildTimeGrid([clip('Front', 1000, 'a.mp4')])
      const empty: TimeGrid = buildTimeGrid([])
      return firstError([
        expectNumber(one.sliceCount, 1, '单切片槽位数'),
        expectNumber(one.durationMs, SLICE_MS, '单切片时长'),
        expectNumber(one.startMs, 1000, '单切片起点'),
        expectNumber(empty.sliceCount, 1, '空数组槽位数'),
        expectNumber(empty.startMs, 0, '空数组起点')
      ])
    }
  })

  cases.push({
    name: 'gridIndexAt: 容忍秒级漂移；越界返回 -1',
    run: (): string => {
      const grid = buildTimeGrid([clip('Front', 1000, 'a.mp4'), clip('Front', 121000, 'b.mp4')])
      return firstError([
        expectNumber(gridIndexAt(grid, 1000), 0, '精确命中'),
        expectNumber(gridIndexAt(grid, 61200), 1, '漂移 +200ms'),
        expectNumber(gridIndexAt(grid, 119900), 2, '漂移 -1100ms'),
        expectNumber(gridIndexAt(grid, 500), 0, '早于网格但在半格容差内 → 归入槽位 0'),
        expectNumber(gridIndexAt(grid, -31000), -1, '超出半格容差 → -1'),
        expectNumber(gridIndexAt(grid, 999999), -1, '晚于网格'),
        expectNumber(gridSlotStartMs(grid, 2), 120000, '槽位 2 起点')
      ])
    }
  })

  cases.push({
    name: 'buildSegmentSpans: 只取指定机位且按时间升序',
    run: (): string => {
      const clips = [
        clip('Front', 121000, 'front_late.mp4'),
        clip('Back', 1000, 'back.mp4'),
        clip('Front', 1000, 'front_early.mp4')
      ]
      const front = buildSegmentSpans(clips, 'Front', buildTimeGrid(clips))
      return firstError([
        expectNumber(front.length, 2, '段数'),
        expectString(front[0].uri, 'front_early.mp4', 'front[0]'),
        expectString(front[1].uri, 'front_late.mp4', 'front[1]')
      ])
    }
  })

  cases.push({
    name: 'buildSegmentSpans: 空 uri 的切片被忽略',
    run: (): string => {
      const clips = [clip('Front', 1000, ''), clip('Front', 61000, 'ok.mp4')]
      const front = buildSegmentSpans(clips, 'Front', buildTimeGrid(clips))
      return firstError([
        expectNumber(front.length, 1, '段数'),
        expectString(front[0].uri, 'ok.mp4', 'uri')
      ])
    }
  })

  cases.push({
    name: 'buildSegmentSpans: 单段时长不超过一个切片',
    run: (): string => {
      const clips = [clip('Front', 1000, 'a.mp4')]
      const front = buildSegmentSpans(clips, 'Front', buildTimeGrid(clips))
      return firstError([
        expectNumber(front[0].durationMs, SLICE_MS, 'durationMs')
      ])
    }
  })

  // ---------- 时长 / 工具函数 ----------
  cases.push({
    name: 'computeGridDurationMs: 按切片数计算，而不是墙钟跨度',
    run: (): string => {
      return firstError([
        expectNumber(computeGridDurationMs(3), 180000, '3 个切片'),
        expectNumber(computeGridDurationMs(1), 60000, '1 个切片'),
        expectNumber(computeGridDurationMs(0), 60000, '0 个切片也至少 1 分钟')
      ])
    }
  })

  cases.push({
    name: 'buildSegmentSpans: 同机位两个切片落到同一槽位时只保留较早的一个',
    run: (): string => {
      const clips = [
        clip('Front', 1000, 'first.mp4'),
        clip('Front', 2000, 'dup.mp4')
      ]
      const front = buildSegmentSpans(clips, 'Front', buildTimeGrid(clips))
      return firstError([
        expectNumber(front.length, 1, '段数'),
        expectString(front[0].uri, 'first.mp4', '保留较早的')
      ])
    }
  })

  cases.push({
    name: 'clampMs: 负数归零、越界截断、NaN 归零',
    run: (): string => {
      return firstError([
        expectNumber(clampMs(-5, 1000), 0, '负数'),
        expectNumber(clampMs(500, 1000), 500, '区间内'),
        expectNumber(clampMs(5000, 1000), 1000, '越界'),
        expectNumber(clampMs(Number.NaN, 1000), 0, 'NaN')
      ])
    }
  })

  // ---------- 模板几何（单一来源） ----------
  cases.push({
    name: 'PreviewLayout: T1 上下堆叠两槽，几何铺满',
    run: (): string => {
      const g = buildSlotGeometry('T1')
      return firstError([
        expectNumber(g.length, 2, '槽数'),
        expectString(g[0].camera, 'Front', 'slot0 camera'),
        expectString(g[1].camera, 'Back', 'slot1 camera'),
        expectNumber(g[0].width, 1, 'slot0 width'),
        expectNumber(g[0].height, 0.5, 'slot0 height'),
        expectNumber(g[1].y, 0.5, 'slot1 y'),
        expectNumber(g[1].height, 0.5, 'slot1 height')
      ])
    }
  })

  cases.push({
    name: 'PreviewLayout: T2 倒品字三槽',
    run: (): string => {
      const g = buildSlotGeometry('T2')
      return firstError([
        expectNumber(g.length, 3, '槽数'),
        expectString(g[0].camera, 'Front', 'slot0'),
        expectString(g[1].camera, 'Left', 'slot1'),
        expectString(g[2].camera, 'Right', 'slot2'),
        expectNumber(g[0].height, 0.6667, 'slot0 height'),
        expectNumber(g[1].width, 0.5, 'slot1 width'),
        expectNumber(g[2].x, 0.5, 'slot2 x')
      ])
    }
  })

  cases.push({
    name: 'PreviewLayout: T3 左右分屏两槽',
    run: (): string => {
      const g = buildSlotGeometry('T3')
      return firstError([
        expectNumber(g.length, 2, '槽数'),
        expectString(g[0].camera, 'Left', 'slot0'),
        expectString(g[1].camera, 'Right', 'slot1'),
        expectNumber(g[0].width, 0.5, 'slot0 width'),
        expectNumber(g[1].x, 0.5, 'slot1 x')
      ])
    }
  })

  cases.push({
    name: 'PreviewLayout: T4 三栏宽度 0.25/0.5/0.25 且两侧 zoomX=2（与原生 hstack 960/1920/960 一致）',
    run: (): string => {
      const g = buildSlotGeometry('T4')
      return firstError([
        expectNumber(g.length, 3, '槽数'),
        expectString(g[0].camera, 'LeftFront', 'slot0'),
        expectString(g[1].camera, 'Front', 'slot1'),
        expectString(g[2].camera, 'RightFront', 'slot2'),
        expectNumber(g[0].width, 0.25, 'slot0 width'),
        expectNumber(g[1].width, 0.5, 'slot1 width'),
        expectNumber(g[2].width, 0.25, 'slot2 width'),
        expectNumber(g[0].x, 0, 'slot0 x'),
        expectNumber(g[1].x, 0.25, 'slot1 x'),
        expectNumber(g[2].x, 0.75, 'slot2 x'),
        expectNumber(g[0].zoomX, 2, 'slot0 zoomX'),
        expectNumber(g[2].zoomX, 2, 'slot2 zoomX'),
        expectNumber(g[1].zoomX, 1, 'slot1 zoomX')
      ])
    }
  })

  cases.push({
    name: 'PreviewLayout: T5 单视角一槽铺满',
    run: (): string => {
      const g = buildSlotGeometry('T5')
      return firstError([
        expectNumber(g.length, 1, '槽数'),
        expectString(g[0].camera, 'Front', 'slot0'),
        expectNumber(g[0].width, 1, 'width'),
        expectNumber(g[0].height, 1, 'height')
      ])
    }
  })

  cases.push({
    name: 'PreviewLayout: 所有模板的槽位都落在画布内、互不重叠、面积和为 1',
    run: (): string => {
      const defs = listTemplateDefinitions()
      const errors: Array<string> = []
      for (let d = 0; d < defs.length; d++) {
        const templateId = defs[d].templateId
        const g = buildSlotGeometry(templateId)
        let area = 0
        for (let i = 0; i < g.length; i++) {
          const a = g[i]
          if (a.x < 0 || a.y < 0 || a.x + a.width > 1.0001 || a.y + a.height > 1.0001) {
            errors.push(`${templateId} slot${i} 越界`)
          }
          area += a.width * a.height
          for (let j = i + 1; j < g.length; j++) {
            const b = g[j]
            const overlapX = Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x)
            const overlapY = Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y)
            if (overlapX > 0.0001 && overlapY > 0.0001) {
              errors.push(`${templateId} slot${i} 与 slot${j} 重叠`)
            }
          }
        }
        if (Math.abs(area - 1) > 0.001) {
          errors.push(`${templateId} 面积和 ${area} != 1`)
        }
        if (g.length > MAX_PREVIEW_SLOTS) {
          errors.push(`${templateId} 槽数 ${g.length} 超过 MAX_PREVIEW_SLOTS`)
        }
      }
      return firstError(errors)
    }
  })

  cases.push({
    name: 'PreviewLayout: 槽位机位与 slotBindings 完全一致（不存在平行的映射表）',
    run: (): string => {
      const defs = listTemplateDefinitions()
      const errors: Array<string> = []
      for (let d = 0; d < defs.length; d++) {
        const def = defs[d]
        const g = buildSlotGeometry(def.templateId)
        for (let i = 0; i < g.length; i++) {
          const expected = cameraForSlot(def, g[i].slotId)
          if (g[i].camera !== expected) {
            errors.push(`${def.templateId} slot${i} camera ${g[i].camera} != ${expected}`)
          }
          if (expected.length === 0) {
            errors.push(`${def.templateId} slot${i}（${g[i].slotId}）在 slotBindings 里没有机位`)
          }
        }
      }
      return firstError(errors)
    }
  })

  cases.push({
    name: 'PreviewLayout: 每个模板的槽位数等于机位数（一槽一机位，不重复）',
    run: (): string => {
      const defs = listTemplateDefinitions()
      const errors: Array<string> = []
      for (let d = 0; d < defs.length; d++) {
        const def = defs[d]
        const g = buildSlotGeometry(def.templateId)
        const cameras = templateCameras(def.templateId)
        if (cameras.length !== g.length) {
          errors.push(`${def.templateId} 机位数 ${cameras.length} != 槽位数 ${g.length}`)
        }
      }
      return firstError(errors)
    }
  })

  cases.push({
    name: 'PreviewLayout: 画布宽高比与原生契约一致（T1 0.8889 / T2 1.1852 / T3 3.5556 / T4 3.5556 / T5 1.7778）',
    run: (): string => {
      const errors: Array<string> = []
      const expected: Array<string> = ['T1', 'T2', 'T3', 'T4', 'T5']
      const ratios: Array<number> = [1920 / 2160, 1920 / 1620, 3840 / 1080, 3840 / 1080, 1920 / 1080]
      for (let i = 0; i < expected.length; i++) {
        const actual = templateAspectRatio(expected[i])
        if (Math.abs(actual - ratios[i]) > 0.0005) {
          errors.push(`${expected[i]} 宽高比 ${actual} != ${ratios[i]}`)
        }
      }
      return firstError(errors)
    }
  })

  cases.push({
    name: 'PreviewLayout: 时钟轨优先 Front，T3 退化为声明顺序第一个',
    run: (): string => {
      return firstError([
        expectString(resolveClockCamera('T2'), 'Front', 'T2'),
        expectString(resolveClockCamera('T3'), 'Left', 'T3 无 Front'),
        expectString(resolveClockCamera('T4'), 'Front', 'T4')
      ])
    }
  })

  cases.push({
    name: 'PreviewLayout: 模板是否使用某机位可判定（用于槽位切模板时决定是否换源）',
    run: (): string => {
      return firstError([
        expectTrue(templateUsesCamera('T2', 'Left'), 'T2 用 Left'),
        expectTrue(!templateUsesCamera('T2', 'LeftFront'), 'T2 不用 LeftFront'),
        expectTrue(templateUsesCamera('T4', 'LeftFront'), 'T4 用 LeftFront'),
        expectTrue(!templateUsesCamera('T5', 'Right'), 'T5 不用 Right')
      ])
    }
  })

  cases.push({
    name: 'PreviewLayout: 未知模板回退到默认模板而不是抛异常',
    run: (): string => {
      const g = buildSlotGeometry('不存在的模板')
      return firstError([
        expectTrue(g.length > 0, '槽数大于 0'),
        expectString(g[0].camera, 'Front', '默认模板第一槽是 Front')
      ])
    }
  })

  cases.push({
    name: 'PreviewLayout: toLegacyCamera 与 DvrMeta.camera 命名空间一致',
    run: (): string => {
      const g = buildSlotGeometry('T4')
      const errors: Array<string> = []
      for (let i = 0; i < g.length; i++) {
        if (['Front', 'Back', 'Left', 'Right', 'LeftFront', 'RightFront'].indexOf(g[i].camera) < 0) {
          errors.push(`未知机位名 ${g[i].camera}`)
        }
      }
      return firstError(errors)
    }
  })

  cases.push({
    name: 'Models: 模板定义里的机位与 ffmpegPolicy 候选集非空且自洽',
    run: (): string => {
      const defs = listTemplateDefinitions()
      const errors: Array<string> = []
      for (let d = 0; d < defs.length; d++) {
        const def = defs[d]
        if (def.requiredCameras.length === 0) {
          errors.push(`${def.templateId} 无必需机位`)
        }
        if (def.ffmpegPolicy.frontTrackCandidates.length === 0) {
          errors.push(`${def.templateId} 无 frontTrackCandidates`)
        }
        for (let i = 0; i < def.slotBindings.length; i++) {
          const camera = def.slotBindings[i].camera
          if (def.requiredCameras.indexOf(camera) < 0 && def.optionalCameras.indexOf(camera) < 0) {
            errors.push(`${def.templateId} slotBinding ${def.slotBindings[i].slotId} 的机位既非必需也非可选`)
          }
        }
      }
      return firstError(errors)
    }
  })

  cases.push({
    name: 'Models: resolveTemplateDefinition 对未知 id 回退默认模板',
    run: (): string => {
      const def = resolveTemplateDefinition('NOPE')
      return firstError([
        expectString(def.templateId, 'T2', '默认模板'),
        expectNumber(def.previewSlots.length > 0 ? 1 : 0, 1, '有槽位定义')
      ])
    }
  })

  cases.push({
    name: 'Models: toLegacyCamera 映射覆盖全部 CameraPosition',
    run: (): string => {
      const def = resolveTemplateDefinition('T4')
      const errors: Array<string> = []
      for (let i = 0; i < def.slotBindings.length; i++) {
        const legacy = toLegacyCamera(def.slotBindings[i].camera)
        if (legacy.length === 0) {
          errors.push(`机位 ${def.slotBindings[i].camera} 无 legacy 名`)
        }
      }
      return firstError(errors)
    }
  })

  // ---------- seek 决策（播放中该不该动播放器） ----------
  //
  // 这一组是**回归用例**：预览页曾经"声音断断续续 + 进度条一顿一顿"，
  // 根因就在 checkSeek() 的偏差基准上（旧实现拿"上次 seek 的目标"当基准）。

  cases.push({
    name: 'checkSeek: 正常播放（每 100ms 上报、位置与目标同步）3.2 秒内一次都不 seek',
    run: (): string => {
      // 主轨每 100ms 上报一次，时钟由它驱动 → 目标 == 播放器实际位置。
      // 新规则以实际位置为基准，偏差恒为 0，因此一次都不该 seek。
      let driftHeld = 0
      let seeks = 0
      for (let i = 1; i <= 32; i++) {
        const observed = i * 100
        const check = checkSeek(observed, observed, false, driftHeld, 100)
        driftHeld = check.nextDriftHeldMs
        if (check.seek) {
          seeks += 1
        }
      }
      return expectNumber(seeks, 0, '3.2 秒正常播放的 seek 次数')
    }
  })

  cases.push({
    name: 'checkSeek: 对照——旧规则（以"上次 seek 目标"为基准）在同样 3.2 秒里会 seek 十余次',
    run: (): string => {
      // 把旧规则原样写出来，让"它为什么必然形成 seek 风暴"变成一条可执行的断言：
      // 目标会随播放远离上次 seek 的目标，偏差恒定增长 → 每积累一个容差就 seek 一次。
      let lastTarget = 0
      let seeks = 0
      for (let i = 1; i <= 32; i++) {
        const wanted = i * 100
        if (Math.abs(lastTarget - wanted) > 200) {
          lastTarget = wanted
          seeks += 1
        }
      }
      return expectTrue(seeks >= 10, `旧规则的 seek 次数 ${seeks} 应 >= 10（这就是 seek 风暴）`)
    }
  })

  cases.push({
    name: 'checkSeek: 偏差连续超容差满确认窗口才 seek，且窗口随即清零',
    run: (): string => {
      const first = checkSeek(0, 5000, false, 0, 300)
      const second = checkSeek(0, 5000, false, first.nextDriftHeldMs, 300)
      const third = checkSeek(0, 5000, false, second.nextDriftHeldMs, 300)
      return firstError([
        expectTrue(!first.seek, '第一轮不 seek'),
        expectNumber(first.nextDriftHeldMs, 300, '第一轮累计 300ms'),
        expectTrue(!second.seek, `累计 600ms < ${DRIFT_CONFIRM_MS}ms 仍不 seek`),
        expectNumber(second.nextDriftHeldMs, 600, '第二轮累计 600ms'),
        expectTrue(third.seek, '累计 900ms 达到确认窗口 → seek'),
        expectNumber(third.nextDriftHeldMs, 0, 'seek 后窗口清零')
      ])
    }
  })

  cases.push({
    name: 'checkSeek: 偏差中途回到容差内则窗口清零（偏差必须是连续的）',
    run: (): string => {
      const a = checkSeek(0, 5000, false, 0, 600)
      const b = checkSeek(5000, 5000, false, a.nextDriftHeldMs, 100)
      const c = checkSeek(0, 5000, false, b.nextDriftHeldMs, 100)
      return firstError([
        expectTrue(!a.seek, '600ms 未到窗口不 seek'),
        expectNumber(b.nextDriftHeldMs, 0, '回到容差内清零'),
        expectNumber(c.nextDriftHeldMs, 100, '重新计时'),
        expectTrue(!c.seek, '重新计时后不 seek')
      ])
    }
  })

  cases.push({
    name: 'checkSeek: forceSeek 立即 seek，无视容差与确认窗口',
    run: (): string => {
      const same = checkSeek(1000, 1000, true, 500, 10)
      const far = checkSeek(0, 60000, true, 0, 0)
      return firstError([
        expectTrue(same.seek, '位置相同也强制 seek'),
        expectNumber(same.nextDriftHeldMs, 0, '窗口清零'),
        expectTrue(far.seek, '大跨度强制 seek 不受确认窗口限制')
      ])
    }
  })

  cases.push({
    name: 'checkSeek: 容差边界——恰好等于容差不 seek，超出 1ms 才开始计时',
    run: (): string => {
      const atLimit = checkSeek(0, SEEK_TOLERANCE_MS, false, 0, 1000)
      // 只给 100ms：超容差但远未满确认窗口 → 必须不 seek。
      const overLimit = checkSeek(0, SEEK_TOLERANCE_MS + 1, false, 0, 100)
      return firstError([
        expectTrue(!atLimit.seek, '恰好等于容差 → 不 seek'),
        expectNumber(atLimit.nextDriftHeldMs, 0, '窗口不启动'),
        expectTrue(!overLimit.seek, '超容差 1ms 但未满确认窗口 → 不 seek'),
        expectNumber(overLimit.nextDriftHeldMs, 100, '窗口启动并累计')
      ])
    }
  })

  cases.push({
    name: 'checkSeek: 尚未收到 timeUpdate（-1）时按位置 0 处理',
    run: (): string => {
      const check = checkSeek(-1, SEEK_TOLERANCE_MS + 1, false, 0, DRIFT_CONFIRM_MS)
      return firstError([
        expectTrue(check.seek, '按 0 计算 → 超容差且满窗口 → seek')
      ])
    }
  })

  cases.push({
    name: 'checkSeek: 播放器真的卡住（位置冻结、目标前进）会被纠正，但频率被确认窗口限制',
    run: (): string => {
      // 位置一直冻结在 0，目标每 100ms 前进一次，共 2 秒。
      let driftHeld = 0
      let seeks = 0
      for (let i = 1; i <= 20; i++) {
        const check = checkSeek(0, i * 100, false, driftHeld, 100)
        driftHeld = check.nextDriftHeldMs
        if (check.seek) {
          seeks += 1
        }
      }
      return firstError([
        expectTrue(seeks >= 1, `卡住应被纠正，实际 ${seeks} 次`),
        expectTrue(seeks <= 3, `纠正次数应被确认窗口限制（不是每 200ms 一次），实际 ${seeks} 次`)
      ])
    }
  })

  cases.push({
    name: 'buildTimeGrid: 合并跨天行程时，各段首尾相接（不是把墙钟 min/max 拉成几天）',
    run: (): string => {
      // 真机日志里的那一对：09-11 16:58:56 与 09-12 12:02:03（相隔 19.05 小时）。
      // 旧实现算出 sliceCount=1144、时长 19.1 小时，播完第一段要"跳过"19 小时；
      // 新实现应把它们当作两段连续录制首尾相接 → 2 个槽位、120 秒。
      const clips = [
        clip('Front', new Date('2026-09-11T16:58:56').getTime(), 'a_front.mp4'),
        clip('Front', new Date('2026-09-12T12:02:03').getTime(), 'b_front.mp4')
      ]
      const grid = buildTimeGrid(clips)
      const spans = buildSegmentSpans(clips, 'Front', grid)
      const atBoundary = segmentAt(spans, SLICE_MS)
      return firstError([
        expectNumber(grid.runs.length, 2, '连续录制段数'),
        expectNumber(grid.sliceCount, 2, '合并后的槽位数'),
        expectNumber(grid.durationMs, 2 * SLICE_MS, '合并后的总时长'),
        expectNumber(spans.length, 2, '段数'),
        expectNumber(spans[0].startMs, 0, '第 1 段起点'),
        expectNumber(spans[1].startMs, SLICE_MS, '第 2 段紧接第 1 段（不是 19 小时之后）'),
        // 这正是旧实现的 bug：60000 处是空洞 → 触发 skip；新实现必须是 content。
        expectString(atBoundary.kind, SegmentKind.CONTENT, '段交界处必须是 content'),
        expectNumber(atBoundary.index, 1, '段交界处落在第 2 段'),
        expectNumber(atBoundary.offsetMs, 0, '段交界处偏移 0')
      ])
    }
  })

  cases.push({
    name: 'buildTimeGrid: 段内 ≤120s 的空洞仍然保留（不因为拼接而被压缩掉）',
    run: (): string => {
      // 0s 与 120s：中间缺了整整一分钟（间隔 60000ms ≤ RUN_GAP_MS）→ 同一段，
      // 中间那一分钟仍是空洞，不能被"拼接"抹掉。
      const clips = [
        clip('Front', 1000, 'a.mp4'),
        clip('Front', 121000, 'b.mp4')
      ]
      const grid = buildTimeGrid(clips)
      const spans = buildSegmentSpans(clips, 'Front', grid)
      const inHole = segmentAt(spans, SLICE_MS)
      return firstError([
        expectNumber(grid.runs.length, 1, '仍是一段连续录制'),
        expectNumber(grid.sliceCount, 3, '中间缺的分钟仍占一个槽位'),
        expectNumber(spans.length, 2, '该机位只有 2 段素材'),
        expectNumber(spans[1].startMs, 2 * SLICE_MS, '第 2 段仍在第 3 个槽位'),
        expectString(inHole.kind, SegmentKind.GAP, '中间那分钟是空洞'),
        expectNumber(gapHoldIndex(inHole), 0, '空洞保持第 0 段末帧')
      ])
    }
  })

  cases.push({
    name: 'buildTimeGrid: 超过 120s 才算断开（正好 120s 仍算同一段）',
    run: (): string => {
      // 切片 0s，下一个切片 180s：上一片结束于 60s，间隔 120s → 恰好等于阈值 → 同一段。
      const sameRun = buildTimeGrid([clip('Front', 0, 'a.mp4'), clip('Front', 180000, 'b.mp4')])
      // 切片 0s，下一个切片 181s：间隔 121s > 阈值 → 断开成两段并首尾相接。
      const splitRun = buildTimeGrid([clip('Front', 0, 'a.mp4'), clip('Front', 181000, 'b.mp4')])
      const splitSpans = buildSegmentSpans([clip('Front', 0, 'a.mp4'), clip('Front', 181000, 'b.mp4')], 'Front', splitRun)
      return firstError([
        expectNumber(sameRun.runs.length, 1, '间隔正好 120s → 同一段'),
        expectNumber(sameRun.sliceCount, 4, '同一段：0s/60s/120s/180s 四个槽位'),
        expectNumber(splitRun.runs.length, 2, '间隔 121s → 断开成两段'),
        expectNumber(splitRun.sliceCount, 2, '断开后只有 2 个槽位'),
        expectNumber(splitSpans[1].startMs, SLICE_MS, '断开后第 2 段紧接第 1 段')
      ])
    }
  })

  cases.push({
    name: 'gridIndexAt: 合并行程里，落在两段之间的时间戳返回 -1',
    run: (): string => {
      const clips = [
        clip('Front', new Date('2026-09-11T16:58:56').getTime(), 'a.mp4'),
        clip('Front', new Date('2026-09-12T12:02:03').getTime(), 'b.mp4')
      ]
      const grid = buildTimeGrid(clips)
      const a = new Date('2026-09-11T16:58:56').getTime()
      const b = new Date('2026-09-12T12:02:03').getTime()
      return firstError([
        expectNumber(gridIndexAt(grid, a), 0, '第 1 段 → 槽位 0'),
        expectNumber(gridIndexAt(grid, b), 1, '第 2 段 → 槽位 1'),
        expectNumber(gridIndexAt(grid, a + 3600000), -1, '两段之间（1 小时后）→ -1'),
        expectNumber(gridIndexAt(grid, b + 60000), -1, '超出第 2 段 → -1')
      ])
    }
  })

  return cases
}
