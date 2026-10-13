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

import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
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
  { path: 'entry/src/ohosTest/ets/test/PreviewLayoutCases.ets', exportName: 'previewLayoutCases' }
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
