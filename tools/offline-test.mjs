/**
 * 离线纯函数测试（不需要设备、不需要 HarmonyOS SDK 工程构建）。
 *
 * 为什么需要它：entry/src/ohosTest 里的 hypium 测试只能在真机/模拟器上跑，
 * 而这台机器当前 `hdc list targets` 为空。纯函数层的 bug（时间网格、空洞、模板几何）
 * 恰恰是最该被反复验证的部分。
 *
 * 做法：从入口出发 BFS 收集所有**不依赖 @ohos / ArkUI** 的 .ets 模块，
 * 用 DevEco 自带的 TypeScript 编译器转译成 ESM，再交给 Node 直接执行。
 *
 * 为什么用 tsc 而不是 Node 的 --experimental-transform-types：
 * Node 的类型擦除是纯语法级的，无法判断 `import { DvrMeta } from './TripModels'`
 * 里的 DvrMeta 是不是只有类型；它会保留这条 import，运行时报
 * "does not provide an export named 'DvrMeta'"。
 * tsc 会按引用位置判定并擦除纯类型导入，这正是纯函数层能跑起来的前提。
 *
 * 用法：
 *   node tools/offline-test.mjs
 *
 * 覆盖范围刻意保守：一旦某个模块出现裸导入（@ohos.* / @kit.*），
 * 这里会**明确报错**而不是静默跳过——静默跳过会让"本地全绿"变成假象。
 */

import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, join, relative, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const require = createRequire(import.meta.url)

const ROOT = resolve(import.meta.dirname, '..')
const BUILD_DIR = join(ROOT, '.offline-test-build')

/**
 * 测试入口（用例本体，不依赖 hypium）。
 * 每项是一个 .ets 文件 + 它导出的用例工厂函数名。
 * 新增纯函数模块时，在这里加一行，并同步在 entry/src/ohosTest/ets/test/List.test.ets 注册。
 */
const SUITES = [
  { path: 'entry/src/ohosTest/ets/test/TimelineMathCases.ets', exportName: 'timelineMathCases' },
  { path: 'entry/src/ohosTest/ets/test/TimelineClockCases.ets', exportName: 'timelineClockCases' },
  { path: 'entry/src/ohosTest/ets/test/PreviewLayoutCases.ets', exportName: 'previewLayoutCases' },
  { path: 'entry/src/ohosTest/ets/test/SegmentModelCases.ets', exportName: 'segmentModelCases' },
  { path: 'entry/src/ohosTest/ets/test/TripFormatCases.ets', exportName: 'tripFormatCases' },
  { path: 'entry/src/ohosTest/ets/test/EditHistoryCases.ets', exportName: 'editHistoryCases' },
  { path: 'entry/src/ohosTest/ets/test/EditRestoreCases.ets', exportName: 'editRestoreCases' }
]

const TSC_CANDIDATES = [
  'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js',
  'C:/Program Files/Huawei/DevEco Studio/tools/hvigor/hvigor-ohos-plugin/node_modules/typescript/lib/typescript.js'
]

function loadTypeScript() {
  for (const candidate of TSC_CANDIDATES) {
    if (existsSync(candidate)) {
      return require(candidate)
    }
  }
  throw new Error(
    '找不到 TypeScript 编译器。请修改 TSC_CANDIDATES，指向 DevEco 自带的 typescript/lib/typescript.js'
  )
}

const ts = loadTypeScript()

/** .ets 源码路径 → 构建目录里的 .ts 路径（内容不变，供 tsc 做类型解析） */
function toTsPath(relPath) {
  return join(BUILD_DIR, relPath.replace(/\.ets$/, '.ts'))
}

/** .ets 源码路径 → 构建目录里的 .mjs 路径（转译产物，供 Node 执行） */
function toMjsPath(relPath) {
  return join(BUILD_DIR, relPath.replace(/\.ets$/, '.mjs'))
}

/**
 * BFS 收集入口可达的全部纯模块。
 * 返回 relPath 列表；遇到裸导入直接抛错。
 */
function collectModules() {
  const collected = []
  const seen = new Set()
  const queue = SUITES.map((suite) => suite.path)

  while (queue.length > 0) {
    const relPath = queue.shift()
    if (seen.has(relPath)) continue
    seen.add(relPath)

    const absPath = join(ROOT, relPath)
    if (!existsSync(absPath)) {
      throw new Error(`找不到模块：${relPath}`)
    }
    const source = readFileSync(absPath, 'utf8')

    for (const match of source.matchAll(/from\s*['"]([^'"]+)['"]/g)) {
      const spec = match[1]
      if (!spec.startsWith('.')) {
        throw new Error(
          `${relPath} 导入了非相对模块 "${spec}"。\n` +
            '离线测试只覆盖纯函数层。请把纯逻辑拆到不依赖 @ohos / ArkUI 的模块里，' +
            '或把该模块移出入口的可达集合（不要静默跳过）。'
        )
      }
      const target = relative(
        ROOT,
        resolve(dirname(absPath), spec.replace(/\.ets$/, '') + '.ets')
      )
      queue.push(target)
    }

    // 原样复制成 .ts，保持相对目录结构，tsc 才能自然解析 '../model/Models'
    const tsPath = toTsPath(relPath)
    mkdirSync(dirname(tsPath), { recursive: true })
    writeFileSync(tsPath, source, 'utf8')
    collected.push(relPath)
  }

  return collected
}

/** 用 tsc 转译单个模块为 ESM，并把相对导入说明符改写成 .mjs */
function transpileModule(relPath) {
  const source = readFileSync(toTsPath(relPath), 'utf8')
  const result = ts.transpileModule(source, {
    fileName: relPath.replace(/\.ets$/, '.ts'),
    compilerOptions: {
      target: ts.ScriptTarget.ES2022,
      module: ts.ModuleKind.ESNext,
      removeComments: false
    },
    reportDiagnostics: true
  })

  const fatal = (result.diagnostics ?? []).filter(
    (d) => d.category === ts.DiagnosticCategory.Error
  )
  if (fatal.length > 0) {
    throw new Error(
      `${relPath} 转译失败：${fatal.map((d) => ts.flattenDiagnosticMessageText(d.messageText, ' ')).join('; ')}`
    )
  }

  const rewritten = result.outputText.replace(
    /(from\s*['"])(\.[^'"]+?)(['"])/g,
    (_m, head, spec, tail) => `${head}${spec.replace(/\.mjs$/, '')}.mjs${tail}`
  )

  const mjsPath = toMjsPath(relPath)
  mkdirSync(dirname(mjsPath), { recursive: true })
  writeFileSync(mjsPath, rewritten, 'utf8')
}

/** 对纯函数层做真实类型检查（tsc --noEmit 的等价物） */
function typeCheck(relPaths) {
  const rootNames = relPaths.map(toTsPath)
  const program = ts.createProgram(rootNames, {
    target: ts.ScriptTarget.ES2022,
    module: ts.ModuleKind.ESNext,
    moduleResolution: ts.ModuleResolutionKind.NodeJs,
    strict: true,
    noEmit: true,
    skipLibCheck: true,
    types: [],
    lib: ['lib.es2022.d.ts']
  })
  const diagnostics = ts.getPreEmitDiagnostics(program).filter(
    (d) => d.category === ts.DiagnosticCategory.Error
  )
  return diagnostics.map((d) => {
    const text = ts.flattenDiagnosticMessageText(d.messageText, ' ')
    if (!d.file || d.start === undefined) return text
    const pos = d.file.getLineAndCharacterOfPosition(d.start)
    const file = relative(ROOT, d.file.fileName).replace(/\\/g, '/')
    return `${file}:${pos.line + 1}:${pos.character + 1}  ${text}`
  })
}

/**
 * 跨语言一致性：ArkTS 的模板契约必须与原生导出契约逐条相等。
 * 这正是"预览一套、导出一套"这类漂移的守卫——两边分别改，测试就会红。
 * 来源：entry/src/main/cpp/export_engine.cpp 的 kNativeTemplateContracts。
 */
function readNativeContracts() {
  const cppPath = join(ROOT, 'entry/src/main/cpp/export_engine.cpp')
  const cpp = readFileSync(cppPath, 'utf8')
  const table = cpp.match(/kNativeTemplateContracts\s*=\s*\{\{([\s\S]*?)\}\};/)
  if (!table) {
    throw new Error('无法解析 export_engine.cpp 的 kNativeTemplateContracts')
  }
  const contracts = new Map()
  for (const row of table[1].matchAll(
    /\{\s*"([^"]+)"\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(true|false)\s*,\s*(true|false)\s*,\s*(true|false)\s*\}/g
  )) {
    contracts.set(row[1], {
      width: Number(row[2]),
      height: Number(row[3]),
      needSideTrack: row[4] === 'true',
      disableFrontAudio: row[5] === 'true',
      needSide2Track: row[6] === 'true'
    })
  }
  if (contracts.size === 0) {
    throw new Error('解析出的原生模板契约为 0 条')
  }
  return contracts
}

async function checkNativeContract() {
  const name = '跨语言：ArkTS 模板契约 == 原生导出契约'
  try {
    const native = readNativeContracts()
    const models = await import(pathToFileURL(toMjsPath('entry/src/main/ets/model/Models.ets')).href)
    const definitions = models.listTemplateDefinitions()

    const problems = []
    for (const def of definitions) {
      const contract = native.get(def.templateId)
      if (!contract) {
        problems.push(`${def.templateId} 在原生契约里不存在`)
        continue
      }
      if (def.canvasWidth !== contract.width || def.canvasHeight !== contract.height) {
        problems.push(
          `${def.templateId} 画布 ${def.canvasWidth}x${def.canvasHeight} != 原生 ${contract.width}x${contract.height}`
        )
      }
      if (def.ffmpegPolicy.needSideTrack !== contract.needSideTrack) {
        problems.push(
          `${def.templateId} needSideTrack ${def.ffmpegPolicy.needSideTrack} != 原生 ${contract.needSideTrack}`
        )
      }
      if (def.ffmpegPolicy.disableFrontAudio !== contract.disableFrontAudio) {
        problems.push(
          `${def.templateId} disableFrontAudio ${def.ffmpegPolicy.disableFrontAudio} != 原生 ${contract.disableFrontAudio}`
        )
      }
      if (def.ffmpegPolicy.needSide2Track !== contract.needSide2Track) {
        problems.push(
          `${def.templateId} needSide2Track ${def.ffmpegPolicy.needSide2Track} != 原生 ${contract.needSide2Track}`
        )
      }
    }
    if (definitions.length !== native.size) {
      problems.push(`模板数量 ${definitions.length} != 原生 ${native.size}`)
    }
    return problems.length > 0 ? { name, detail: problems.join('; ') } : { name, ok: true }
  } catch (err) {
    return { name, detail: err && err.message ? err.message : String(err) }
  }
}

/**
 * 颜色令牌守卫：spec §6.9 的 17 个令牌 + spec §5.2/§6.4/§6.5/§6.6/§6.7 用到但 §6.9 没列的
 * 8 个（胶囊底、选中字、浮层渐变与白色半透明）必须落在 color.json 且取值一致。
 * 页面与组件里不许再写十六进制色值，所以这里红一次就意味着「某个颜色没进资源」。
 */
const REQUIRED_COLOR_TOKENS = new Map([
  ['page_bg', '#F2F4F7'], ['card_bg', '#FFFFFF'], ['page_border', '#EAE8E3'],
  ['card_border', '#EDEAE4'], ['track_bg', '#F4F2ED'], ['segment_border', '#E4E1DA'],
  ['text_primary', '#1C1B18'], ['text_secondary', '#57534A'], ['text_tertiary', '#8A867D'],
  ['text_disabled', '#B5B0A6'], ['ink', '#111111'], ['amber', '#D98324'],
  ['amber_soft', '#FDF6EC'], ['stage_bg', '#14120F'], ['stage_divider', '#1E1B17'],
  ['segment_off_bg', '#EFEDE8'], ['segment_off_border', '#E7E4DE'],
  ['chip_bg', '#FBFAF8'], ['amber_deep', '#8A5A18'],
  ['overlay_veil', '#E614120F'], ['overlay_fade', '#0014120F'],
  ['overlay_track', '#4DFFFFFF'], ['overlay_text', '#D6FFFFFF'],
  ['overlay_btn_bg', '#29FFFFFF'], ['overlay_btn_border', '#42FFFFFF'],
  ['knob_shadow', '#8C000000'],
  // 播放钮的底：40% 暖黑 + 同色描边（2026-10-15 第三轮调整）。
  // 中途试过全透明（#00000000），亮画面上白图标读不出来，用户否掉了 —— 这个钮必须有底。
  ['stage_btn_bg', '#6614120F'], ['stage_btn_border', '#6614120F'], ['stage_btn_fg', '#FFFFFF'],
  ['export_scrim', '#88000000'], ['export_text', '#F8FAFC'],
  // 剪辑页暖白重设计（2026-10-15）：底色、卡面、描边、进度轨、模板卡留白与六个机位色
  ['ed_bg', '#F3F1EC'], ['ed_surface', '#FBFAF7'], ['ed_line', '#E6E0D3'],
  ['ed_track', '#F1EDE3'], ['ed_thumb_bg', '#F2EEE5'], ['ed_slot_fg', '#4A453C'],
  ['slot_cam_front', '#EDE6D6'], ['slot_cam_back', '#DAD6CE'],
  ['slot_cam_left', '#D6DED7'], ['slot_cam_right', '#E2D6D2'],
  ['slot_cam_left_front', '#E4EBE2'], ['slot_cam_right_front', '#EDE0DB']
])

function checkColorTokens() {
  const name = '颜色令牌齐全且取值正确'
  try {
    const raw = JSON.parse(
      readFileSync(join(ROOT, 'entry/src/main/resources/base/element/color.json'), 'utf8')
    )
    const actual = new Map(
      (raw.color ?? []).map((item) => [item.name, String(item.value).toUpperCase()])
    )
    const problems = []
    for (const [token, expected] of REQUIRED_COLOR_TOKENS) {
      const got = actual.get(token)
      if (got === undefined) problems.push(`${token} 缺失`)
      else if (got !== expected) problems.push(`${token} 期望 ${expected}，实际 ${got}`)
    }
    return problems.length > 0 ? { name, detail: problems.join('; ') } : { name, ok: true }
  } catch (err) {
    return { name, detail: err && err.message ? err.message : String(err) }
  }
}

/**
 * 页面与组件配色守卫（spec §8.11）：剪辑页与三个组件都不得出现遗留配色或十六进制色值，
 * 一律走 `$r('app.color.*')`。
 */
const UI_FILES = [
  'entry/src/main/ets/pages/Index.ets',
  'entry/src/main/ets/pages/Editor.ets',
  'entry/src/main/ets/components/EditorPreviewArea.ets',
  'entry/src/main/ets/components/SegmentParamRow.ets',
  'entry/src/main/ets/components/SegmentTrack.ets',
  'entry/src/main/ets/components/TemplateStrip.ets',
  'entry/src/main/ets/components/EditRecordCard.ets'
]

const LEGACY_COLORS = ['#FF7A00', '#0A59F7', '#FF4444', '#F97316', '#181818', '#282828', '#333333', '#121212', '#1A1A1A']

function checkNoLegacyColors() {
  const name = '剪辑页与组件无硬编码配色'
  const problems = []
  for (const rel of UI_FILES) {
    const src = readFileSync(join(ROOT, rel), 'utf8')
    for (const color of LEGACY_COLORS) {
      if (src.toUpperCase().includes(color)) {
        problems.push(`${rel} 仍含 ${color}`)
      }
    }
    const hits = src.match(/#[0-9A-Fa-f]{6,8}/g)
    if (hits) {
      problems.push(`${rel} 含十六进制色值 ${Array.from(new Set(hits)).join(' ')}`)
    }
  }
  return problems.length > 0 ? { name, detail: problems.join('; ') } : { name, ok: true }
}

/**
 * 轨道空白区恒建守卫（spec §3.6.4「空白区恒建」）。
 *
 * 为什么需要它：片头/片段间/片尾的空白区项是拖动时「让出/顶开」的那几秒的唯一容器。
 * 一旦有人图省事把它们改回「时长为 0 就不建」，两段紧贴时拖动边界会让所有项权重之和
 * 不再等于片长，ArkUI 把整条轨道按比例重摊一遍 —— 表现为「拖这一段，后面那段跟着位移，
 * 松手又弹回去」。这是已经发生过一次的真实缺陷（2026-10-15），所以在这里钉死。
 */
function checkGapItemsAlwaysBuilt() {
  const name = '轨道空白区恒建（拖动时权重和恒等于片长）'
  const rel = 'entry/src/main/ets/components/SegmentTrack.ets'
  const src = readFileSync(join(ROOT, rel), 'utf8')
  const start = src.indexOf('private buildTimelineItems()')
  if (start < 0) {
    return { name, detail: `${rel} 找不到 buildTimelineItems()` }
  }
  // 取到下一个同级方法（build() 之前）为止
  let end = src.indexOf('\n  build()', start)
  if (end < 0) {
    end = src.length
  }
  const body = src.slice(start, end)
  const problems = []
  for (const key of ['gap-head-', 'gap-tail-']) {
    if (!body.includes(key)) {
      problems.push(`buildTimelineItems 缺少恒建的 ${key} 项`)
    }
  }
  if (!/items\.push\(new TrackTimelineItem\(true, new Segment\(\), seg\.endSec, nextSeg\.startSec/.test(body)) {
    problems.push('片段间空白区没有无条件 push（被时长判断包住了？）')
  }
  const forbidden = [
    'sorted[0].startSec > 0.05',
    'nextSeg.startSec - seg.endSec > 0.05',
    'this.totalDurationSec - lastSeg.endSec > 0.05'
  ]
  for (const bad of forbidden) {
    if (body.includes(bad)) {
      problems.push(`空白区仍被条件 \`${bad}\` 挡住，时长为 0 时不会建项`)
    }
  }
  return problems.length > 0 ? { name, detail: problems.join('; ') } : { name, ok: true }
}

/**
 * 空档 key 必须带上「已提交边界秒数」守卫（spec §3.6.4）。
 *
 * 为什么需要它：空档宽度不是由它自己的 item 决定的，而是 liveGapWeight(item) 拿**建项时
 * 捕获的** startSec/endSec 去和「正在被拖的那条边界」比对现算的；而 ForEach 按 key 复用
 * 子组件时**不会重跑 item 生成函数**。于是只用相邻段 id 做 key 时：松手提交后新项的 key
 * 与旧项完全相同 → 子组件被原样复用、手里还是上一轮的旧边界 → 新旧边界对不上，两侧
 * 「贴着被拖边界」的判断全部落空，空档宽度退回旧值 0，紧贴的那一段被画到错误位置。
 * 这个坑已经踩过一次（2026-10-15：拖过一次之后空档不再跟手，后段跟着前段的边一起滑），
 * 在这里钉死。段块的 blockKey 本来就把边界编进 key，空档此前漏了。
 */
function checkGapKeysCarryCommittedBounds() {
  const name = '空档 key 带已提交边界（ForEach 复用拿不到过期 item）'
  const rel = 'entry/src/main/ets/components/SegmentTrack.ets'
  const src = readFileSync(join(ROOT, rel), 'utf8')
  const start = src.indexOf('private buildTimelineItems()')
  if (start < 0) {
    return { name, detail: `${rel} 找不到 buildTimelineItems()` }
  }
  let end = src.indexOf('\n  build()', start)
  if (end < 0) {
    end = src.length
  }
  const lines = src.slice(start, end).split('\n')
  const problems = []
  const kinds = [
    { prefix: '`gap-head-', label: '片头空档' },
    { prefix: '`gap-${', label: '段间空档' },
    { prefix: '`gap-tail-', label: '片尾空档' }
  ]
  for (const kind of kinds) {
    const line = lines.find((item) => item.includes('new TrackTimelineItem(true,') && item.includes(kind.prefix))
    if (!line) {
      problems.push(`${kind.label}的恒建 push 找不到（key 前缀应为 ${kind.prefix}）`)
      continue
    }
    const matched = line.match(/`([^`]*)`/)
    if (!matched) {
      problems.push(`${kind.label}的 key 不是模板字符串：${line.trim()}`)
      continue
    }
    const key = matched[1]
    if (!key.includes('.id')) {
      problems.push(`${kind.label}的 key \`${key}\` 没带上片段 id（拖动期间要稳定）`)
    }
    if (!/Sec\}/.test(key)) {
      problems.push(`${kind.label}的 key \`${key}\` 没带上已提交边界秒数：只用 id 时松手提交后 key 不变，ForEach 会复用手里拿着旧边界的子组件`)
    }
  }
  return problems.length > 0 ? { name, detail: problems.join('; ') } : { name, ok: true }
}

/**
 * 手柄覆盖层守卫（spec §3.6.1 手柄拖拽）。
 *
 * 为什么需要它：手柄前后踩过两个坑，都在这里钉死。
 * 坑一：`Row(){ 左手柄; Blank(); 右手柄 }` 流式排版 + 两个固定 44vp 子项 —— 块宽 < 88vp 时
 *   Row 放不下，左手柄占满整块、Blank 被压到 0、右手柄被排到块内固定 x=44..88vp 处，再叠加
 *   +22 居中偏移，圆点落在块内固定 x≈88vp 上：块越窄离真正的右边界越远，点它抓不到右边界。
 * 坑二：为了不越界，把触摸区整个夹在段块内部（min(44, 块宽/2)）—— 段块宽度 = 时长比例，
 *   长片里一个 15s 段可能只有几 vp 宽，触摸区跟着缩到几 vp，用户反馈「触摸的区域太小了，
 *   不容易拖动」；而且手柄塞在块内时，圆点还会被后画的相邻段盖住。
 * 现在的做法：手柄画在**轨道覆盖层**上（画在段块行之后，圆点永远在最上面），触摸区 =
 *   块外恒定 22vp + 块内一半（左右以块中心为界、互不重叠），触摸区用 HitTestMode.Transparent
 *   保证拖动优先命中手柄、同时不抢下面段块/空档的点击。
 */
function checkHandlesLiveInOverlayWithBigTouchAreas() {
  const name = '手柄画在轨道覆盖层上、触摸区够大且不抢邻居点击'
  const rel = 'entry/src/main/ets/components/SegmentTrack.ets'
  const src = readFileSync(join(ROOT, rel), 'utf8')
  const problems = []
  // 1. 触摸区宽度公式：外侧恒定 HANDLE_TOUCH_WIDTH/2 + 块内一半
  if (!/private handleTouchWidthVp\(\): number \{\s*return HANDLE_TOUCH_WIDTH \/ 2 \+ this\.handleInnerSpanVp\(\)/.test(src)) {
    problems.push('缺少 handleTouchWidthVp()（或公式不对）：触摸区必须 = 块外 HANDLE_TOUCH_WIDTH/2 + 块内一半，否则窄块又缩成几 vp')
  }
  const widthUsed = (src.match(/\.width\(this\.handleTouchWidthVp\(\)\)/g) ?? []).length
  if (widthUsed < 2) {
    problems.push(`左右手柄的触摸区都该用 .width(this.handleTouchWidthVp())，实际只有 ${widthUsed} 处`)
  }
  // 2. 块内那一半必须封顶在 22vp，否则窄块时左右触摸区互相重叠
  if (!/Math\.min\(HANDLE_TOUCH_WIDTH \/ 2, blockW \/ 2\)/.test(src)) {
    problems.push('handleInnerSpanVp() 没把块内那一半封顶在 HANDLE_TOUCH_WIDTH/2：窄块时左右触摸区会互相重叠、抢同一次拖动')
  }
  // 3. 触摸区必须 Transparent：它在覆盖层最上面，Default 会把下面段块/空档的点击全吃掉
  const transparent = (src.match(/HitTestMode\.Transparent/g) ?? []).length
  if (transparent < 2) {
    problems.push(`两条手柄触摸区都该用 HitTestMode.Transparent（实际 ${transparent} 处），否则它们盖住的段块/空档点不中`)
  }
  // 4. 覆盖层必须无参：段对象当 @Builder 参数时，ForEach 复用子树会拿到不刷新的旧值
  if (!/\n  handles\(\) \{/.test(src)) {
    problems.push('找不到无参 handles()：手柄必须画在轨道覆盖层上，而不是画在段块里面')
  }
  if (/handles\(segment/.test(src)) {
    problems.push('handles() 又带上了 segment 参数：段对象当 @Builder 参数在 ForEach 复用子树时不刷新')
  }
  // 5. 手柄位置必须由选中段的实时边界现算
  for (const fn of ['selectedLeftVp', 'selectedRightVp']) {
    if (!new RegExp(`private ${fn}\\(\\): number`).test(src)) {
      problems.push(`缺少 ${fn}()：手柄覆盖层必须按选中段的实时边界定位`)
    }
  }
  const posUsed = (src.match(/\.position\(\{ x: this\.selected(Left|Right)Vp\(\)/g) ?? []).length
  if (posUsed < 2) {
    problems.push(`左右手柄都该用 .position({ x: this.selected*Vp() ... }) 定位，实际 ${posUsed} 处`)
  }
  // 6. 覆盖层必须画在段块行之后，否则相邻段会盖住圆点
  const buildIdx = src.indexOf('\n  build() {')
  if (buildIdx < 0) {
    problems.push('找不到 build()')
  } else {
    const buildBody = src.slice(buildIdx)
    const rowIdx = buildBody.indexOf('ForEach(this.buildTimelineItems()')
    const overlayIdx = buildBody.indexOf('this.handles()')
    if (rowIdx < 0) {
      problems.push('build() 里找不到轨道 ForEach')
    } else if (overlayIdx < 0) {
      problems.push('build() 里没有渲染手柄覆盖层 this.handles()')
    } else if (overlayIdx < rowIdx) {
      problems.push('手柄覆盖层画在了段块行之前：相邻段会盖住手柄圆点，必须画在之后')
    }
  }
  // 7. 手柄段里不得退回 Row + Blank 流式排版
  const hStart = src.indexOf('\n  handles() {')
  const hEnd = hStart >= 0 ? src.indexOf('\n  }', hStart) : -1
  const hBody = hStart >= 0 && hEnd > hStart ? src.slice(hStart, hEnd) : ''
  if (hBody.includes('Blank()')) {
    problems.push('手柄又退回 Row + Blank 流式排版：固定宽子项在窄块里放不下，右手柄会被排到块内固定位置、圆点跑出块外')
  }
  return problems.length > 0 ? { name, detail: problems.join('; ') } : { name, ok: true }
}

/**
 * 轨道宽度绝对化守卫（spec §3.6.4「宽度绝对化」）。
 *
 * 为什么需要它：`layoutWeight` 是**按权重比例分摊整条轨道**（每项实得 = 轨宽 × w_i / Σw）。
 * 只要有一项的值不对（或某一帧没刷新），整行都会按比例重摊一遍，旁边的段跟着被拉伸/压缩 ——
 * 这正是「拖这一段，另一段被压扁/拉长」的来源。改成绝对宽度后每一项只由自己的时长决定，
 * 互不牵连。这个坑已经踩过一次（2026-10-15），在这里钉死，防止有人图省事改回 layoutWeight。
 */
function checkTrackUsesAbsoluteWidths() {
  const name = '轨道宽度绝对化（不用 layoutWeight 比例分摊）'
  const rel = 'entry/src/main/ets/components/SegmentTrack.ets'
  const raw = readFileSync(join(ROOT, rel), 'utf8')
  // 去掉注释再扫，否则说明性注释里提到的 layoutWeight 会误报
  const src = raw.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '')
  const problems = []
  if (!/private widthForSec\(sec: number\): number/.test(src)) {
    problems.push('缺少 widthForSec(sec)：秒 → 绝对宽度（vp）的换算')
  }
  if (!/\.width\(this\.widthForSec\(this\.liveBlockWeight\(segment\)\)\)/.test(src)) {
    problems.push('段块没有用绝对宽度：应为 .width(this.widthForSec(this.liveBlockWeight(segment)))')
  }
  if (!/\.width\(this\.widthForSec\(this\.liveGapWeight\(item\)\)\)/.test(src)) {
    problems.push('空白区块没有用绝对宽度：应为 .width(this.widthForSec(this.liveGapWeight(item)))')
  }
  const hits = src.match(/\.layoutWeight\(/g)
  if (hits) {
    problems.push(`仍有 ${hits.length} 处 layoutWeight：比例分摊下任何一项的值不对都会让整行重摊，旁边的段被拉伸/压缩`)
  }
  return problems.length > 0 ? { name, detail: problems.join('; ') } : { name, ok: true }
}

/**
 * 相对导入一致性守卫。
 *
 * 为什么需要它：ArkUI 文件（@Entry / @Component / @Builder）的装饰器让 tsc 解析不了，
 * 所以 `typecheck-player.mjs` 覆盖不到 `pages/` 与 `components/`；而「import 了一个
 * 目标模块并不存在的具名导出」正是 DevEco 构建报 10505001 的那一类错误。
 * 这个守卫只用正则扫文本，不依赖解析器，因此能覆盖 ArkUI 文件。
 */
function listEtsFiles(dir) {
  const out = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name)
    if (entry.isDirectory()) {
      out.push(...listEtsFiles(full))
    } else if (entry.name.endsWith('.ets')) {
      out.push(full)
    }
  }
  return out
}

function exportedNames(src) {
  const names = new Set()
  const declared = /\bexport\s+(?:declare\s+)?(?:abstract\s+)?(?:async\s+)?(?:class|interface|enum|struct|function|const|let|var|type)\s+([A-Za-z_$][\w$]*)/g
  let match
  while ((match = declared.exec(src)) !== null) {
    names.add(match[1])
  }
  const listed = /\bexport\s*(?:type\s*)?\{([^}]*)\}/g
  while ((match = listed.exec(src)) !== null) {
    for (const part of match[1].split(',')) {
      const piece = part.trim().replace(/^type\s+/, '')
      if (piece.length === 0) {
        continue
      }
      const alias = piece.match(/\bas\s+([A-Za-z_$][\w$]*)$/)
      names.add(alias ? alias[1] : piece)
    }
  }
  return names
}

function checkImportConsistency() {
  const name = '相对导入的具名符号都存在'
  const problems = []
  for (const file of listEtsFiles(join(ROOT, 'entry/src/main/ets'))) {
    const src = readFileSync(file, 'utf8')
    const rel = relative(ROOT, file).replace(/\\/g, '/')
    const reImport = /\bimport\s*\{([^}]*)\}\s*from\s*['"]([^'"]+)['"]/g
    let match
    while ((match = reImport.exec(src)) !== null) {
      const spec = match[2]
      if (!spec.startsWith('.')) {
        continue
      }
      const target = resolve(dirname(file), spec)
      const candidate = existsSync(`${target}.ets`)
        ? `${target}.ets`
        : (existsSync(join(target, 'index.ets')) ? join(target, 'index.ets') : '')
      if (candidate === '') {
        problems.push(`${rel} 找不到模块 ${spec}`)
        continue
      }
      const targetSrc = readFileSync(candidate, 'utf8')
      // 目标里有 `export *` 时无法静态判定，跳过以免误报。
      if (/\bexport\s*\*\s*from\b/.test(targetSrc)) {
        continue
      }
      const available = exportedNames(targetSrc)
      const targetRel = relative(ROOT, candidate).replace(/\\/g, '/')
      for (const part of match[1].split(',')) {
        const piece = part.trim().replace(/^type\s+/, '')
        if (piece.length === 0) {
          continue
        }
        const aliasParts = piece.split(/\s+as\s+/)
        const original = aliasParts[0].trim()
        if (!available.has(original)) {
          problems.push(`${rel} 从 ${targetRel} 导入了不存在的 ${original}${aliasParts.length > 1 ? ` (as ${aliasParts[1].trim()})` : ''}`)
        }
      }
    }
  }
  return problems.length > 0 ? { name, detail: problems.join('; ') } : { name, ok: true }
}

/**
 * 页面访问的 EditorStateModel 字段必须真实存在。
 *
 * DevEco 的 ArkTS 编译器会报 `Property 'x' does not exist on type 'EditorStateModel'`，
 * 而 tsc 解析不了 ArkUI 文件（装饰器与 build() 的 DSL 语法都不是合法 TS），
 * 所以这里手工对账一次：从 AppState.ets 取出接口字段，再扫声明了
 * `@State state: EditorStateModel` 的文件里的 `state.<name>` 访问。
 */
function checkStateMemberAccess() {
  const name = '页面访问的 EditorStateModel 字段都存在'
  const appStatePath = join(ROOT, 'entry/src/main/ets/model/AppState.ets')
  const appStateSrc = readFileSync(appStatePath, 'utf8')
  const header = 'export interface EditorStateModel {'
  const headerAt = appStateSrc.indexOf(header)
  if (headerAt < 0) {
    return { name, detail: `在 ${relative(ROOT, appStatePath).replace(/\\/g, '/')} 里找不到 ${header}` }
  }
  const bodyStart = headerAt + header.length
  let depth = 1
  let bodyEnd = bodyStart
  for (let i = bodyStart; i < appStateSrc.length; i += 1) {
    if (appStateSrc[i] === '{') {
      depth += 1
    } else if (appStateSrc[i] === '}') {
      depth -= 1
      if (depth === 0) {
        bodyEnd = i
        break
      }
    }
  }
  const body = appStateSrc.slice(bodyStart, bodyEnd)
  const fields = new Set()
  const reField = /^\s*([A-Za-z_$][\w$]*)\s*[?:]/gm
  let fieldMatch
  while ((fieldMatch = reField.exec(body)) !== null) {
    fields.add(fieldMatch[1])
  }
  if (fields.size === 0) {
    return { name, detail: 'EditorStateModel 没解析出任何字段，守卫会失效' }
  }
  const problems = []
  for (const file of listEtsFiles(join(ROOT, 'entry/src/main/ets'))) {
    const src = readFileSync(file, 'utf8')
    if (!/@State\s+(?:private\s+|protected\s+|public\s+)?state\s*:\s*EditorStateModel/.test(src)) {
      continue
    }
    const rel = relative(ROOT, file).replace(/\\/g, '/')
    const reUse = /\bstate\.([A-Za-z_$][\w$]*)/g
    let useMatch
    while ((useMatch = reUse.exec(src)) !== null) {
      if (!fields.has(useMatch[1])) {
        const line = src.slice(0, useMatch.index).split('\n').length
        problems.push(`${rel}:${line} 访问了不存在的 state.${useMatch[1]}`)
      }
    }
  }
  return problems.length > 0
    ? { name, detail: Array.from(new Set(problems)).join('; ') }
    : { name, ok: true }
}

/**
 * 代码里 $r('app.color.X') 引用的令牌必须在 color.json 里真实存在。
 *
 * 缺令牌时 DevEco 报资源找不到，而 tsc 看不见 $r()。
 * checkColorTokens 只保证 REQUIRED_COLOR_TOKENS 在色板里，管不了反向引用。
 */
function checkColorReferences() {
  const name = '颜色令牌引用都存在'
  const colorsPath = join(ROOT, 'entry/src/main/resources/base/element/color.json')
  const parsed = JSON.parse(readFileSync(colorsPath, 'utf8'))
  const have = new Set((parsed.color ?? []).map((item) => item.name))
  const problems = []
  for (const file of listEtsFiles(join(ROOT, 'entry/src/main/ets'))) {
    const src = readFileSync(file, 'utf8')
    const rel = relative(ROOT, file).replace(/\\/g, '/')
    const reRef = /\$r\(\s*['"]app\.color\.([A-Za-z0-9_]+)['"]\s*\)/g
    let match
    while ((match = reRef.exec(src)) !== null) {
      if (!have.has(match[1])) {
        const line = src.slice(0, match.index).split('\n').length
        problems.push(`${rel}:${line} 引用了不存在的颜色令牌 app.color.${match[1]}`)
      }
    }
  }
  return problems.length > 0
    ? { name, detail: Array.from(new Set(problems)).join('; ') }
    : { name, ok: true }
}

/**
 * 模板命名一致性守卫。
 *
 * 模板名有两个来源，界面到底显示哪个取决于调用点：
 *   - `AppConstants.getTemplateUiNameById()` —— TemplateStrip 优先用它；
 *   - `Models.ets` 的 `TEMPLATE_DEFINITION_MAP[].title` —— 取不到时的回落，也是导出/日志里的名字。
 *
 * 两处曾经漂移过：T3 一边叫「左右盲区」一边叫「侧向防开门杀」，T5 一边叫「单视角」
 * 一边叫「单前视」。界面上看不出来（走的是前者），但日志、回落路径和导出元数据会显示另一个名字。
 * AppConstants 依赖 @kit.AbilityKit，进不了本文件的纯模块 BFS，所以这里按文本对账。
 */
function checkTemplateNamingConsistency() {
  const name = '模板名在 AppConstants 与 Models 两处一致'
  try {
    const constantsSrc = readFileSync(
      join(ROOT, 'entry/src/main/ets/constants/AppConstants.ets'), 'utf8'
    )
    const modelsSrc = readFileSync(join(ROOT, 'entry/src/main/ets/model/Models.ets'), 'utf8')

    // 1) AppConstants：只在 getTemplateUiNameById 的函数体里找 if/return 对
    const fnAt = constantsSrc.indexOf('export function getTemplateUiNameById')
    if (fnAt < 0) {
      return { name, detail: 'AppConstants.ets 里找不到 getTemplateUiNameById' }
    }
    const nextFnAt = constantsSrc.indexOf('export function', fnAt + 1)
    const body = constantsSrc.slice(fnAt, nextFnAt > 0 ? nextFnAt : constantsSrc.length)
    const uiNames = new Map()
    for (const m of body.matchAll(/if\s*\(\s*templateId\s*===\s*'(\w+)'\s*\)\s*\{\s*return\s*'([^']*)'/g)) {
      uiNames.set(m[1], m[2])
    }
    if (uiNames.size === 0) {
      return { name, detail: 'AppConstants.getTemplateUiNameById 没解析出任何模板名，守卫会失效' }
    }

    // 2) Models：每个 `[TemplateId.TX]: {` 到下一个标记之间，第一条 title: 就是模板名
    const marks = []
    for (const m of modelsSrc.matchAll(/\[TemplateId\.(T\d)\]:\s*\{/g)) {
      marks.push({ id: m[1], at: m.index })
    }
    if (marks.length === 0) {
      return { name, detail: 'Models.ets 没解析出任何 TEMPLATE_DEFINITION_MAP 条目' }
    }
    const modelTitles = new Map()
    for (let i = 0; i < marks.length; i += 1) {
      const end = i + 1 < marks.length ? marks[i + 1].at : modelsSrc.length
      const block = modelsSrc.slice(marks[i].at, end)
      const titleMatch = block.match(/title:\s*'([^']*)'/)
      if (titleMatch) {
        modelTitles.set(marks[i].id, titleMatch[1])
      }
    }

    const problems = []
    for (const [id, uiName] of uiNames) {
      const modelTitle = modelTitles.get(id)
      if (modelTitle === undefined) {
        problems.push(`${id} 在 Models.ets 里没有对应条目`)
      } else if (modelTitle !== uiName) {
        problems.push(`${id}：AppConstants 叫「${uiName}」，Models 叫「${modelTitle}」`)
      }
    }
    if (uiNames.size !== modelTitles.size) {
      problems.push(`模板数量 AppConstants ${uiNames.size} != Models ${modelTitles.size}`)
    }
    return problems.length > 0 ? { name, detail: problems.join('; ') } : { name, ok: true }
  } catch (err) {
    return { name, detail: err && err.message ? err.message : String(err) }
  }
}

/**
 * 预览播放守卫（原 spec §5.4「播放跳过灰段与空档」已于 2026-10-15 作废）。
 *
 * 为什么需要它：页面曾在播放头推进时按 `playbackSkipTargetSec` 跳过灰段与空档。
 * 末段之后的片尾空档，其跳过目标正好是 `totalDurationSec` —— 于是**自动播放一走到最后一个
 * 片段的结束位置，进度条就直接跳到视频末尾**（用户 2026-10-15 报告：「看起来像是进度条只能
 * 在片段属于的区间，期望进度条可以播放整个视频，不受片段影响」）。
 * 媒体层其实从来不知道剪辑段：`EditorPreviewArea` 只吃 `tripSnapshot.clips`，
 * `buildSegmentSpans(clips, camera, grid)` 按整条行程的录像片段绑 span —— 跳过纯粹是页面层
 * 自己加的。所以修法就是不再跳过；模型里那个函数随之删除，不留死代码与断言过期行为的用例。
 */
function checkPreviewPlaybackNeverSkipsSegments() {
  const name = '预览播放不按片段跳过（进度条覆盖整条源视频）'
  const problems = []
  const pageRel = 'entry/src/main/ets/pages/Editor.ets'
  const page = readFileSync(join(ROOT, pageRel), 'utf8')
  // 只看真实用法（调用 / 导入 / 状态赋值），注释里提到名字不算：注释正是用来说明它为什么被删掉的。
  if (/playbackSkipTargetSec\s*\(/.test(page) || /import[^\n]*playbackSkipTargetSec/.test(page)) {
    problems.push(`${pageRel} 仍在用 playbackSkipTargetSec：末段之后的片尾空档会跳到 totalDurationSec，进度条一播到末段结束就冲到底`)
  }
  if (/skippingToTargetSec\s*[:=]/.test(page)) {
    problems.push(`${pageRel} 仍留着 skippingToTargetSec 状态：跳过逻辑没删干净`)
  }
  const handlerIdx = page.indexOf('private handlePreviewPlayheadChanged(')
  if (handlerIdx < 0) {
    problems.push(`${pageRel} 找不到 handlePreviewPlayheadChanged()`)
  } else {
    let end = page.indexOf('\n  private ', handlerIdx + 10)
    if (end < 0) {
      end = page.length
    }
    const body = page.slice(handlerIdx, end)
    if (!body.includes('this.updatePlayheadSec(nextSec)')) {
      problems.push('handlePreviewPlayheadChanged() 不再连续推进播放头（应保留 this.updatePlayheadSec(nextSec)）')
    }
  }
  const modelRel = 'entry/src/main/ets/model/SegmentModel.ets'
  const model = readFileSync(join(ROOT, modelRel), 'utf8')
  if (model.includes('playbackSkipTargetSec')) {
    problems.push(`${modelRel} 仍导出 playbackSkipTargetSec：该行为已作废，应连同用例一起删除`)
  }
  return problems.length > 0 ? { name, detail: problems.join('; ') } : { name, ok: true }
}

async function main() {
  rmSync(BUILD_DIR, { recursive: true, force: true })
  const modules = collectModules()
  for (const relPath of modules) {
    transpileModule(relPath)
  }

  const failures = []

  // 1) 类型检查
  const typeErrors = typeCheck(modules)
  if (typeErrors.length > 0) {
    failures.push({
      name: `类型检查（${typeErrors.length} 处）`,
      detail: typeErrors.join('\n      ')
    })
  }

  // 2) 纯函数用例
  let passed = 0
  for (const suite of SUITES) {
    const casesModule = await import(pathToFileURL(toMjsPath(suite.path)).href)
    const factory = casesModule[suite.exportName]
    if (typeof factory !== 'function') {
      failures.push({
        name: `${suite.path} 缺少导出 ${suite.exportName}()`,
        detail: '请检查 SUITES 配置或用例文件的导出名'
      })
      continue
    }
    const cases = factory()
    for (const testCase of cases) {
      let failure = ''
      try {
        failure = testCase.run() ?? ''
      } catch (err) {
        failure = `抛出异常：${err && err.message ? err.message : String(err)}`
      }
      if (failure === '') {
        passed += 1
      } else {
        failures.push({ name: testCase.name, detail: failure })
      }
    }
  }

  // 3) 跨语言契约
  const contract = await checkNativeContract()
  if (contract.ok) {
    passed += 1
  } else {
    failures.push({ name: contract.name, detail: contract.detail })
  }

  // 4) 颜色令牌
  const colors = checkColorTokens()
  if (colors.ok) {
    passed += 1
  } else {
    failures.push({ name: colors.name, detail: colors.detail })
  }

  // 5) 页面与组件里不许有硬编码配色
  const uiColors = checkNoLegacyColors()
  if (uiColors.ok) {
    passed += 1
  } else {
    failures.push({ name: uiColors.name, detail: uiColors.detail })
  }

  // 6) 相对导入的具名符号必须真实存在（覆盖 tsc 解析不了的 ArkUI 文件）
  const imports = checkImportConsistency()
  if (imports.ok) {
    passed += 1
  } else {
    failures.push({ name: imports.name, detail: imports.detail })
  }

  // 7) 页面访问的 state 字段必须真实存在（同样覆盖 ArkUI 文件）
  const stateMembers = checkStateMemberAccess()
  if (stateMembers.ok) {
    passed += 1
  } else {
    failures.push({ name: stateMembers.name, detail: stateMembers.detail })
  }

  // 8) $r('app.color.X') 引用的令牌必须真实存在
  const colorRefs = checkColorReferences()
  if (colorRefs.ok) {
    passed += 1
  } else {
    failures.push({ name: colorRefs.name, detail: colorRefs.detail })
  }

  // 9) 模板名在 AppConstants 与 Models 两处必须一致
  const templateNames = checkTemplateNamingConsistency()
  if (templateNames.ok) {
    passed += 1
  } else {
    failures.push({ name: templateNames.name, detail: templateNames.detail })
  }

  // 10) 轨道空白区必须恒建（见 checkGapItemsAlwaysBuilt 注释）
  const gapItems = checkGapItemsAlwaysBuilt()
  if (gapItems.ok) {
    passed += 1
  } else {
    failures.push({ name: gapItems.name, detail: gapItems.detail })
  }

  // 11) 轨道宽度必须绝对化，不得退回 layoutWeight 比例分摊
  const absWidths = checkTrackUsesAbsoluteWidths()
  if (absWidths.ok) {
    passed += 1
  } else {
    failures.push({ name: absWidths.name, detail: absWidths.detail })
  }

  // 12) 空档 key 必须带已提交边界（见 checkGapKeysCarryCommittedBounds 注释）
  const gapKeys = checkGapKeysCarryCommittedBounds()
  if (gapKeys.ok) {
    passed += 1
  } else {
    failures.push({ name: gapKeys.name, detail: gapKeys.detail })
  }

  // 13) 手柄必须画在轨道覆盖层上，触摸区够大且不抢邻居点击
  //     （见 checkHandlesLiveInOverlayWithBigTouchAreas 注释）
  const handleAreas = checkHandlesLiveInOverlayWithBigTouchAreas()
  if (handleAreas.ok) {
    passed += 1
  } else {
    failures.push({ name: handleAreas.name, detail: handleAreas.detail })
  }

  // 14) 预览播放不得按片段跳过（见 checkPreviewPlaybackNeverSkipsSegments 注释）
  const playback = checkPreviewPlaybackNeverSkipsSegments()
  if (playback.ok) {
    passed += 1
  } else {
    failures.push({ name: playback.name, detail: playback.detail })
  }

  const total = passed + failures.length
  console.log(`\n离线纯函数测试：${passed}/${total} 通过`)
  console.log(`收集模块 ${modules.length} 个，产物 ${relative(ROOT, BUILD_DIR).replace(/\\/g, '/')}/\n`)

  if (failures.length > 0) {
    for (const f of failures) {
      console.log(`  ✗ ${f.name}\n      ${f.detail}`)
    }
    console.log('')
    process.exitCode = 1
    return
  }
  console.log('  全部通过 ✓\n')
}

await main()
