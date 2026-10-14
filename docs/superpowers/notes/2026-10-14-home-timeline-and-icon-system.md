# 首页时间轴改版 + 图标系统落地说明

日期：2026-10-14 · 对应 `mockups/ui-options.html` 的 p-g / p-h / p-i / p-j 四个面板

## 一、这一轮改了什么

| 面板 | 落点 | 状态 |
| --- | --- | --- |
| p-g ★A+C 混搭 · 时间轴版 | `pages/Index.ets` 整段重写 | 已实现 |
| p-h v2 剪辑页 · 固定播放区 | `pages/Editor.ets` + `components/SegmentTrack.ets` | 已实现 |
| p-i v2 片段手柄 | `components/SegmentTrack.ets` | **App 本来就是对的，未改** |
| p-j v2 图标系统 | 新建 `components/AppIcon.ets`，替换 6 处 | 已实现 |

### 1. 首页：从「深色原型图」换成暖白时间轴

改前 `pages/Index.ets` 里**一个 `$r('app.color.*')` 都没有**，配色全是硬编码
（`#181818` 背景 / `#FF7A00` 橙 / `#282828` 卡 / `#333333` 封面兜底 / `#999999` 文字），
而 `color.json` 那套暖色令牌剪辑页早就在用了 —— 首页是掉队的那一页。

现在：

- **配色全部走令牌**，`page_bg` 暖白底 + `card_bg` 白卡 + `card_border` 描边。
- **两列 Grid 换成单列 List**，卡面 16:9（与原始视频同画幅），左侧 46vp 时间轴轨。
- **卡面不留任何文字**：机位数、分辨率、时长、`完整/不完整` 徽章全部拿掉。
  时长与左轨的开始时间语义重复，机位数与分辨率则是选行程时用不上的信息。
- **机位齐全度改用状态点表达**：齐全 = 实心琥珀，缺机位 = 空心（`isTripComplete()`）。
  信息没丢，但不再需要第三个强调色。
- **日期分组头**：`2026-10-01` → `10月1日 周四`，只在换天时出现一次。
- 新增 `utils/TripFormat.ets` 承载 4 个纯函数（开始时间、完整度、日期、时长格式化）。

顺带修掉一处隐患：`HomeViewModel.ets` 原来的 `getCompletenessColor()` 返回 `#0A59F7`
（蓝），是全 App 的**第三个强调色**，与琥珀冲突。徽章一删，这个蓝色也就不存在了。

**时间轴竖线怎么画的**：没有用任何百分比高度（`height('100%')` 在 List 里会退化成
撑满整个列表）。竖线画在封面容器的**左边框**上，而容器带 `padding({ bottom: 12 })`，
所以边框天然覆盖「卡片 + 行间距」的完整高度，相邻两行自动接得上。最后一行把边框颜色
换成 `page_bg` 隐藏。

### 2. 剪辑页：画面区恒 16:9

`Editor.ets` 原来画面区跟模板走 `getPreviewAspectRatio()`，内容宽 326px 时五个模板的
自然高度是 **366 / 275 / 92 / 92 / 183 px —— 最大差 4 倍**，每切一次模板，下面的参数行和
片段轨道就上下弹一次。

现在画面区定死 `STAGE_ASPECT_RATIO = 16 / 9`。`EditorPreviewArea` 内部本来就有一层
`aspectRatio(templateAspectRatio)` 的等比约束，模板组合会在里面按 Contain 缩放居中、
四周留 `stage_bg` 黑边，所以这一处改动就够了，不需要动组件。

同时给 PlayerCard 补了一层极轻的暖色投影（`shadow_soft`），给画面区加了 `stage_divider`
内描边和 10vp 圆角 —— 之前整张卡只有一层 1px 描边落在同为浅色的底上，这正是「像原型图」的来源。

**进度条**：`PreviewOverlay` 的轨道本来就是 `width('100%')`（占满播放器宽度减左右各 12vp），
但只有一根 30% 白的细轨加一个白点，压在高亮画面上几乎看不见，"进度条"读起来就只剩一个圆钮。
现在轨道加粗到 3vp，并叠了一条按播放进度填 `amber` 的已播部分。

### 3. 片段手柄：App 本来就是对的

需求是「只有选中的片段带手柄」。`SegmentTrack.ets` 的 `segmentBlock()` 里本来就是
`if (this.isSelected(segment)) { this.handles() }` —— 手柄只在选中段出现，**未改任何代码**。
之前看到「每段都有手柄」是 mockup 里画的旧状态，不是 App 的实际行为。

### 4. 图标：全部矢量，零新增资源文件

新建 `components/AppIcon.ets`，含 `AppIcon`（8 个图标）与 `TemplateGlyph`（5 个模板缩略图）。

统一规格：**24×24 viewBox、1.9 描边、圆头圆角、颜色可传入**，靠 `Shape.viewPort`
缩放到任意尺寸，所以同一份路径在 14 / 18 / 20 / 22 上都保持一致的视觉重量。
`play` 与 `check` 形状太简单，改填充以免描边显脏。

替换掉的 6 处文本/emoji：

| 位置 | 改前 | 改后 |
| --- | --- | --- |
| `pages/Editor.ets` 顶栏 | `Text('←')` | `AppIcon(Back, 20)` |
| `pages/Editor.ets` 播放钮 | `Text('▶')` | `AppIcon(Play/Pause, 22)`，随播放状态切换 |
| `components/SegmentTrack.ets` 浮层 | `Text('✂')` | `AppIcon(Scissors, 18)` |
| `components/SegmentParamRow.ets` | `Text('✕')` | `AppIcon(Close, 18)` |
| `components/SegmentParamRow.ets` 喇叭 | 手绘 Path（16 单位） | `AppIcon(Speaker/Muted, 20)`，统一到 24 单位 |
| `components/TemplateStrip.ets` 缩略图 | emoji（`📹📹` / `👁️👁️👁️` / `⬅️➡️` / `🎬` / `📹`） | `TemplateGlyph` |
| `pages/Index.ets` 选中勾 | `Text('✓')` | `AppIcon(Check, 14)` |

**模板缩略图画的是版式，不是画面。** emoji 表达的是"内容"，但用户选模板时真正要判断的是
「这一屏会切成几格、谁大谁小」。`TemplateGlyph` 直接读 `Models.ets` 的 `previewSlots`
逐槽画方块，所以缩略图与进画面后看到的分屏必然一致，改比例时图标自动跟着对。

已删除的死代码：`AppConstants.getTemplateIconById()`、`EditorViewModel.getTemplateIcon()`、
`Editor.getTemplateIcon()`（三者都只为了产出 emoji，替换后无调用者）。

## 二、怎么构建（本沙箱实测可用）

`hvigor` 在这个沙箱里**能跑**（早期文档里"跑不起来"的结论已经不成立）。关键是
DevEco 自带的 node 必须在 PATH 上，且要设 `DEVECO_SDK_HOME`：

```powershell
$env:PATH = "C:\Program Files\Huawei\DevEco Studio\tools\node;$env:PATH"
$env:DEVECO_SDK_HOME = "C:\Program Files\Huawei\DevEco Studio\sdk"
& "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" `
    assembleHap --mode module -p product=default --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-signed.hap`（约 16 MB）。

注意 `hvigorw.bat` 的 stderr 会带 ArkTS 警告，PowerShell 会把它当 `NativeCommandError`
报出来（退出码看起来是 1）——**看 `BUILD SUCCESSFUL` 那一行才算数**。

DevEco 的 `tools/node` 目录里同时有 `node.exe` / `npm.cmd` / `npx.cmd`，
所以需要 `npx` 时把它加进 PATH 即可，不必另外装 Node。

## 三、本次验证结果

| 验证 | 命令 | 结果 |
| --- | --- | --- |
| ArkTS 全量编译 | `hvigorw clean` + `assembleHap` | `CompileArkTS` 3.19s，**BUILD SUCCESSFUL**，涉及本次改动的文件 0 error / 0 warn |
| 纯函数单测 | `node tools/offline-test.mjs` | **131/131 通过**（新增 17 个 `TripFormat` 用例） |
| 类型检查 | `node tools/typecheck-player.mjs {player,bridge,export,home}` | 9 / 15 / 12 / 16 文件，**均 0 诊断** |

`tools/offline-test.mjs` 新增两项守卫：
- `SUITES` 注册 `TripFormatCases`；
- `UI_FILES` 加入 `pages/Index.ets` —— 首页从此也被"不得出现十六进制色值 / 遗留配色"
  这条守卫盯着，`#181818` 这类回退会直接让测试红。

`tools/typecheck-player.mjs` 新增 `home` 分组（`HomeViewModel` + `TripFormat`）。

## 四、还没做的

- **未在真机上跑过**：本沙箱只能编译，画面效果、时间轴竖线的接缝、`Shape.viewPort`
  的实际缩放都得在设备上看一眼。真机验收清单见
  `docs/superpowers/notes/2026-10-13-ui-delivery-and-verification.md` 第三节。
- **AI 生成位图仍未落地**：`AppIcon` 覆盖了全部功能图标，不需要位图。真正还值得出图的
  只剩**空状态插画**（`Index.ets` 的 `emptyBlock()` 目前只有一行灰字）和桌面 App 图标。
  prompt 见 `mockups/ui-options.html` 的 p-j 面板第 4 节。
- **T3/T5 命名已统一（2026-10-14 追加）**：原先 `AppConstants.getTemplateUiNameById`
  叫「左右盲区 / 单视角」，`Models.ets` 的 `title` 叫「侧向防开门杀 / 单前视」。
  按决定统一到前者 —— `Models.ets` 的 `title` 改成「左右盲区」「单视角」。
  同时加了一条文本对账守卫 `checkTemplateNamingConsistency()`
  （`tools/offline-test.mjs`）：`AppConstants` 依赖 `@kit.AbilityKit`，进不了纯模块 BFS，
  所以按文本解析两处再逐条比对。已实测**制造一次漂移它会红**，还原后恢复全绿。
  `AppConstants.getTemplateUiNameById()` 与 `Models` 的 `title` 现在语义一致：
  前者是界面名，后者是回落名与导出/日志名，两者取同一份文案。
- `EditorViewModel.getPreviewAspectRatio()` 现在没有调用者了（画面区改恒定后），
  但它是模板几何的合法查询口，暂时留着。
