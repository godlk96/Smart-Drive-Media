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
  { path: 'entry/src/ohosTest/ets/test/TripFormatCases.ets', exportName: 'tripFormatCases' }
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
    /\{\s*"([^"]+)"\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(true|false)\s*,\s*(true|false)\s*\}/g
  )) {
    contracts.set(row[1], {
      width: Number(row[2]),
      height: Number(row[3]),
      needSideTrack: row[4] === 'true',
      disableFrontAudio: row[5] === 'true'
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
  ['stage_btn_bg', '#24FFFFFF'], ['stage_btn_border', '#3DFFFFFF'], ['stage_btn_fg', '#F0FFFFFF'],
  ['export_scrim', '#88000000'], ['export_text', '#F8FAFC']
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
  'entry/src/main/ets/components/TemplateStrip.ets'
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
