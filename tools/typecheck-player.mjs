/**
 * 对**播放链路**（SingleTrackController / GlobalTimelineManager）做真实类型检查。
 *
 * 为什么单独做：hvigor 全量构建在本沙箱里跑不起来（它要在工作区外创建 symlink，
 * 被沙箱 + Windows 权限双重拒绝），但这两个文件是**纯 TS 类**（不含 ArkUI 装饰器），
 * 因此可以直接用 DevEco 自带的 tsc + SDK 真实的 @ohos.* 声明做类型检查。
 *
 * 用法：node tools/typecheck-player.mjs
 * 退出码 0 = 无错误；非 0 = 打印每个错误（文件:行:列）。
 */

import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, join, relative, resolve } from 'node:path'

const require = createRequire(import.meta.url)
const ROOT = resolve(import.meta.dirname, '..')
const BUILD = join(ROOT, '.player-typecheck')
const SDK_API = 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/api'

const TSC_CANDIDATES = [
  'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js',
  'C:/Program Files/Huawei/DevEco Studio/tools/hvigor/hvigor-ohos-plugin/node_modules/typescript/lib/typescript.js'
]

function loadTypeScript() {
  for (const c of TSC_CANDIDATES) {
    if (existsSync(c)) return require(c)
  }
  throw new Error('找不到 TypeScript 编译器，请修正 TSC_CANDIDATES')
}

const ts = loadTypeScript()

/** 要检查的文件（入口）+ 它们依赖的纯模块，全部按原相对结构复制成 .ts */
const ENTRIES = [
  'entry/src/main/ets/media/SingleTrackController.ets',
  'entry/src/main/ets/media/GlobalTimelineManager.ets'
]
const DEPS = [
  'entry/src/main/ets/media/TimelineMath.ets',
  'entry/src/main/ets/media/TimelineClock.ets',
  'entry/src/main/ets/utils/Logger.ets',
  'entry/src/main/ets/model/TripModels.ets',
  'entry/src/main/ets/model/AppState.ets'
]

/** ArkTS/运行环境提供的全局函数，TS 默认不知道 */
const GLOBALS_D_TS = `
declare function canIUse(feature: string): boolean
declare function setTimeout(handler: () => void, delay?: number): number
declare function clearTimeout(id: number): void
declare function setInterval(handler: () => void, delay?: number): number
declare function clearInterval(id: number): void
`

rmSync(BUILD, { recursive: true, force: true })
for (const rel of [...ENTRIES, ...DEPS]) {
  const src = join(ROOT, rel)
  if (!existsSync(src)) {
    console.log(`跳过（不存在）：${rel}`)
    continue
  }
  const dst = join(BUILD, rel.replace(/\.ets$/, '.ts'))
  mkdirSync(dirname(dst), { recursive: true })
  writeFileSync(dst, readFileSync(src, 'utf8'), 'utf8')
}
writeFileSync(join(BUILD, 'globals.d.ts'), GLOBALS_D_TS, 'utf8')

/**
 * 把 SDK 的 @ohos.*.d.ts 平铺成 BUILD/node_modules/<name>.d.ts。
 * 这样 `import media from '@ohos.multimedia.media'` 走标准 node 解析即可命中，
 * 且 d.ts 内部的 `./@ohos.base` 之类相对导入也在同一目录里能解析。
 */
const sdkModulesDir = join(BUILD, 'node_modules')
mkdirSync(sdkModulesDir, { recursive: true })
let staged = 0
for (const name of readdirSync(SDK_API)) {
  if (!name.endsWith('.d.ts')) continue
  writeFileSync(join(sdkModulesDir, name), readFileSync(join(SDK_API, name), 'utf8'), 'utf8')
  staged += 1
}
console.log(`已平铺 SDK 声明 ${staged} 个到 node_modules/`)

const rootNames = [...ENTRIES, ...DEPS]
  .map((rel) => join(BUILD, rel.replace(/\.ets$/, '.ts')))
  .filter((p) => existsSync(p))
rootNames.push(join(BUILD, 'globals.d.ts'))

const options = {
  target: ts.ScriptTarget.ES2022,
  module: ts.ModuleKind.ESNext,
  moduleResolution: ts.ModuleResolutionKind.NodeJs,
  strict: true,
  noEmit: true,
  skipLibCheck: true,
  types: [],
  lib: ['lib.es2022.d.ts']
}

const program = ts.createProgram(rootNames, options)
const diagnostics = ts.getPreEmitDiagnostics(program)

const lines = []
for (const d of diagnostics) {
  const text = ts.flattenDiagnosticMessageText(d.messageText, ' ')
  if (!d.file || d.start === undefined) {
    lines.push(`(global) ${text}`)
    continue
  }
  const pos = d.file.getLineAndCharacterOfPosition(d.start)
  const file = relative(ROOT, d.file.fileName).replace(/\\/g, '/')
  lines.push(`${file}:${pos.line + 1}:${pos.character + 1}  ${text}`)
}

console.log(`检查文件 ${rootNames.length} 个，诊断 ${lines.length} 条\n`)
if (lines.length > 0) {
  for (const l of lines) console.log(`  ${l}`)
  process.exitCode = 1
} else {
  console.log('  无类型错误 ✓')
}
