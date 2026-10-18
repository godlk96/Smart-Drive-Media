# 剪单「我的剪辑」：导出历史与现场还原设计

- **日期**：2026-10-18
- **状态**：待评审 (Draft rev.2 —— 已并入 builder-check 复核意见)
- **文档路径**：`docs/superpowers/specs/2026-10-18-my-edits-history-design.md`

---

## 1. 目标与背景 (Intent & The Why)

### 1.1 现状与痛点

`Smart-Drive-Media`（剪单）今天的导出是一条**单向路**：

1. 用户在剪辑页点导出 → `ExportManager.run()`（`entry/src/main/ets/service/ExportManager.ets:156`）合成 mp4；
2. `saveVideoToAlbum()`（`entry/src/main/ets/service/ExportManager.ets:250`）弹系统「保存到相册」，用户选位置，App 把字节拷进相册的**新条目**；
3. 事件文本更新为 `相册保存成功：${albumUri}`（`entry/src/main/ets/service/ExportManager.ets:213`），剪辑页只把 `exportStatusText` 从「待导出」改掉，**不弹任何提示**。

结果：

- 导完没有任何「保存成功」的确认，用户不确定到底存没存进去；
- 导出历史**完全没有落盘** —— `PreferencesService`（`entry/src/main/ets/service/PreferencesService.ets`）今天只有两个 key：`pref_last_trip_id`、`pref_template_id`；
- 想回头改一版，只能回「行程库」重新挑行程，**从一张白纸重剪**：`CoreBridge.createEditorState`（`entry/src/main/ets/bridge/CoreBridge.ets:783`）每次都重置为 `DEFAULT_TEMPLATE_ID`（T5）、整条未剪（`isRawFull = true`）、水印开。

### 1.2 核心目标

把「导出」从终点变成**作品**：每次导出成功留一条记录，记住成片在相册的位置**和**导出那一刻的整套参数；用户从「我的剪辑」点进去，剪辑页按参数**现场还原**，改完再导出可以覆盖同一件作品。

用户原话 (m00001)："导出保存成功之后 提示保存成功。新增一个 我剪辑的视频的功能，可以查看我历史剪辑过的视频，并且支持按照参数 跳转到剪辑页。主要想想以什么方式展现出来。"

---

## 2. 目标、非目标与反目标

### 2.1 目标 (Goals)

1. **导出成功有明确回执**：弹 toast「已保存到相册」。
2. **首页顶部双 Tab**：「行程库 / 我的剪辑」。
3. **作品列表**：大封面卡 —— 成片首帧 + 行程日期 + 模板名 + 段数 · 时长 + 导出时间。
4. **现场还原**：点卡片进剪辑页，模板 / 分段 / 水印 / 播放头全套回到导出那一刻。
5. **覆盖语义**：该行程已有作品时，点导出先问「要覆盖那一条吗？」；选覆盖则列表更新同一条，相册里也**不出现第二份**。
6. **看成片**：缩略图上的 ▶ 交给系统播放器播放。
7. **空态**：一条都没有时给一句说明 + 「去行程库」按钮。

### 2.2 非目标 (Non-Goals)

- **不做应用内播放器**（用户 m00133 选「跳到相册看」）。App 里唯一的 AVPlayer 是剪辑页内的多轨同步预览器 `entry/src/main/ets/media/SingleTrackController.ets`，不为列表复用。
- 不做云同步、不做跨设备。
- 本期不做作品改名、排序、分享。

### 2.3 反目标 (Anti-Goals —— 做了就算失败)

- **绝不记录未导出的中间态**。用户改了参数但没导出，退出后什么都不留 (m00006)。
- **绝不在「覆盖」时把两份成片留在相册里**（用户 m00116 要「原来的物理删除」）。
- **绝不静默用错素材**。行程身份对不上时宁可明确报错，也不能拿另一趟行程的录像还原用户的剪辑。
- **绝不自动删除用户的记录**。孤儿记录只降级显示，清理权在用户手里。

---

## 3. 核心设计

### 3.1 一句话模型

> **一条记录 = 一次导出 = 一件作品。** 记录里同时握着「成片在哪」和「怎么剪的」。

### 3.2 两层数据是隔离的（重要前提）

| 层 | 内容 | 谁说了算 | 能否物理删除 |
|---|---|---|---|
| **记录层** | `pref_edit_records` 里的 `EditRecord` | App 自己 | **能，100% 可控** |
| **成片层** | 相册里那条 mp4（`albumUri`） | 系统媒体库 | 受受控权限限制，见 4.6 |

「我的剪辑」列表渲染的是**记录层**；用户点 ▶ 打开的是**成片层**。这两层必须分开谈 —— 删掉一条记录永远做得到，**真正难的是把相册里那份成片也弄干净**。

### 3.3 三条链路

```
【导出】剪辑页 ──点导出──▶ 该行程有记录? ──有──▶ 问「覆盖那一条 / 存成新的」
                                │                        │
                                └──无──▶ 直接导出 ◀──────┘
                                          │
                                          ▼
                        合成 ──▶ 写相册（覆盖则跳过保存对话框）
                                          │
                                          ▼
                        落盘记录 ──▶ toast「已保存到相册」

【还原】我的剪辑 ──点卡片──▶ params{ tripId, recordId }
                                │
                                ├─▶ 参数：取 record.snapshot（权威）
                                └─▶ 素材：用 tripId + (title,startTs) 现场解析
                                          └─ 对不上 ──▶ 明确报错，不静默用错

【新建】行程库 ──点行程──▶ params{ tripId }
                                │
                                └─▶ createEditorState(tripId,'','')  ← 现有默认白纸
```

### 3.4 界面结构

首页 `entry/src/main/ets/pages/Index.ets` 内部加一个 Tab 状态，**不新增路由页**（`entry/src/main/resources/base/profile/main_pages.json` 保持 `["pages/Index","pages/Editor"]`）：

- 页头标题随 Tab 变（「行程库」/「我的剪辑」）；
- Tab 栏在标题下方，选中态用 `#D98324` 下划线；
- 「行程库」栏页头右侧保留现在的「合并剪辑 / 多选」；
- 「我的剪辑」栏页头右侧为「选择」（多选删除）。

---

## 4. 详细设计

### 4.1 数据契约

```typescript
export class EditRecord {
  id: string = ''            // `rec_<epochMs>_<rand>`
  tripId: string = ''        // 仅作线索，不作为身份依据（见 4.4）
  tripTitle: string = ''     // 「10月1日 周三」
  tripStartTs: number = 0    // 身份校验用（见 4.4）
  tripEndTs: number = 0
  albumUri: string = ''      // 相册成片 URI
  fileName: string = ''      // SmartDrive_Export_YYYYMMDD_HHMMSS.mp4
  exportedAt: number = 0     // 毫秒时间戳
  durationMs: number = 0
  segmentCount: number = 0
  templateId: string = ''    // T1..T6
  snapshot: string = ''      // ExportSnapshot 深拷贝的 JSON
  coverPath: string = ''     // 首帧缩略图缓存路径
  schemaVersion: number = 1
}
```

`snapshot` 直接复用已有的 `ExportSnapshot { sessionId, createdAt, trip, selectedTemplateId, playback, brand }`（`entry/src/main/ets/model/Models.ets`）与 `deepCloneExportSnapshot(state)`；`EditorViewModel.buildExportSnapshot`（`entry/src/main/ets/viewmodel/EditorViewModel.ets:113`）已经在产出这个对象，不需要新造状态容器。

### 4.2 持久化

`PreferencesService` 新增第三个 key：

- `KEY_EDIT_RECORDS = 'pref_edit_records'` —— 整个有序列表序列化成一个 JSON 数组字符串，**一个 key 存全部**。

依据：API 26 的 `preferences.MAX_VALUE_LENGTH = 16MB`（`@ohos.data.preferences.d.ts:80`），200 条约 60–100KB，占用 <1%。不上 `relationalStore`，因为本期只需要「整表读、整表写」，没有按字段查询的需求。

**必须注意**：`PreferencesService.ets:25-35` 今天在 preferences 打不开时会**静默回退到内存 Map**。对这份数据这是丢数据，必须改成显式错误上报，由 UI 提示「历史记录暂时不可用」。

### 4.3 还原入口

`entry/src/main/ets/pages/Editor.ets:124` 的 `params` 增加一个 `recordId`：

- `recordId` 非空 → 从记录还原；
- `recordId` 空、`tripId` 非空 → 现有白纸路径；
- 都空 → `trip-demo-1`（现状不变）。

`HomeViewModel` 新增 `openEditorFromRecordRoute(record)` → `{ url: PAGE_ROUTE_EDITOR, params: { tripId: record.tripId, recordId: record.id } }`，与现有 `openEditorRoute(card)` 并列。

### 4.4 还原的权威来源：参数以记录为准，素材以现场为准

「按参数跳回剪辑页」这句话里，**参数是记录的责任，素材是现场的责任** —— 两者可能对不上，必须分开处理。

**记录里存得下的**：`ExportSnapshot.trip` 是一个 `Trip`（`entry/src/main/ets/model/Models.ets:352-368`：`tripId` / `title` / `rangeText` / `durationSec` / `tracks` / `startTs` / `endTs`），**没有**预览与时间轴字段。

**剪辑页真正需要的**：`TripSnapshot`（`entry/src/main/ets/model/TripModels.ets:14-29`：`id` / `title` / `subtitle` / `durationSec` / `segmentCount` / `tripTitle` / `tripRange` / `previewUri` / `previewFrameUri` / `previewCamera` / `clips` / `timeline` / `startTs` / `endTs`），它只活在 `CoreBridge.trips` 里，由 `createLibraryState()` 从华为分享的扫描结果填充（`entry/src/main/ets/bridge/CoreBridge.ets:590-613`）。

所以还原是**两路合成**：

| 来源 | 提供 | 权威性 |
|---|---|---|
| `record.snapshot` | 模板、分段、水印、播放头 | **权威** —— 用户改的就是这些 |
| 现场扫描到的 `TripSnapshot` | 视频素材、时间轴、预览帧 | **尽力** —— 素材没了就还原不了 |

**身份漂移是真问题**：`tripId` 的构造是 `trip-${title}-${startTime}-${index}`（`entry/src/main/ets/bridge/CoreBridge.ets:493`），其中 `index` 是该分组在**整次扫描**里的序号。用户删掉靠前的源素材，后面的行程会整体重新编号 —— 一个存下来的 `tripId` 会**静默指向另一趟行程**，还原出错素材。另外合并剪辑的 `trip-merged-*`（`entry/src/main/ets/bridge/CoreBridge.ets:545` 与 `:559`）只存在于内存，重启即失。

因此：

1. **不信任 `tripId` 本身**。还原时用记录里的 `(tripTitle, tripStartTs)` 与现场行程交叉验证；对不上就判定**身份漂移**。
2. 漂移或找不到 → **明确告诉用户**「原始行程素材已不在，这次剪辑无法还原」，给两个出口：「当作新剪辑打开」（走默认白板）或「返回」。
3. **绝不静默用错素材**（反目标 3）。
4. 合并剪辑的作品在重启后必然落到第 2 条（`trip-merged-*` 不在扫描结果里），文案要能说清是这种情况。

### 4.5 覆盖：询问时机与实现路径

**时机修正（重要）**：询问必须发生在**点导出之后、合成开始之前**，不能等导出成功。

原因：现在的 `saveVideoToAlbum`（`entry/src/main/ets/service/ExportManager.ets:250`）一上来就调 `showAssetsCreationDialog`，等成功事件到达时相册里**新条目已经建好了**（`entry/src/main/ets/service/ExportManager.ets:205-213`）。那时再问「要不要覆盖」，用户选覆盖也无从下手 —— 旧的要删（没权限），新的要删（也没权限），结果必然违反反目标 2。用户原话 (m00113) 是「导出的时候问」，前移到点导出也更贴他的说法。

**规则（统一，不分入口）**：点导出时，若该行程**已有记录**，就问一句：

| 从哪进 | 问什么 |
|---|---|
| 我的剪辑（有 `recordId`） | 「要覆盖**这一条**吗？」 |
| 行程库（无 `recordId`） | 「这趟之前导出过 **N** 条，要覆盖**最近那一条**吗？」 |
| 该行程没有记录 | 不问，直接导出 |

两个按钮：**覆盖那一条** / **存成新的**。

**选「覆盖」时导出流程的变化**：

1. **不调** `showAssetsCreationDialog` —— 目标 URI 用旧记录的 `albumUri`；
2. `fs.open(oldAlbumUri, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC)` 后写新字节（见 4.6）；
3. 成功后**更新**那一条记录（`id` 不变），而不是追加。

**选「存成新的」**：完全走现有流程（弹相册保存对话框、建新条目），追加一条记录。

**接口变化**：

- `ExportManager.run()`（`entry/src/main/ets/service/ExportManager.ets:156`）需要一个可选入参 `overwriteTargetUri?: string`；为 `undefined` 时行为与今天完全一致；
- `saveVideoToAlbum`（`entry/src/main/ets/service/ExportManager.ets:250`）需要接受这个目标 URI 并跳过对话框。

**记录落盘的位置**：由**导出流程**在相册写入成功后立即落盘，**不是**等页面收到事件再写。两个理由：

- 页面拿 `albumUri` 很脆 —— `startNativeExport` 在**第一个**终结事件上就 resolve（`entry/src/main/ets/NativeExportManager.ets:32-37`），而 `ExportManager` 是先发 `导出完成：${fileName}`（`entry/src/main/ets/service/ExportManager.ets:212`）再发 `相册保存成功：${albumUri}`（`:213`），页面得靠解析事件文本才能拿到它；
- 若由页面写，两步之间被杀/返回会留下「相册有视频、列表没记录」的空档。放在流程内可以顺手消除。

### 4.6 相册成片的覆盖 —— 就地覆写 L1（已定）

用户要求 (m00116)「原来的物理删除」。**已裁决 (m00173)：走 L1 就地覆写。**

先说清楚「物理删除」为什么在成片层做不到。API 26 的现实是：

- `photoAccessHelper.MediaAssetChangeRequest.deleteAssets(context, uriList)`（`@ohos.file.photoAccessHelper.d.ts:4886`）带 `@permission ohos.permission.WRITE_IMAGEVIDEO`；
- `WRITE_IMAGEVIDEO` 是**受控权限**（`availableLevel: "system_basic"`），本应用签名 profile 的 ACL 目前**只授了 `ohos.permission.READ_IMAGEVIDEO`**；
- 因此直接调 `deleteAssets` 会以 **201 Permission denied** 失败；
- 即便拿到权限，删除也只是进**回收站**（30 天，用户可还原），不是硬删；
- `@ohos.multimedia.mediaLibrary` 在 API 26 SDK 里**整个不存在**，`MediaLibrary.deleteAsset` 这条路已经没了。

因此采用**就地覆写（L1）**，不删条目：

> **覆盖 = 重新打开上次那条 `albumUri`，`TRUNC` 后写进新字节。** 相册里的条目数量、位置、ID 全都不变，只有内容换成新成片。

好处：不需要任何新权限，不弹系统授权框，不依赖 AGC 白名单，也不会把文件丢进回收站。用户的观感正是他要的 —— 「旧的不在了，新的在同一个地方」。

代价（可接受）：

- 条目名保留旧的（`SmartDrive_Export_<旧时间戳>.mp4`）—— 文件名对用户不可见，且 4.1 的 `fileName` 字段记的是真实新名字；
- 需真机验证「跨会话能否再写上次的 media URI」（见第 6 节风险 1）。

**降级顺序（L1 验证失败才用）**：

| 级别 | 做法 | 代价 |
|---|---|---|
| **L1 就地覆写（已定）** | 见上 | 无新权限；条目名保留旧的 |
| **L2 申请受控权限后删除** | `module.json5` 声明 `ohos.permission.WRITE_IMAGEVIDEO`，走系统授权弹窗，再 `deleteAssets` 删旧条目 + 新建 | 多一次系统授权弹窗；**release 需向 AGC 申请受控权限白名单**（可能被拒）；删除只是进回收站 30 天 |
| **L3 只覆盖记录** | 记录指向新成片，旧成片留在相册由用户自己删 | 相册里会堆版本 |

**实现要求（本设计里最容易踩的坑）**：`ExportManager.saveVideoToAlbum`（`entry/src/main/ets/service/ExportManager.ets:250`）现在用 `fs.open(albumUri, fs.OpenMode.READ_WRITE)`（`entry/src/main/ets/service/ExportManager.ets:291`）—— **没有 TRUNC**。就地覆写必须自己补 `fs.OpenMode.TRUNC`，否则新成片比旧的短时，文件尾部会残留旧字节，产物直接损坏。

### 4.7 删除记录

**L1 帮不上忙** —— 覆写是「换内容」，删除没有新内容可写，降级链在删除上直接退化到 L2/L3。

因此「我的剪辑」里的删除**只删记录层**：记录从列表移除，**相册里那份成片留着不动**。

- 删除确认弹窗必须把这句话说清楚：「只会从列表移除，相册里的视频不会被删掉」，不能让用户以为视频也没了；
- 要连相册文件一起删，只有 L2 那条受控权限的路（见 4.6），本期不做。

### 4.8 缩略图

复用已有能力，**不新增取帧代码**：`extractFirstFrameByService(sourceUri, cacheDir, cacheKey)`（`entry/src/main/ets/service/ExportNativeService.ets:101`）—— AVImageGenerator 取首帧 → JPEG → 落盘到 `resolveThumbnailCachePath(cacheDir, cacheKey)`（`entry/src/main/ets/service/ExportNativeService.ets:72`），任何失败返回 `''`。

- `cacheKey` 用 `record.id`；
- 路径写回 `record.coverPath`；
- 取不到时回落到该行程在「行程库」里的封面；
- 卡片渲染永远不等缩略图（先占位，异步替换）。

### 4.9 导出成功的 toast

复用剪辑页已有的 toast 机制：`showToast(message)` 在 `entry/src/main/ets/pages/Editor.ets:249-259`（字段 `toastText` / `toastVisible` / `toastTimer`，2000ms 自动隐藏）。今天只有取消会弹（`entry/src/main/ets/pages/Editor.ets:595` 与 `:609` 都是 `'已取消导出'`）。

新增：导出成功且相册写入完成后 → `showToast('已保存到相册')`。

### 4.10 点 ▶ 看成片（best-effort，需真机验收）

用户选 (m00133)「跳到相册看」。用隐式 Want 把成片交给系统播放器：

```typescript
const want: Want = {
  action: 'ohos.want.action.viewData',
  uri: record.albumUri,
  type: 'video/mp4',
  flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
}
await context.startAbility(want)
```

要点：

- action 必须写**字面量** `'ohos.want.action.viewData'` —— stage model 的 `@ohos.app.ability.wantConstant.d.ts` 里**没有** `ACTION_VIEW_DATA` 常量（那个只存在于 FA 模型的 `@ohos.ability.wantConstant.d.ts:195`）。
- `FLAG_AUTH_READ_URI_PERMISSION = 0x00000001`（`@ohos.app.ability.wantConstant.d.ts:318`）是唯一的 URI 授权机制 —— **`grantUriPermission` 在整个 API 26 SDK 里不存在**。
- **不要硬编图库的 bundleName / abilityName**（非公开 API，随版本变）。
- 项目里**没有任何 `startAbility` / Want 先例**，这是第一次用。

**验收标准**：真机上点 ▶ → 系统拉起一个能播放 `video/mp4` 的应用并播放该成片。若系统无匹配 ability（抛 **16000019 No matching ability is found**，`application/UIAbilityContext.d.ts:291`）→ catch 后 toast「没有找到能播放这条视频的应用」。

**若真机验收失败（已裁决 m00216）**：**直接去掉 ▶**，不补 App 内播放。卡片上只剩「重新剪辑」，封面不再带播放按钮。

**文案边界**：系统**没有**「打开相册并定位到某一条」的公开 API。这里做的是「让系统播放器播放这条 URI」，**不是**「打开相册 App 的那一格」，文案上别承诺后者。

### 4.11 孤儿记录：只降级，绝不自动清理

记录里存的是**指针**，不是视频副本 —— App 不留自己那份 mp4。用户在系统相册把成片删掉，记录就会悬空。

**处置：只降级显示，绝不自动清理。** 自动清理等于静默删除用户的历史（违反反目标 4）。

- 孤儿卡片：封面置灰 + 一行「相册里的视频已被删除」；
- 「重新剪辑」**保留可用**（素材还在的话照样能重剪）；
- ▶ **置灰禁用**（点了必然失败）；
- 用户可以在「选择」模式里自己删掉这条记录。

**检测必须权限感知**：孤儿判定依赖打开 `albumUri`，这需要 `ohos.permission.READ_IMAGEVIDEO`。若该权限未授予，**所有记录都会看起来像孤儿** —— 因此：

1. 检测前先确认读权限；无权限则一律标记为「**未知**」，**不判孤儿**、不改任何记录；
2. 只有明确的「权限已授予 且 URI 打不开」才判孤儿；
3. 任何情况下检测都不写盘。

### 4.12 视觉规格

沿用现有调色板（`entry/src/main/resources/base/element/color.json`）：背景 `ed_bg #F3F1EC`、卡片 `card_bg #FFFFFF`、分隔 `ed_line #E6E0D3`、强调 `amber #D98324`、强调浅底 `amber_soft #FDF6EC`、强调描边 `chip_amber_border #F0DEC5`、主文字 `text_primary #1C1B18`、次文字 `text_secondary #57534A`、三级文字 `text_tertiary #8A867D`、画面底 `stage_bg #14120F`。

卡片（用户 m00123 选定的「大封面卡」）：

```
┌──────────────────────────┐
│     成片首帧 16:9     ▶  │
├──────────────────────────┤
│ 10月1日 周三 · 单视角     │
│ 2 段 · 00:32             │
│ 10月18日 21:04 导出       │
│ [ 重新剪辑 ]              │
└──────────────────────────┘
```

- 白底、`1px ed_line` 描边、10px 圆角；
- 顶部 16:9 成片首帧，右下角一个半透明白圆 ▶；
- 下方三行：`10月1日 周三 · 单视角`（粗）、`2 段 · 00:32`、`10月18日 21:04 导出`；
- 再一行「重新剪辑」胶囊按钮（`amber_soft` 底 + `chip_amber_border` 边 + 琥珀色字）。

**卡片上的分工**：点卡片主体 = 重新剪辑（进还原），点封面右下角的 ▶ = 看成片。

空态：一句「还没有剪辑过的视频」+ 说明 + 一个黑底「去行程库」按钮，点了切 Tab。

---

## 5. 评审问题裁决与工程收敛

### 5.1 已确认为工程默认决策 (Our Call)

1. **同一行程攒了多条记录时**，覆盖的目标是「**最近的那一条**」。
2. **从「我的剪辑」还原进去重剪**，默认就是要覆盖原来那条 —— 但**仍然弹一次确认**（用户 m00113 的原话是「导出的时候问」，所以不静默覆盖）。
3. **缩略图**用相册里成片的真实首帧，取不到回落到行程封面。
4. **Tab 不新增路由页**，在 `entry/src/main/ets/pages/Index.ets` 内部切换。
5. **列表不播放**，点 ▶ 走系统播放器（用户 m00133）。

### 5.2 已裁决的用户决策 (Resolved)

- **「物理删除」的降级链（4.6）** —— 用户裁决 (m00173)：*「实在不行就先试就地覆写」* → **采用 L1 就地覆写**。用户同时澄清了本设计的关键前提 (m00173)：*「这个是 APP 产生的记录，和相册互相有隔离的」* —— 即 3.2 的两层模型，记录层 App 完全自主，成片层才受系统权限约束。
- **▶ 的退路（4.10）** —— 用户裁决 (m00216)：先做 best-effort；**真机拉不起来就直接删掉 ▶**，不在 App 内补播放页。
- **设计稿整体批准 (m00216)** —— 进入实施计划阶段。

### 5.3 builder-check 复核意见的处置

| # | 复核提出的问题 | 处置 |
|---|---|---|
| Q1 | 「要覆盖吗」问在导出成功之后，那时相册新条目已建好，必然留下两份 | **采纳，已修正** —— 询问前移到**点导出时**，并把目标 URI 穿进导出任务跳过保存对话框（4.5）。同时采纳「记录由导出流程落盘」以消除页面拿不到 `albumUri` 与中间被杀的空档 |
| Q2 | 4.4 说行程库不弹窗，5.1 又说要问「最近那一条」，两条规则互斥 | **采纳，已修正** —— 统一为「只要该行程已有记录就问」，两个入口共用一套规则，只是问法不同（4.5） |
| Q3 | 还原时快照与现场扫描谁是权威；tripId 会因重编号指向别的行程；合并行程重启即失 | **采纳，已修正** —— 新增 4.4：参数以记录为权威、素材以现场为尽力，并用 `(tripTitle, tripStartTs)` 做身份校验，漂移即明确报错 |
| Q4 | 删除记录时 L1 无意义，降级链退化 | **采纳，已修正** —— 新增 4.7：删除只删记录层，弹窗明确告知相册视频不会删 |
| Q5 | 孤儿记录是降级还是自动清理，检测是否权限感知 | **采纳，已修正** —— 新增 4.11：只降级、绝不自动清理；检测权限感知，无权限一律判「未知」 |
| Q6 | ▶ 无法深链到具体视频，验收标准是什么 | **采纳，已修正** —— 4.10 写明验收标准、16000019 降级、以及失败时的两条退路 |

---

## 6. 风险与未知

1. **L1 未验证（最高优先级）**：跨会话对上次 `albumUri` 的写权限是否还在，以及媒体库会不会重新索引被覆写的内容 —— 需真机验证。这是整个覆盖方案的地基。
2. **L2 未验证**：debug 自动签名在 `module.json5` 声明 `WRITE_IMAGEVIDEO` 后是否会把它加进 ACL，属推断；release 必须走 AGC 受控权限申请。
3. **▶ 未验证**：项目无 `startAbility` 先例，隐式 Want 能否拉起播放器需真机确认（4.10）。
4. **行程身份漂移**：`tripId` 含整次扫描的序号（`entry/src/main/ets/bridge/CoreBridge.ets:493`），源素材增删会导致重编号。4.4 的 `(tripTitle, tripStartTs)` 校验是缓解，不是根治 —— 同一时刻同名的两趟行程仍可能撞车。
5. **孤儿记录**：记录存的是指针不是副本，成片被用户在相册删掉即悬空（4.11 的降级显示）。
6. **`entry/src/main/module.json5` 里 `READ_MEDIA` / `WRITE_MEDIA` 自 API 22 起已废弃**，与本次无关但值得顺手清理。
7. **`oh-package.json5` 的描述写着 "HarmonyOS6 API22"**，与实际 API 26 不符，属于陈旧信息。

---

## 7. 开发者自主决定的范围 (Left to the Builder)

1. `EditRecord` 的具体字段映射与还原时的状态装配实现。
2. Tab 切换动画、卡片阴影/圆角的具体数值。
3. 多选删除的交互细节（全选、反选、批量确认文案）。
4. 缩略图异步加载的并发度与占位图样式。
5. `pref_edit_records` 的 schema 迁移策略。
6. 覆盖询问弹窗的具体文案与按钮措辞。
