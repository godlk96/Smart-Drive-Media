/**
 * 「作品库」还原链路：轨道记录、片段级缺失判定、命中并集、快照合成。
 *
 * 为什么需要它：旧的还原身份校验（`snapshotMatchesTrip`）只比 `(标题, 起点)`，
 * 用户在导出之后删掉**中间**某个源片段，校验照样通过 —— 用户拿到一条看着对、
 * 其实从删除点起整体错位的成片（设计稿 3.2 的静默错）。
 *
 * 新的身份锚是**导出那一刻真正送进 native 的四条轨道**（有序、含重复），记成源片段
 * 文件名。还原时逐位比对「这些文件还在不在」（`findMissingClipNames`），任一缺失即
 * 判「素材已不在」。**不再**按记录逐位重建 URI 轨道：导出侧重算一次模板轨道的结果
 * 与记录一致（见 `buildRestoredTripSnapshot` 的注释），多留一份「重建」API 只会
 * 与真正跑的那条路分歧。
 *
 * 本文件**不得**导入 @ohos.* / @kit.*：它是纯数据 + 纯函数，要被
 * tools/offline-test.mjs 直接跑（离线桩遇到裸导入会直接抛错）。
 * 只相对导入 `./WorkMeta` / `./TripModels` / `./Models`。
 */

import { WorkMeta, WorkTracks } from './WorkMeta'
import { DvrMeta, ExportComposeRequest, TripSnapshot } from './TripModels'
import { ExportSnapshot, normalizeTemplateIdValue, tripFromSnapshot } from './Models'

/** 四条轨道按固定顺序（front → back → side → side2）摊平，供「合并去重」与「缺失判定」共用。 */
function flattenTracks(tracks: WorkTracks): Array<string> {
  const out: Array<string> = []
  const groups: Array<Array<string>> = [tracks.front, tracks.back, tracks.side, tracks.side2]
  for (let g = 0; g < groups.length; g++) {
    const group = groups[g]
    for (let i = 0; i < group.length; i++) {
      out.push(group[i])
    }
  }
  return out
}

/** 把一条轨道的 URI 逐个反查回文件名；查不到的位放空串，绝不静默跳过。 */
function resolveUris(uris: Array<string>, nameByUri: Map<string, string>): Array<string> {
  const out: Array<string> = []
  for (let i = 0; i < uris.length; i++) {
    const name = nameByUri.get(uris[i])
    out.push(name === undefined ? '' : name)
  }
  return out
}

/**
 * 把 request 的四条轨道**按顺序**反查回 `DvrMeta.fileName`，得到要写进 sidecar 的 `WorkTracks`。
 *
 * 刻意不按机位分组再重排：轨道里同一文件可能重复或跳过，只有逐位照抄 request 的原始顺序
 * 才能让还原侧复现出与导出时一模一样的那四条轨道（`resolveTemplateTracks` /
 * `alignSideUrisByFront` 的产物是位置敏感的）。
 *
 * URI 查不到时放**空串**而不是丢掉这一位：空串在还原侧一律判缺失，宁可让用户看到
 * 「素材已不在」，也不能因为少了一格而把后面所有段静默前移。
 */
export function collectWorkTracks(clips: Array<DvrMeta>, request: ExportComposeRequest): WorkTracks {
  const nameByUri = new Map<string, string>()
  for (let i = 0; i < clips.length; i++) {
    const clip = clips[i]
    if (clip.uri.length === 0) {
      continue
    }
    if (!nameByUri.has(clip.uri)) {
      nameByUri.set(clip.uri, clip.fileName)
    }
  }
  const tracks = new WorkTracks()
  tracks.front = resolveUris(request.frontUris, nameByUri)
  tracks.back = resolveUris(request.backUris, nameByUri)
  tracks.side = resolveUris(request.sideUris, nameByUri)
  tracks.side2 = resolveUris(request.side2Uris, nameByUri)
  return tracks
}

/** 四条轨道合并、去重、丢空串，保留首次出现顺序。作品用到过哪些源文件，靠它。 */
export function collectTrackClipNames(tracks: WorkTracks): Array<string> {
  const names = flattenTracks(tracks)
  const out: Array<string> = []
  for (let i = 0; i < names.length; i++) {
    const name = names[i]
    if (name.length === 0) {
      continue
    }
    if (out.indexOf(name) < 0) {
      out.push(name)
    }
  }
  return out
}

/**
 * 现场**可用**的源片段文件名：丢掉空文件名与空 URI 的条目。给 `findMissingClipNames`
 * 的第二参用。
 *
 * 为什么必须有它：`findMissingClipNames` 只认名字、看不见 URI，若调用方直接把
 * `liveClips.map(c => c.fileName)` 递进去，一条 URI 为空的片段会被判成「还在」，
 * 而 `collectHitClips` 会判成「找不到」—— 同一份数据两处结论相反，
 * 还原链路就会漏报「素材已不在」，把一段黑屏送进编码器。
 */
export function collectLiveFileNames(clips: Array<DvrMeta>): Array<string> {
  const out: Array<string> = []
  for (let i = 0; i < clips.length; i++) {
    const clip = clips[i]
    if (clip.fileName.length === 0 || clip.uri.length === 0) {
      continue
    }
    out.push(clip.fileName)
  }
  return out
}

/**
 * 返回缺失的源片段文件名，按**首次出现顺序**，同名只报一次；空串一律算缺失。
 *
 * 逐位扫四条轨道而不是只比首尾：缺的可能是中间某一格，而那一格正是旧校验漏掉、
 * 导致成片整体错位的情形。
 *
 * `liveFileNames` 只应传**可用**的现场片段名（见 `collectLiveFileNames`）—— 本函数
 * 看不到 URI，传进来的名字一律当作「文件确实可用」。
 */
export function findMissingClipNames(tracks: WorkTracks, liveFileNames: Array<string>): Array<string> {
  const present = new Set<string>()
  for (let i = 0; i < liveFileNames.length; i++) {
    if (liveFileNames[i].length > 0) {
      present.add(liveFileNames[i])
    }
  }
  const names = flattenTracks(tracks)
  const missing: Array<string> = []
  for (let i = 0; i < names.length; i++) {
    const name = names[i]
    if (name.length > 0 && present.has(name)) {
      continue
    }
    if (missing.indexOf(name) < 0) {
      missing.push(name)
    }
  }
  return missing
}

/**
 * 同名多份的取舍：`timestamp` 升序、再 `uri` 字典序。
 *
 * 必须给出一条**全序**（而不是「谁先遇到用谁」）：现场片段数组的顺序由扫描决定，
 * 同名多份时若按输入顺序取，同一份 sidecar 在两次还原里可能指向不同 URI。定成全序后
 * 结果与输入顺序无关，可复现。
 */
function isEarlier(a: DvrMeta, b: DvrMeta): boolean {
  if (a.timestamp !== b.timestamp) {
    return a.timestamp < b.timestamp
  }
  return a.uri < b.uri
}

/**
 * 命中并集：被任一轨道引用过的源片段，按**文件名**去重（同名多份取 timestamp 最早、
 * 再 uri 字典序，与 `isEarlier` 同一套取舍），最后按 timestamp 升序 ——
 * 保证与 liveClips 的输入顺序无关。
 *
 * 空文件名与**空 URI**的现场片段一律排除，与 `collectLiveFileNames` 的「不可用」判定同口径。
 * 必须排除空 URI：`tripFromSnapshot` 会 `filter(clip.uri.length > 0)` 丢掉它们，而
 * `applyRestoredState` 用 `live.clips.length` 当片段总数（`CoreBridge.ets:867`）——
 * 放进来会让剪辑页的计数与实际行程对不上。
 */
function collectHitClips(tracks: WorkTracks, liveClips: Array<DvrMeta>): Array<DvrMeta> {
  const referenced = new Set<string>()
  const names = collectTrackClipNames(tracks)
  for (let i = 0; i < names.length; i++) {
    referenced.add(names[i])
  }
  const chosen = new Map<string, DvrMeta>()
  for (let i = 0; i < liveClips.length; i++) {
    const clip = liveClips[i]
    if (clip.fileName.length === 0 || clip.uri.length === 0 || !referenced.has(clip.fileName)) {
      continue
    }
    const existing = chosen.get(clip.fileName)
    if (existing === undefined || isEarlier(clip, existing)) {
      chosen.set(clip.fileName, clip)
    }
  }
  // 再扫一遍现场片段，只留每个文件名被选中的那一个对象 —— 同名多份因此只出现一次。
  const out: Array<DvrMeta> = []
  const pushed = new Set<string>()
  for (let i = 0; i < liveClips.length; i++) {
    const clip = liveClips[i]
    if (chosen.get(clip.fileName) !== clip || pushed.has(clip.fileName)) {
      continue
    }
    pushed.add(clip.fileName)
    out.push(clip)
  }
  out.sort((a: DvrMeta, b: DvrMeta) => {
    if (a.timestamp !== b.timestamp) {
      return a.timestamp - b.timestamp
    }
    return a.uri < b.uri ? -1 : (a.uri > b.uri ? 1 : 0)
  })
  return out
}

/**
 * 用 sidecar + 现场片段合成一份 `TripSnapshot`，交给 `restoreEditorStateFromSnapshot` 还原。
 *
 * `durationSec` 取自 `meta.durationMs`（用户上次导出的成片时长），**不是**从片段累加 ——
 * 剪辑过的片长与源片段总长无关，累加会得到一个错的时长，时间轴、边界标记、播放头全跟着错。
 *
 * `timeline` 刻意留空：`buildTimeline` 在 `service/TimelineService.ets`，那个模块导入了
 * `libsmartdrive_exporter.so` 与 `./CoreApiContract`，本纯模块引不了。由 Task 9 的
 * `CoreBridge` 拿到快照后补 `live.timeline = buildTimeline(live.clips)`。
 *
 * ## 与设计稿的**有意偏差**：还原不逐位复现记录下来的四条轨道，而是重算一次
 *
 * 设计稿（3.2）写的是「按 `meta.tracks` 逐位把 URI 装回去」。实际做法是：这里只从
 * `meta.tracks` 取出**命中的片段集合**（`collectHitClips`，顺序无关），随后照常走
 * 导出那条路 —— `ExportService.resolveTemplateTracks` 按模板的 `ffmpegPolicy` /
 * `canvasWidth` / 候选顺序，**重新**推导出四条轨道。
 *
 * 今天这样是等价的，因为重算的输入恰好就是记录里引用过的那些片段：
 * - 现场多出**从未被这条作品选中过**的源素材 → 它们进不了 `collectHitClips`，
 *   也就进不了重算的输入，扰不动结果；
 * - 少掉**从未被选中过**的候选片段 → 同上，删掉它不会让某个 argmin 换人；
 * - 唯一能让重算结果与记录不同的情形，是模板本身的规则变了（`ffmpegPolicy` /
 *   `canvasWidth` / 候选排序被改），那时「旧作品按新规则重导」本身就是要的效果。
 *
 * **残余风险（已知、接受）**：上面最后一条也是风险 —— 改了模板规则之后，一条老作品
 * 重新导出的成片会与它**第一次渲染出来的**不一样（轨道选择可能变），而卡片上并没有
 * 任何提示。真要改模板规则，得连同这条一起想清楚（版本化 `templateId`，或在 sidecar 里
 * 记下当时的轨道快照）。
 */
export function buildRestoredTripSnapshot(meta: WorkMeta, liveClips: Array<DvrMeta>): TripSnapshot {
  const snapshot = new TripSnapshot()
  snapshot.id = `trip-restored-${meta.id}`
  snapshot.tripTitle = meta.tripTitle
  snapshot.durationSec = meta.durationMs / 1000
  snapshot.startTs = meta.tripStartTs
  snapshot.endTs = meta.tripEndTs
  snapshot.clips = collectHitClips(meta.tracks, liveClips)
  snapshot.timeline = []
  for (let i = 0; i < snapshot.clips.length; i++) {
    const clip = snapshot.clips[i]
    if (snapshot.previewUri.length === 0 && clip.uri.length > 0) {
      snapshot.previewUri = clip.uri
    }
    if (snapshot.previewCamera.length === 0 && clip.camera.length > 0) {
      snapshot.previewCamera = clip.camera
    }
  }
  return snapshot
}

/**
 * 把 sidecar 还原成 `restoreEditorStateFromSnapshot` 需要的那份 `ExportSnapshot`。
 *
 * 参数（模板 / 播放头 / 分段 / 水印）以 sidecar 为准 —— 这正是用户点「重新剪辑」想拿回来的；
 * 素材（trip）以现场快照为准，由调用方传入。`sessionId` / `createdAt` 还原链路不读，
 * 从 meta 取真实值填上，免得留空看起来像坏数据。
 *
 * `templateId` 存的是 string（sidecar 是外部数据，可能含未知值），这里用
 * `normalizeTemplateIdValue` 收敛成合法模板，未知值回落到默认模板。
 */
export function exportSnapshotFromWorkMeta(meta: WorkMeta, live: TripSnapshot): ExportSnapshot {
  return {
    sessionId: meta.id,
    createdAt: meta.exportedAt,
    trip: tripFromSnapshot(live),
    selectedTemplateId: normalizeTemplateIdValue(meta.templateId),
    playback: meta.playback,
    brand: { watermarkEnabled: meta.watermarkEnabled }
  }
}
