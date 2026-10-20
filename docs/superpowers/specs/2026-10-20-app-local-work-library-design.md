# 剪单「作品库」：把成片主存迁进 App 私有空间

- **日期**：2026-10-20
- **状态**：待评审 (Draft rev.2 —— 已并入 builder-check 复核意见)
- **文档路径**：`docs/superpowers/specs/2026-10-20-app-local-work-library-design.md`
- **取代**：`docs/superpowers/specs/2026-10-18-my-edits-history-design.md` 的 4.1 / 4.2 / 4.5 / 4.6 / 4.7 / 4.8 / 4.11

---

## 1. 目标与背景 (Intent & The Why)

### 1.1 现状

「我的剪辑」今天是这样运作的（详见 2026-10-18 设计稿）：

1. 成片合成到 `cacheDir` 的临时文件（`entry/src/main/ets/service/ExportManager.ets:199`）；
2. 经 `showAssetsCreationDialog` 弹系统「保存到相册」对话框（`:317`），把字节拷进**系统图库**的一条新条目，记录里存 `albumUri`；
3. 作品记录**整表**序列化进一个 preferences key `pref_edit_records`（`entry/src/main/ets/service/PreferencesService.ets:11`），上限 50 条 + 4MB 预算，超了从最旧淘汰（`entry/src/main/ets/model/EditRecord.ets:321` 与 `:329`）；
4. 列表渲染的是这张记录表；异步补封面、异步探孤儿；
5. 还原时用 `(tripTitle, tripStartTs)` 做行程身份校验。

### 1.2 痛点

三处结构性负担，都是「成片在系统图库」这一条逼出来的：

**一、两层数据。** 记录层 App 完全掌控，成片层受系统受控权限约束 —— `module.json5` 只声明了 `READ_IMAGEVIDEO`，没有 `WRITE_IMAGEVIDEO`，所以 `deleteAssets` 必然 201 失败。于是：覆盖只能「就地覆写 + `TRUNC`」，删除只能删记录、相册那份留着，孤儿检测还要权限感知（`entry/src/main/ets/viewmodel/HomeViewModel.ets:454`）。

**二、`tripId` 会漂。** 构造是 `trip-${title}-${startTime}-${index}`（`entry/src/main/ets/bridge/CoreBridge.ets:493`），`index` 是该分组在**整次扫描**里的序号。源素材增删会让后面的行程整体重编号，一个存下来的 `tripId` 会静默指向另一趟行程。所以到处都要用 `(tripTitle, tripStartTs)` 交叉校验。

**三、校验粒度错了，而且会静默出错。** 这是本次要修的实伤：

- `snapshotMatchesTrip`（`entry/src/main/ets/model/Models.ets:529`）只比 `(stored.trip.title, stored.trip.startTs)` 对 `(live.tripTitle, live.startTs)`；
- 而 `startTs` 来自该行程**最早那个片段**的时间戳、`title` 来自它的日期（`entry/src/main/ets/bridge/CoreBridge.ets:487`）；
- 所以删片段分两种：删掉**最早**的 → 两字段都变 → 拦住了；删掉**中间或靠后**的 → 两字段一个都不变 → **静默放行**；
- 放行后 `restoreEditorStateFromSnapshot`（`Models.ets:547`）用**少了那个片段的现场轨道**配记录里的 `playback.segments`；native 侧把每条机位的片段 concat 成一个文件、再按 `atrim=start=X:end=Y` 切（`entry/src/main/cpp/export_engine.cpp:393`）—— 轨道短了一段，**后面所有段的偏移整体前移 60 秒**（`CLIP_DURATION_SEC`），切出来就是另一段画面。

用户拿到一份「看着像、其实不是」的成片，全程无任何提示。这直接违反 2026-10-18 设计稿 2.3 的反目标 3。

### 1.3 核心改动

**把成片的主存从系统图库搬进 App 私有空间。** 相册那份降级成一个显式的「保存到相册」动作，App 之后不再管它。

一句话模型：

> **一件作品 = 导出目录里的一个 `mp4` + 同名的 `json` + 同名的 `jpg`。**

记录层与成片层的隔离（2026-10-18 设计稿 3.2）这个前提本身消失 —— 两者都在 App 空间里，App 对两者都有完全控制权。

用户原话（2026-10-20）：「可以两边都存一下(APP+图库)，图库的不再需要处理 比如删除 比如覆盖」；「就按照你的方案」（采纳「App 私有空间当主存 + 显式保存到相册」的形状）；「现在存的都不要了」（不迁移旧数据）。

---

## 2. 目标、非目标与反目标

### 2.1 目标 (Goals)

1. **导出落进 App 私有空间**：可覆盖、可删除、可列出，全程零系统权限、零系统对话框。
2. **列表以导出目录为准**：不读 preferences、不扫相册、不要权限。
3. **还原判定改成片段级**：杜绝 1.2 里那条静默出错路径。
4. **「保存到相册」变成显式动作**：用户想分享时才点。
5. **导出成功后引导用户去看作品列表**。

### 2.2 非目标 (Non-Goals)

- 不做 App 内播放器（沿用 2026-10-18 的决定：▶ 交给系统播放器）。
- 不做云同步、跨设备、备份。
- 不做作品改名、排序、分享面板。
- **不迁移旧数据**（见 4.10）。

### 2.3 反目标 (Anti-Goals —— 做了就算失败)

- **绝不自动删除用户的作品**。磁盘紧张也不静默清理，宁可导出失败。
- **绝不静默用错素材**。片段对不上宁可明确报错。
- **绝不留下半截文件**。写入必须原子；宁可这次导出失败，也不要一个打不开的 mp4。
- **绝不假装图库那份归 App 管**。删除文案要说清相册里的副本不会跟着删。

---

## 3. 核心设计

### 3.1 存储布局

```
filesDir/
  exports/                                       ← 作品库，只放成品
    SmartDrive_Export_20261018_210400.mp4        成片本体
    SmartDrive_Export_20261018_210400.json       元数据（sidecar）
    SmartDrive_Export_20261018_210400.jpg        封面首帧

cacheDir/                                        ← 合成中间态，沿用今天的位置
    SmartDrive_Export_20261018_210400.mp4.tmp           native 输出目标
    SmartDrive_Export_20261018_210400.mp4.tmp.front.concat.mp4     native 的轨道 concat 副本
    SmartDrive_Export_20261018_210400.mp4.tmp.side.concat.mp4
    input_<ts>_<n>.mp4                                JS 侧的源素材落地副本
```

文件**基名**（去掉扩展名）就是**作品 id**。覆盖时基名不变，所以作品 id 稳定、可跨会话引用。

命名沿用 `buildExportFileName()`（`entry/src/main/ets/service/ExportManager.ets:69`）的 `SmartDrive_Export_YYYYMMDD_HHMMSS` 形式。它只有秒级精度，同一秒内连导两次会撞名 —— 新建时加一次存在性检查，撞了就补后缀（覆盖场景不受影响，基名本来就沿用旧的）。

**`exports/` 必须保持干净，所以合成中间态全部留在 `cacheDir`。** 这不是随手决定：native 会把每条轨道的 concat 副本写成 `outputPath + ".front.concat.mp4"` 之类（`entry/src/main/ets/../../cpp/export_engine.cpp:1631-1659`），JS 侧会把不在 `/data/storage/` 下的源素材复制成 `resolveParentDir(outputPath)/input_<ts>_<n>.mp4`（`entry/src/main/ets/service/ExportNativeService.ets:390`）。这些名字都以 `.mp4` 结尾、且都以 `SmartDrive_Export_` 开头，**任何宽松过滤都拦不住**。正常路径下它们会被清理（JS 的 `finally`、native 的 `std::remove`），但进程被杀就会留下。

因此：`outputPath` 继续指向 `cacheDir`，合成完成后再把成品移进 `filesDir/exports/`。

### 3.2 sidecar 数据契约

```typescript
export const WORK_META_SCHEMA_VERSION: number = 1

/** 四条轨道：与 ExportComposeRequest 的 frontUris/backUris/sideUris/side2Uris 一一对应 */
export class WorkTracks {
  front: Array<string> = []
  back: Array<string> = []
  side: Array<string> = []
  side2: Array<string> = []
}

export class WorkMeta {
  schemaVersion: number = WORK_META_SCHEMA_VERSION
  /** 作品 id = 文件基名 */
  id: string = ''
  /** 首次导出时刻（覆盖不刷新） */
  createdAt: number = 0
  /** 最近一次导出时刻（覆盖会刷新），列表按它倒序 */
  exportedAt: number = 0
  /** 「10月1日 周三」/「10月1日 合并行程」，卡片展示用 */
  tripTitle: string = ''
  tripStartTs: number = 0
  tripEndTs: number = 0
  /**
   * 还原身份锚 = **实际送进 native 的四条轨道**，有序、含重复，
   * 元素是源片段文件名（`DVR_LoopRecording_..._camera.mp4`）。
   */
  tracks: WorkTracks = new WorkTracks()
  /** T1..T6 */
  templateId: string = ''
  /** 用户改的那部分参数（ExportSnapshot.playback） */
  playback: PlaybackState | null = null
  watermarkEnabled: boolean = false
  /** 卡片展示用；从 playback.segments 推导亦可，存下来省一次计算 */
  segmentCount: number = 0
  durationMs: number = 0
}
```

**为什么记「四条轨道」而不是「机位 → 该机位的全部片段」**（这是 rev.1 的一个设计错误）：

`resolveTemplateTracks`（`entry/src/main/ets/service/ExportService.ets:82-124`）**不是**一个静态的「模板 → 机位」映射，它是对着**导出那一刻的现场片段列表**跑的：

- T1 的 `frontTrackCandidates` 是 `[FRONT, LEFT_FRONT, RIGHT_FRONT]`，实际选中哪一路取决于现场有哪些机位；
- 对 `alignSideByFrontTimeline` 为真的模板（T2/T4/T6），side 轨由 `alignSideUrisByFront`（`:42-80`）**按 front 轨逐个片段挑时间戳最近邻**构造，长度等于 front 轨，且**可能重复或跳过**同一个 side 文件。

所以「机位 → 全部片段」这份信息既**判不准**（按候选并集取会过严，删掉一个 Right 片段会拦住一个实际只用 Front+Rear 的 T1 作品），也**装不回**（按机位分组、按文件名升序装配，复现不出 `alignSideUrisByFront` 那条带重复的轨道）。而轨道一错位，`atrim` 偏移整体平移，正是 1.2 里那个静默错。

记下**实际送进 native 的四条轨道**之后：判定是精确的差集，装配是逐位复现，而且**完全不需要再查 `ffmpegPolicy`**。

**刻意不存 `ExportSnapshot.trip`。** `restoreEditorStateFromSnapshot`（`Models.ets:547`）只读 `selectedTemplateId` / `playback` / `brand.watermarkEnabled`，素材一律走现场。而 `trip.tracks` 里那份「全部片段 + 每条 URI」正是 snapshot 体积的大头（几十 KB 量级）。丢掉它，sidecar 降到 1KB 以内 —— 这让「每条作品一个 sidecar 文件」在列表加载时完全无压力。

### 3.3 前提修正：源片段文件名今天没有进快照

rev.1 声称「`snapshot.trip.tracks` 里本来就有全部片段，只是换成文件名」。**这是错的。** `tripFromSnapshot`（`entry/src/main/ets/model/Models.ets:419-451`）把 `DvrMeta` 映射成 `ClipSegment { clipId, camera, uri, timestampMs, durationSec }` 时**丢掉了 `DvrMeta.fileName`**；而 `ExportManager.snapshotToLegacyClips`（`ExportManager.ets:56`）里那句 `clip.fileName = \`${segment.clipId}.mp4\`` 是**编造的**，`clipId` 本身又是 `${snapshot.id}_${camera}_${timestamp}_${index}`（`Models.ets:434`），带着不稳定的 trip id 和一个会随删除移位的下标。

**改法**：给 `ClipSegment` 加 `fileName: string`，在 `tripFromSnapshot` 里从 `DvrMeta.fileName` 填上；`snapshotToLegacyClips` 改用真实文件名。`Models.ets` 是纯模型（要被 `tools/offline-test.mjs` 的 `EditRestoreCases.ets` 直接跑，不能引裸导入），加一个 `string` 字段不违反这条约束。

### 3.4 三条链路

```
【导出】剪辑页 ──点导出──▶ 已有同源作品? ──有──▶ 问「覆盖那一条 / 存成新的」
                              │                        │
                              └──无──▶ 直接导出 ◀──────┘
                                        │
                                        ▼
                合成到 cacheDir/<id>.mp4.tmp ──▶ 移到 filesDir/exports/<id>.mp4
                                        │
                                        ▼
                     抽首帧 <id>.jpg ──▶ 写 <id>.json ──▶ toast「已保存 · 查看作品」

【列表】我的剪辑 ──▶ listFile(exports/) ──▶ 逐个读同名 .json
                              │
                              ├─ 有 json ──▶ 完整卡片，可重剪、可覆盖、可删
                              └─ 无 json ──▶ 降级卡片，只可看/存相册/删

【还原】点卡片 ──▶ params{ workId }
                      │
                      ├─ 参数：取 sidecar（权威）
                      ├─ 素材：按 tracks 里的文件名反查现场片段，逐位重建四条轨道
                      └─ 缺片段 ──▶ 明确报错，不静默用错
```

---

## 4. 详细设计

### 4.1 导出

`ExportManager.run()`（`entry/src/main/ets/service/ExportManager.ets:190`）改动：

1. 合成输出指向 `cacheDir/<id>.mp4.tmp`（`<id>` 由 `buildExportFileName()` 生成；覆盖时**沿用被覆盖那条作品的基名**，不重新生成）。
2. 合成成功后把成品移进 `filesDir/exports/<id>.mp4`。
3. 抽首帧写 `filesDir/exports/<id>.jpg`（见 4.7）。
4. **最后**写 `filesDir/exports/<id>.json`（见 4.2 的原子写）。

顺序是有意的：json 落盘即代表「这件作品完成」。中途被杀最坏得到「有 mp4 没 json」，列表照样显示，只是不可重剪 —— 比今天整表 JSON 坏掉全丢更好。

导出任务需要额外携带 **`tracks`（四条轨道的文件名）**：在 `buildComposeRequestByService` 选出轨道之后，把每条选中的 URI 反查回它对应的 `DvrMeta.fileName`。依赖 3.3 的前提修正。

`saveVideoToAlbum`（`:294`）从导出主流程里**摘出去**，改成 4.6 的独立动作。

### 4.2 原子写

- **mp4**：native 输出到 `cacheDir/<id>.mp4.tmp`，完成后移进 `exports/<id>.mp4`。跨目录移动用 `fs.rename`（同一 App 沙盒，同一挂载点）。
- **json / jpg**：先写 `<name>.tmp`，完成后替换。

**替换时若目标已存在**（覆盖场景），保守做法是 `unlink` 旧文件再 `rename` —— 中间窗口极短，且此刻 `.tmp` 已经完整。`fs.rename` 能否直接覆盖已存在文件需真机确认（见第 6 节风险 2）；能覆盖就直接 rename。

sidecar 的解析**永不抛错**：坏 JSON 退化成「无元数据」，只降级这一条作品，不牵连列表。这比今天 `parseEditRecords`（`EditRecord.ets:110`）的「整表坏掉就返回空列表」隔离性更好。

### 4.3 列表

`HomeViewModel.refreshMyEdits`（`entry/src/main/ets/viewmodel/HomeViewModel.ets:315`）重写：

1. `fs.listFile(exportsDir)`；目录不存在 → 空列表（不报错）。
2. **严格过滤**：文件名匹配 `^SmartDrive_Export_\d{8}_\d{6}(_\d+)?\.mp4$`。宽松规则（「`.mp4` 结尾且不含 `.tmp`」）不够 —— 见 3.1，native 的 concat 残留和 JS 的素材落地副本都会漏过去。进程被杀时这些残留会变成「有视频无元数据」的幽灵卡片，而且每导一次新增一批。
3. 对每一项读同名 `.json`：
   - **读到且解析成功** → 完整卡片；
   - **读不到 / 解析失败** → 降级卡片：封面用同名 `.jpg`（有则用）、导出时间从文件名时间戳解析、**不可重剪**、可「保存到相册」、可删。
4. 排序：有元数据的按 `exportedAt` 倒序；无元数据的按文件名时间戳。两组混排时统一折算成一个排序键。

**整条链路不读 preferences、不扫相册、不要权限。** 这是相对今天最大的一处简化。

### 4.4 覆盖

点导出时判断「有没有同源作品」：

| 从哪进 | 判断依据 | 问什么 |
|---|---|---|
| 我的剪辑（有 `workId`） | 直接用 `workId` | 「这条作品已经导出过，要覆盖它吗？」 |
| 行程库（无 `workId`） | `tripTitle` + `tripStartTs` **软匹配**最近一条 | 「这趟行程已经导出过 N 条，要覆盖最近那一条吗？」 |
| 都没有 | — | 不问，直接导出 |

**这里的 `(tripTitle, tripStartTs)` 是软判断，不是身份校验。** 它只决定「问不问覆盖」，判断错了最坏是多问一次或少问一次，不会静默产出错素材 —— 与 4.5 的硬校验性质不同，因此可以接受，且与今天的行为一致。

选「覆盖」：合成到同一个 `<id>` → 替换 `exports/<id>.mp4` → 重抽 `<id>.jpg` → 重写 `<id>.json`（`createdAt` 保留，`exportedAt` 刷新）。
选「存成新的」：新 `<id>`，走完整新建流程。

**覆盖不再需要任何特殊路径** —— 没有对话框要跳过、没有媒体 URI 要 TRUNC、没有「按 albumUri 反查旧记录 id」。2026-10-18 设计稿 4.5 与 4.6 整节连同 L1/L2/L3 降级链一起作废。

### 4.5 还原与片段级校验

Editor 路由参数从 `recordId` 改为 `workId`（`entry/src/main/ets/pages/Editor.ets:144`）。

#### 判定

1. 从 sidecar 读 `tracks`；
2. 把 `tracks` 四条轨道里的文件名并成一个集合 `needed`；
3. 从现场扫描结果（`CoreBridge` 的行程库里每个 `DvrMeta.fileName`）取 `live`；
4. `needed - live` 为空 → 允许还原；否则 → 明确报错。

**粒度带来的正确结果**：T5 单视角的作品，`tracks` 里只有 front 一条轨道，用户删了一个 Left 片段完全不影响它 —— 今天会误拦，新方案不会。

**不依赖 `ffmpegPolicy`，也不需要重跑 `resolveTemplateTracks`** —— 记录的就是当初实际送进 native 的那四条轨道。

#### 素材装配

按 `tracks` 记录的顺序，**逐位**从现场重建四条轨道：

- 对每个文件名，在 `live` 里找到对应片段，取其当前 URI；
- front 轨的第 i 位、back 轨的第 i 位……按原顺序拼回去，**含重复项**；
- 由这四条轨道合成一份 `TripSnapshot`（`tripTitle` / `startTs` / `endTs` / `durationSec` 从 sidecar 取；`clips` 是这些片段的并集；`timeline` / `previewUri` / `previewCamera` 从并集里挑，与 `CoreBridge.createLibraryState` 造行程的方式一致）。

#### 接进现有还原链

今天的入口是 `CoreBridge.restoreEditorState(tripId, recordJson)`（`CoreBridge.ets:827`），第一件事就是 `this.trips.get(tripId)`，拿不到就退回白纸；随后 `applyRestoredState`（`:860`）用 `live.durationSec` 建时间轴、算 `isRawFull`。

新方案下素材是**跨行程、跨机位拼出来的**，现场没有对应的 `TripSnapshot`。所以：

- `CoreBridge` 增加一个直接接收**装配好的 `TripSnapshot`** 的入口（内部复用同一套 `restoreEditorStateFromSnapshot` + `applyRestoredState`），不再走 `trips.get`；
- 合成快照**不注册进 `this.trips`** —— 它是还原的临时产物，混进行程库会污染首页列表。

`durationSec` 必须取自 sidecar 而不是从片段重新累加：`applyRestoredState` 里 `segmentSourceDurationSec = live.durationSec`，而 `buildEditorState` 有一条「`segmentSourceDurationSec !== tripDurationSec` → 整段重置」的兜底（`CoreBridge.ets:852-856` 的注释就是在说这件事）。算错会把用户的分段整个冲掉。

#### 缺片段时的出口

三态，**必须区分**：

| 状态 | 条件 | 文案与出口 |
|---|---|---|
| **未授权** | 没有 `READ_IMAGEVIDEO`，`CoreBridge.trips` 为空 | 「需要相册权限才能重新剪辑」+ 授权入口。**绝不判成「素材已不在」** |
| **素材已不在** | 有权限，但 `needed - live` 非空 | 「原始行程素材已不在，这次剪辑无法还原」，列出缺了哪几个机位、共几个片段；出口：「当作新剪辑打开」/「返回」 |
| **可还原** | 有权限，差集为空 | 正常进入 |

第三态与第二态的区分是关键：「我的剪辑」列表现在**不需要权限**就能看，用户很可能在没授权的情况下点进来。若不区分，每一条作品都会弹出「素材已不在」，而那句话是假的 —— 本次改动最大的一个用户可感知收益会被一个误导性弹窗吃掉。这与今天孤儿检测的三态（`ok` / `missing` / `unknown`，`HomeViewModel.ets:494`）是同一个模式。

#### 顺带修掉的老问题

**合并行程（`trip-merged-*`）今天重启即失**（2026-10-18 设计稿 4.4 风险 4），因为那个 id 不在扫描结果里。新方案按片段文件名反查，只要源片段还在，合并作品就能还原。

### 4.6 保存到相册

**显式动作**，不是导出的副产品。

- 入口：作品卡片上的按钮（以及 4.9 的导出成功提示里可以再给一个）。
- 实现：复用今天 `saveVideoToAlbum`（`ExportManager.ets:294`）的主体 —— `showAssetsCreationDialog` → 拷字节 → 完成 toast。走免权限路径，因此**必然有一次系统对话框**，但它是用户主动触发的，可以接受。
- **不记录相册 URI。** 既然 App 不再管理相册那份，URI 存下来也没有用途（今天存它只为了覆盖时反查和 ▶）。
- 相册那份之后与 App 无关：不覆盖、不删除、不感知。

### 4.7 封面

**在导出主流程里生成**，不是列表异步补。

今天没有现成的入口可用：`extractFirstFrameByService`（`entry/src/main/ets/service/ExportNativeService.ets:129`）的输出路径被 `resolveThumbnailCachePath` 写死成 `${cacheDir}/thumb_v3_<key>.jpg`（`:100`），而且命中 `isUsableThumbnail` 就**直接返回旧文件**（`:144`）—— 覆盖时根本不会重抽。今天 `HomeViewModel` 正是靠把 `exportedAt` 拼进 cacheKey 绕开这一点（`HomeViewModel.ets:410`）。

**做法**：把 `extractFirstFrameByService` 拆成两层 ——

- 内层「抽首帧写到指定路径」（`AVImageGenerator` 那段逻辑原样复用）；
- 外层「带缓存的缩略图」保持今天的行为不变（行程库封面还在用它）。

导出流程调内层，写到 `exports/<id>.jpg`；覆盖时重抽（内容换了）。

源是本地沙盒文件，比今天的媒体 URI 更快、不需要权限。抽取失败**不阻断导出** —— 没有 jpg 就是卡片回落到行程库封面或占位图。

这一条删掉今天的整套异步补封面机制：`resolveMyEditsCovers`（`HomeViewModel.ets:392`）的并发池、token 失效、`updateCoverPath` 写回、`isCoverUsable` 的 `fs.accessSync` 存在性探测（`:373`，那段代码存在只是因为 `cacheDir` 会被系统清理 —— 现在封面在 `filesDir`，不会被清）。

### 4.8 剩余空间

成片主存进 App 空间后，App 得自己管磁盘。

- 导出前用 `@ohos.file.statvfs` 的 `getFreeSize(cacheDir)` 查一次；
- 阈值要覆盖**峰值**而不是成品大小：合成期间同时存在 native 的轨道 concat 副本（每条轨道一份，合计接近源素材总和）、JS 侧落地的源素材副本（3.1 里那批 `input_<ts>_<n>.mp4`）、以及成品本身；
- 低于阈值 → 明确报错「存储空间不足，无法导出」，**不自动清理**（反目标 1）；
- 阈值估算公式留给实现者（第 7 节）；`statvfs` 在沙盒路径上的行为需真机确认（风险 3）。

### 4.9 导出后引导

- 导出成功的 toast 从「已保存到相册」改成带动作的形式：**「已保存 · 查看作品」**；
- 点击 → 回到首页并切到「我的剪辑」Tab；
- 机制建议用**模块级的 pending 标记**，不用 router 参数：项目已有先例（`Editor.ets:200` 的 `requestPreviewSeek` 就是这个模式），且不依赖 `router.back()` 携带参数的行为。
- 首页 `onPageShow`（`entry/src/main/ets/pages/Index.ets:98`）目前只在 `activeTab === 1` 时刷新；需要加一条「消费 pending 切 Tab」的分支。

**json 写失败时算成功还是失败**：**报成功，加一句降级提示**。mp4 已经落盘、它就是作品本体，此时报「导出失败」是撒谎；反目标 1 也不允许把它删掉。表现是列表里立刻多出一张降级卡片（可看、可存相册、不可重剪），提示文案沿用今天 `isRecordsDurable()` 那句告警的模式（`Editor.ets:697`）。

### 4.10 旧数据处置

- `pref_edit_records`（`PreferencesService.ets:11`）**停止读写**；
- **暂不删除**。清除是不可逆的，而这份数据只有几百 KB 量级；等新版稳定后再单独清一次。
- 旧作品不再出现在「我的剪辑」里。它们的成片仍在系统相册，用户自己去图库找。
- 空态文案沿用今天的「还没有剪辑过的视频」，不额外解释历史。

### 4.11 界面

- 卡片视觉沿用 2026-10-18 设计稿 4.12 的大封面卡，展示层不变；
- 卡片按钮从单个「重新剪辑」增加为：「重新剪辑」+「保存到相册」；
- ▶ 的处理见 4.6 的风险（风险 1）：本地沙盒文件能不能交给系统播放器需真机验证，读不到就去掉 ▶；
- 降级卡片（有视频无元数据）的样式留给实现者。

---

## 5. 与现有实现的取舍

### 5.1 删掉

| 位置 | 内容 |
|---|---|
| `entry/src/main/ets/model/EditRecord.ets` | 整表解析/容错/CRUD/排序/容量淘汰 —— `normalizeRecord` / `parseEditRecords` / `serializeEditRecords` / `sortRecordsNewestFirst` / `findRecordById` / `recordsForTrip` / `findLatestRecordForTrip` / `upsertRecord` / `removeRecords` / `limitRecords` / `fitRecordsUnderBytes` / `MAX_EDIT_RECORDS` / `MAX_EDIT_RECORDS_BYTES` / `recordMatchesTrip` / `makeRecordId`。约 200 行，只留展示格式化函数 |
| `entry/src/main/ets/service/EditHistoryService.ets` | 整个读改写串行化队列（118 行） |
| `HomeViewModel.ets:454-516` | `resolveMyEditsOrphans` + `probeAlbumUri` —— 孤儿检测、权限感知、201/13900012 特判、unknown/orphan 两态 |
| `HomeViewModel.ets:373-446` | `isCoverUsable` 的存在性探测 + `resolveMyEditsCovers` 的并发池 / token / 写回 |
| `ExportManager.ets:294-389` | `saveVideoToAlbum` 的对话框分支、覆盖/新建两态、`TRUNC` —— 主体挪去 4.6，导出主流程不再经过 |
| `ExportManager.ets:399-446` | `persistRecord` 里「按 `albumUri` 反查旧记录 id」与 preferences 落盘 |
| `Models.ets:529` | `snapshotMatchesTrip` 的行程级判定 |
| `CoreBridge.ets:827-858` | `restoreEditorState` 里 `trips.get` + `snapshotMatchesTrip` 两道关卡 |
| `Editor.ets:163-192` | `resolveRestore` 里依赖 `resolveTripIdByTitleStartTs` + `snapshotMatchesTrip` 的漂移判定 |
| 2026-10-18 设计稿 4.6 | 整节 L1/L2/L3 降级链与受控权限申请 |

### 5.2 新增

- sidecar 读写与容错（薄）
- **`ClipSegment` 加 `fileName` 字段**（3.3 的前提修正；`tripFromSnapshot` 与 `snapshotToLegacyClips` 各改一行）
- 导出时把四条轨道反查成文件名集合（薄 —— 轨道已经选好了，只是把 URI 映射回名字）
- 片段级差集判定（薄）
- **按记录顺序逐位重建四条轨道 + 合成 `TripSnapshot`**（本次唯一一处实质新增逻辑）
- `CoreBridge` 增加接收现成 `TripSnapshot` 的还原入口（薄）
- 抽首帧拆成「抽到指定路径」+「带缓存的缩略图」两层（薄）
- 导出前剩余空间检查（薄）
- 「保存到相册」按钮（主体复用今天的 `saveVideoToAlbum`）
- 导出后跳转引导（薄）

### 5.3 明确没有变简单的

- **还原时仍然要现场扫描源素材**。那是剪辑页的地基，与本次改动无关。
- **用户删了 DVR 源文件仍然还原不了**。只是判定变准了、不再静默出错。
- **ffmpeg 合成那一层完全不动。**
- **`READ_IMAGEVIDEO` 仍然需要** —— 行程库要扫描 DVR 源素材，还原也要靠它。本次不减少这个权限依赖；收益是「我的剪辑」**列表**不再依赖它（但要还原仍需授权，见 4.5 的三态）。

---

## 6. 风险与未知

1. **沙盒文件的 ▶ 能不能交给系统播放器（最高优先级，需真机）。** 今天 ▶ 打开的是相册媒体 URI（`HomeViewModel.ets:604`），带 `FLAG_AUTH_READ_URI_PERMISSION`。新形状下作品在沙盒里，隐式 Want 能不能读到沙盒路径未知。**失败则按 2026-10-18 设计稿 4.10 的退路：直接去掉 ▶**，卡片上只留「重新剪辑」+「保存到相册」。
2. **`fs.rename` 是否覆盖已存在文件，以及能否跨 `cacheDir` / `filesDir` 移动。** 这是原子替换与成品搬运的前提。不确定就用 `unlink` + `rename`（中间窗口极短，`.tmp` 已完整）。
3. **`statvfs.getFreeSize` 在沙盒路径上的行为**，以及 App 私有空间有没有配额上限。需真机确认。
4. **用户看不见沙盒里的作品。** 没点过「保存到相册」的话，卸载即全丢。空态与首次导出的引导要照顾这点 —— 这是本方案最主要的用户可感知代价，需要在文案上如实说明。
5. **逐位重建轨道时，同一个文件名在现场出现多次怎么办。** DVR 文件名理论上唯一，但用户可能复制过文件。需要一个确定的取舍规则（取第一个 / 报错），留给实现者（第 7 节）。
6. **`DvrMeta.fileName` 的一致性。** 判定完全依赖它。`DvrScannerService.parseDvrFileName`（`entry/src/main/ets/service/DvrScannerService.ets:68`）有 native 与 JS 两条解析路径，必须确认两条产出的文件名一致、且与导出时记进 `ClipSegment.fileName` 的一致。**猜错的后果是致命的：所有作品一律判「素材已不在」，整个还原链路全废。**
7. **`entry/src/main/module.json5` 里 `READ_MEDIA` / `WRITE_MEDIA` 自 API 22 起已废弃**，与本次无关但值得顺手清理。

---

## 7. 开发者自主决定的范围 (Left to the Builder)

1. `WorkMeta` 的序列化/反序列化与容错策略（坏 JSON 怎么降级）。
2. 原子写的具体实现，含 `rename` 覆盖与跨目录的兜底。
3. 剩余空间的阈值估算公式。
4. 导出后引导的 UI 形态（带动作的 toast / 横条 / 对话框）。
5. 降级卡片（有视频无元数据）的具体样式与文案。
6. 覆盖询问、删除确认、权限三态三套文案的措辞。
7. 首帧抽取失败的回落策略。
8. 逐位重建轨道时文件名重复的取舍规则。
9. 作品 id 撞名（同秒两次导出）时的后缀规则。
