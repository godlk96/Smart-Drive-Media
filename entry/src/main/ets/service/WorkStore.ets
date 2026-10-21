/**
 * 「作品库」的文件系统层：只管 `filesDir/exports/` 这一个目录的读写。
 *
 * 一件作品 = 目录下三个**同名**文件（`<id>.mp4` / `<id>.json` / `<id>.jpg`），
 * 基名即作品 id。本层不碰相册、不碰 preferences、不扫媒体库 —— 目录里有什么就是什么，
 * 因此不需要任何权限。
 *
 * 为什么不用 preferences 记录链：成片本体已经进了
 * App 私有空间，元数据跟着文件走（sidecar）比另存一份记录更不容易失配 ——
 * 删掉 mp4 就等于删掉作品，不需要「孤儿记录」这种对账。
 *
 * 本文件导入 `@ohos.file.fs` / `@ohos.file.statvfs` / `@ohos.app.ability.common`，
 * **不是纯模块**，因此不能进 tools/offline-test.mjs 的 SUITES（离线桩遇裸导入会抛错），
 * 只进 tools/typecheck-player.mjs 的 deps。
 *
 * 目录里可能混进合成中间态（native 的 `<out>.front.concat.mp4`、JS 的
 * `input_<ts>_<n>.mp4`），它们都以 `.mp4` 结尾。本层靠 `isWorkVideoFileName`
 * 的**整串锚定**把它们挡在门外，绝不用「以 .mp4 结尾」这种宽松规则。
 */

import fs from '@ohos.file.fs'
import statvfs from '@ohos.file.statvfs'
import common from '@ohos.app.ability.common'
import { WorkMeta, isWorkVideoFileName, parseWorkMeta, serializeWorkMeta, workIdFromFileName,
  workSortKey } from '../model/WorkMeta'
import { extractFirstFrameToPath } from './ExportNativeService'
import { debugLog } from '../utils/Logger'

/** 列表项：一件作品的四个入口信息。`meta` 为 undefined 即降级卡片（无 sidecar）。 */
export class WorkEntry {
  /** 作品 id = 文件基名 */
  id: string = ''
  /** `<id>.mp4` 的绝对路径 */
  videoPath: string = ''
  /** `<id>.jpg` 的绝对路径；不存在时为空串，调用方回退到占位图 */
  coverPath: string = ''
  /** sidecar；缺失/损坏时为 undefined */
  meta: WorkMeta | undefined = undefined
  /** 排序键（有 sidecar 用 exportedAt，否则退回文件名时间戳） */
  sortKey: number = 0
}

export class WorkStore {
  private static instance: WorkStore | null = null
  private context: common.UIAbilityContext | null = null

  public static getInstance(): WorkStore {
    if (!WorkStore.instance) {
      WorkStore.instance = new WorkStore()
    }
    return WorkStore.instance
  }

  /** App 启动或进页面时注入一次 context 即可；重复设置无副作用。 */
  public setContext(context: common.UIAbilityContext | null): void {
    this.context = context
  }

  /**
   * 作品库目录 = `${filesDir}/exports`。**不保证存在** —— 首次启动时还没有，
   * 需要写的调用方先走 `ensureExportsDir`；只读的调用方拿它当路径用即可。
   * context 未注入时返回空串，调用方据此直接走空/失败分支。
   */
  public exportsDir(): string {
    if (!this.context) {
      return ''
    }
    const filesDir = this.context.filesDir
    if (!filesDir || filesDir.length === 0) {
      return ''
    }
    return `${filesDir}/exports`
  }

  /** 列出全部作品，按 `sortKey` 倒序（新导出的在前）。**永不抛错**。 */
  public async list(): Promise<Array<WorkEntry>> {
    const entries: Array<WorkEntry> = []
    const dir = this.exportsDir()
    if (dir.length === 0) {
      return entries
    }
    let names: Array<string> = []
    try {
      names = await fs.listFile(dir)
    } catch (e) {
      // 目录不存在（首次启动）或不可读：列表为空，不抛错。
      debugLog('WorkStore', `列出作品目录失败 ${dir}: ${String(e)}`)
      return entries
    }
    for (let i = 0; i < names.length; i++) {
      const name = names[i]
      // 只收严格满足作品名契约的项：宽松过滤会把 concat 残留 / input_* 副本列成幽灵卡片。
      if (!isWorkVideoFileName(name)) {
        continue
      }
      const videoPath = `${dir}/${name}`
      // 目录也可能恰好撞上这个命名，跳过去，别当作品。
      if (await this.isDirectory(videoPath)) {
        continue
      }
      const id = workIdFromFileName(name)
      const entry = new WorkEntry()
      entry.id = id
      entry.videoPath = videoPath
      entry.coverPath = this.resolveCoverPath(dir, id)
      const meta = await this.readMeta(id)
      // 坏 sidecar 只让这一条降级，不牵连整个列表。
      entry.meta = meta
      entry.sortKey = workSortKey(meta, name)
      entries.push(entry)
    }
    entries.sort((a: WorkEntry, b: WorkEntry): number => b.sortKey - a.sortKey)
    return entries
  }

  /** 读一件作品的 sidecar。缺失、读失败、解析失败一律返回 undefined（降级卡片）。 */
  public async readMeta(id: string): Promise<WorkMeta | undefined> {
    if (id.length === 0) {
      return undefined
    }
    const dir = this.exportsDir()
    if (dir.length === 0) {
      return undefined
    }
    const path = `${dir}/${id}.json`
    if (!this.exists(path)) {
      return undefined
    }
    try {
      const raw = await fs.readText(path)
      return parseWorkMeta(raw)
    } catch (e) {
      debugLog('WorkStore', `读取 sidecar 失败 ${path}: ${String(e)}`)
      return undefined
    }
  }

  /**
   * 原子写 sidecar：先写 `<id>.json.tmp`，再替换成 `<id>.json`。失败返回 false。
   *
   * `.json` 是「作品完成」的标记（导出顺序 mp4 → jpg → json），所以这一写必须
   * 要么整份可见、要么整份不可见，绝不能落下一个写了一半的 json 让列表读到。
   */
  public async writeMeta(meta: WorkMeta): Promise<boolean> {
    if (meta.id.length === 0) {
      return false
    }
    const dir = this.exportsDir()
    if (dir.length === 0) {
      return false
    }
    if (!(await this.ensureExportsDir())) {
      return false
    }
    const target = `${dir}/${meta.id}.json`
    const tmp = `${target}.tmp`
    try {
      await this.writeTextToPath(tmp, serializeWorkMeta(meta))
    } catch (e) {
      debugLog('WorkStore', `写 sidecar 临时文件失败 ${tmp}: ${String(e)}`)
      await this.unlinkQuiet(tmp)
      return false
    }
    try {
      // 先试直接 rename（能原子覆盖最好）。
      await fs.rename(tmp, target)
      return true
    } catch (e) {
      debugLog('WorkStore', `rename 覆盖 sidecar 失败，退化 unlink + rename: ${String(e)}`)
    }
    // 兜底：真机上 fs.rename 可能拒绝覆盖已存在文件。此刻 .tmp 已完整，
    // 先删旧文件再改名，中间窗口极短。
    try {
      await this.unlinkQuiet(target)
      await fs.rename(tmp, target)
      return true
    } catch (e) {
      debugLog('WorkStore', `替换 sidecar 失败 ${target}: ${String(e)}`)
      await this.unlinkQuiet(tmp)
      return false
    }
  }

  /**
   * 抽取成片首帧，原子落盘为 `exports/<id>.jpg`（封面）。失败返回 false（绝不抛）。
   *
   * **覆盖导出时有意重新抽帧**：文件名（= 作品 id）跨覆盖不变，任何基于文件名的
   * 缓存 key 都会命中上一次的旧图，卡片永远停在旧封面。所以这里刻意绕开
   * `isUsableThumbnail` 那条缓存路径，每次都真抽（`extractFirstFrameToPath`
   * 自身也不查缓存）。别把它「优化」回缓存。
   *
   * 与 `writeMeta` 同一套原子替换：先写 `<id>.jpg.tmp`，成功再替换成 `<id>.jpg`；
   * 真机上 `fs.rename` 可能拒绝覆盖已存在文件，故先 unlink 目标再改名。
   * 任何路径都不留下 `.jpg.tmp`。
   */
  public async writeCoverFrom(sourceVideoPath: string, id: string, aspectRatio: number): Promise<boolean> {
    if (sourceVideoPath.length === 0 || id.length === 0) {
      return false
    }
    const dir = this.exportsDir()
    if (dir.length === 0) {
      return false
    }
    if (!(await this.ensureExportsDir())) {
      return false
    }
    const target = `${dir}/${id}.jpg`
    const tmp = `${target}.tmp`
    // extractFirstFrameToPath 只写 tmp、失败返回 false、内部绝不抛；这里再兜一层
    // try/catch，保证 writeCoverFrom 在任何情况下都只返回布尔、不向上抛。
    let extracted = false
    try {
      extracted = await extractFirstFrameToPath(sourceVideoPath, tmp, aspectRatio)
    } catch (e) {
      debugLog('WorkStore', `抽取封面首帧异常 ${tmp}: ${String(e)}`)
      extracted = false
    }
    if (!extracted) {
      await this.unlinkQuiet(tmp)
      return false
    }
    try {
      // 先试直接 rename（能原子覆盖最好）。
      await fs.rename(tmp, target)
      return true
    } catch (e) {
      debugLog('WorkStore', `rename 覆盖封面失败，退化 unlink + rename: ${String(e)}`)
    }
    // 兜底：真机上 fs.rename 可能拒绝覆盖已存在文件。此刻 .tmp 已完整，
    // 先删旧封面再改名，中间窗口极短。
    try {
      await this.unlinkQuiet(target)
      await fs.rename(tmp, target)
      return true
    } catch (e) {
      debugLog('WorkStore', `替换封面失败 ${target}: ${String(e)}`)
      await this.unlinkQuiet(tmp)
      return false
    }
  }

  /**
   * 把合成产物（`cacheDir/<id>.mp4.tmp` 之类）搬成作品库里的 `<id>.mp4`。
   *
   * 跨目录搬运用 `fs.rename`：`cacheDir` 与 `filesDir` 同属 App 沙盒、同一挂载点。
   *
   * 与 `writeMeta` / `writeCoverFrom` 同一套替换顺序：**先试直接 rename**（能原子覆盖最好），
   * 失败才退化成「先 unlink 目标再 rename」。绝不能反过来无条件先删 ——
   * 删掉之后 rename 再抛错，用户手里那条作品就**没了**，而新成片还留在 cacheDir，
   * 调用方只能报一句「导出产物保存失败」。覆盖导出删的是用户唯一一份成片，
   * 这条路径必须走「删之前先确认改名能成」。
   */
  public async moveIntoLibrary(sourcePath: string, id: string): Promise<boolean> {
    if (sourcePath.length === 0 || id.length === 0) {
      return false
    }
    const dir = this.exportsDir()
    if (dir.length === 0) {
      return false
    }
    if (!(await this.ensureExportsDir())) {
      return false
    }
    const target = `${dir}/${id}.mp4`
    try {
      // 先试直接 rename（能原子覆盖最好）。
      await fs.rename(sourcePath, target)
      return true
    } catch (e) {
      debugLog('WorkStore', `rename 覆盖成片失败，退化 unlink + rename: ${String(e)}`)
    }
    // 兜底：真机上 fs.rename 可能拒绝覆盖已存在文件。此刻源文件已完整，
    // 先删旧成片再改名，中间窗口极短。
    try {
      await this.unlinkQuiet(target)
      await fs.rename(sourcePath, target)
      return true
    } catch (e) {
      debugLog('WorkStore', `搬运成片失败 ${sourcePath} -> ${target}: ${String(e)}`)
      return false
    }
  }

  /**
   * 删掉一件作品的 sidecar 与封面，**保留成片本体** `<id>.mp4`。任一不存在不算错；
   * 返回 false 仅当有文件存在却删不掉。**永不抛错**。
   *
   * 覆盖导出专用，且必须在成片替换**之前**调用：作品 id 跨覆盖不变，旧 sidecar/封面
   * 若不清掉，一旦其后的 `writeMeta` 失败（或进程在中间被杀），留在盘上的就是
   * 「**新成片 + 上一次编辑的元数据**」—— 卡片看上去可以重新剪辑（`canReedit` 只看
   * `meta !== undefined`），点进去却按旧模板/旧分段/旧水印去还原一条不是它渲染出来的视频，
   * 再导出一次就把新编辑静默改回旧编辑。
   *
   * 清掉它们之后，最坏结局退化成**已设计**的降级态：有 mp4 无 json，卡片显示
   * 「无法重新剪辑」，用户至少知道真相。这也是「mp4 → jpg → json」那个写入顺序的前提 ——
   * 该顺序只对**新作品**成立，覆盖时得先把上一份 sidecar 拿掉才等价。
   */
  public async clearWorkMetaAndCover(id: string): Promise<boolean> {
    if (id.length === 0) {
      return false
    }
    const dir = this.exportsDir()
    if (dir.length === 0) {
      return false
    }
    const targets: Array<string> = [`${dir}/${id}.json`, `${dir}/${id}.jpg`]
    let ok = true
    for (let i = 0; i < targets.length; i++) {
      const path = targets[i]
      try {
        if (this.exists(path)) {
          await fs.unlink(path)
        }
      } catch (e) {
        ok = false
        debugLog('WorkStore', `清理旧元数据/封面失败 ${path}: ${String(e)}`)
      }
    }
    return ok
  }

  /**
   * 删一件作品的三份文件（`.mp4` / `.json` / `.jpg`）。任一不存在不算错。
   * 返回 false 仅当有文件存在却删不掉。
   */
  public async deleteWork(id: string): Promise<boolean> {
    if (id.length === 0) {
      return false
    }
    const dir = this.exportsDir()
    if (dir.length === 0) {
      return false
    }
    const targets: Array<string> = [`${dir}/${id}.mp4`, `${dir}/${id}.json`, `${dir}/${id}.jpg`]
    let ok = true
    for (let i = 0; i < targets.length; i++) {
      const path = targets[i]
      try {
        if (this.exists(path)) {
          await fs.unlink(path)
        }
      } catch (e) {
        ok = false
        debugLog('WorkStore', `删除作品文件失败 ${path}: ${String(e)}`)
      }
    }
    return ok
  }

  /** 作品库所在卷的剩余字节数；取不到返回 -1（调用方据此跳过空间校验）。 */
  public async freeBytes(): Promise<number> {
    const dir = this.exportsDir()
    if (dir.length === 0) {
      return -1
    }
    try {
      return await statvfs.getFreeSize(dir)
    } catch (e) {
      debugLog('WorkStore', `查询剩余空间失败 ${dir}: ${String(e)}`)
      return -1
    }
  }

  /** 同名 `.jpg` 存在则给路径，否则空串（卡片回退到占位图）。 */
  private resolveCoverPath(dir: string, id: string): string {
    const cover = `${dir}/${id}.jpg`
    return this.exists(cover) ? cover : ''
  }

  /** `accessSync` 在不存在时返回 false，但其他错误会抛；一律收敛成布尔。 */
  private exists(path: string): boolean {
    try {
      return fs.accessSync(path)
    } catch (e) {
      return false
    }
  }

  /**
   * 把一段字符串写到指定路径。SDK 没有 `fs.writeText`，只能 open → write → close
   * （与 ExportNativeService 的 writeArrayBufferToFile 同一套写法）。
   */
  private async writeTextToPath(path: string, content: string): Promise<void> {
    let fd: number = -1
    try {
      const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC)
      fd = file.fd
      await fs.write(fd, content)
    } catch (error) {
      // 带上路径：sidecar / 封面写失败时要能一眼看出是哪个文件。
      const message = error instanceof Error ? error.message : String(error)
      throw new Error(`写入 ${path} 失败：${message}`)
    } finally {
      if (fd >= 0) {
        try {
          await fs.close(fd)
        } catch (_) {
        }
      }
    }
  }

  private async unlinkQuiet(path: string): Promise<void> {
    try {
      if (this.exists(path)) {
        await fs.unlink(path)
      }
    } catch (e) {
      debugLog('WorkStore', `删除失败 ${path}: ${String(e)}`)
    }
  }

  private async isDirectory(path: string): Promise<boolean> {
    try {
      const stat = await fs.stat(path)
      return stat.isDirectory()
    } catch (e) {
      return false
    }
  }

  private async ensureExportsDir(): Promise<boolean> {
    const dir = this.exportsDir()
    if (dir.length === 0) {
      return false
    }
    if (this.exists(dir)) {
      return true
    }
    try {
      await fs.mkdir(dir, true)
      return true
    } catch (e) {
      debugLog('WorkStore', `创建作品目录失败 ${dir}: ${String(e)}`)
      return false
    }
  }
}
