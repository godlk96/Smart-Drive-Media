# 多段剪辑 UI 交付说明与验收清单

日期：2026-10-13 · 分支 `feat/editor-multisegment-ui` · 相对 `main`（`5981eaa`）16 个提交、29 文件、+3629 / −606

## 一、交付范围

Task 1–11 已完成并逐个提交；Task 12（native 逐段渲染）按用户约束③留到最后。

| 提交 | 内容 |
| --- | --- |
| `4ab4850` | 落主题色板到 `color.json` 并加令牌守卫 |
| `6990100` | 片段模型的数据结构与时长换算（`SegmentModel.ets`） |
| `55a3295` | 落刀切分与段数段长上限 |
| `2f06dd6` | 段开关、倍速循环与播放跳过 |
| `5950fdf` | `EditorStateModel` 用 `segments` 取代单区间与全局倍速静音 |
| `2c29a86` | 导出契约扩成带参数的多段区间 |
| `ccc2b1e` | `typecheck-player` 增加 bridge 分组 |
| `e4fb870` | 片段操作接入 `CoreBridge`，倍速改为按选中段循环 |
| `75c6f17` | 补 9 个颜色令牌并加组件配色守卫 |
| `5a1a581` | 参数行、片段轨道与模板行三个组件 |
| `fda880b` | 剪辑页按纸白规格重做，去掉全部硬编码配色 |
| `8c9fba7` | 补上设计文档与实施计划 |
| `a833cd3` | 预览按段应用倍速与静音，补 1.5X 枚举映射 |
| `8f78ab1` | native 解析 `segments` 数组并校验 |
| `ca7d960` | 导出/ffmpeg 诊断备注 |
| `87c54e4` | 导出链路完整打点，native 接 hilog，修相册写入静默截断 |

改动面：

- **主题色板** `entry/src/main/resources/base/element/color.json`：共 32 个令牌（原有 1 + Task 1 的 17 + Task 8 的 14）。
- **数据模型** `entry/src/main/ets/model/SegmentModel.ets`：纯模块（不 import 任何 `@ohos.*`），因此可被 `tools/offline-test.mjs` 离线单测覆盖。
- **状态** `entry/src/main/ets/model/AppState.ets`：`EditorStateModel` 用 `segments: Array<Segment>` + `selectedSegmentId` 取代 `selectionStartSec` / `selectionEndSec` / 全局 `speedLabel` / `muted`。
- **桥接** `entry/src/main/ets/bridge/CoreBridge.ets`：新增 `splitAtPlayhead()` / `canSplitAtPlayhead()` / `toggleSegmentEnabled(id)` / `selectSegment(id)`；`cycleSpeed()` / `toggleMuted()` 改为作用于**选中段**；删除 `updateSelectionRange()` 与 `EDITOR_SPEEDS`。
- **UI** `entry/src/main/ets/pages/Editor.ets` 的 `build()` 整段重做，配合四个组件：
  `components/SegmentTrack.ets`、`components/SegmentParamRow.ets`、`components/TemplateStrip.ets`、`components/EditorPreviewArea.ets`。
- **导出契约** `entry/src/main/ets/model/TripModels.ets`：新增 `ExportSegment`（`startMs` / `endMs` / `speedLabel` / `muted`）与 `ExportComposeRequest.segments`。
- **打点** native hilog + ArkTS 日志（见第四节）。

## 二、如何构建

1. DevEco Studio 打开 `C:\Users\gzr\Desktop\Smart-Drive-Media`。
2. 切到分支 `feat/editor-multisegment-ui`。
3. 需要 OHOS NDK；ffmpeg 预编译件已在仓库内
   （`entry/src/main/cpp/.ffmpeg-install/arm64-v8a/`，`lib` 下 6 个 so 齐全）。
4. Build → Run 到真机。

本沙箱能跑的自检（改完随时可重跑）：

```
node tools/offline-test.mjs              # 纯函数单测
node tools/typecheck-player.mjs player   # 播放链路 9 文件
node tools/typecheck-player.mjs bridge   # 桥接与视图模型 15 文件
node tools/typecheck-player.mjs export   # 导出链路 12 文件（本次新增）
```

## 三、真机验收清单（对应 spec §8）

1. 进页面默认是一整段覆盖全片；不剪任何一刀就能调倍速/声音并导出。
2. 点剪刀能切出第 2、3 段；到 3 段时剪刀不可用并有提示。
3. 任一段短于 2 秒时落刀被拒绝并有提示。
4. 点片段块 → 该段选中且进度条圆钮跳到该段起点。
5. 每段的倍速与声音互不影响；改一段不动其他段。
6. `✕` 后该段变灰划掉，导出结果里不含它；播放时跳过它。
7. 倍速按钮点击顺序为 `0.75x → 1.0x → 1.25x → 1.5x → 2.0x → 0.75x`。
8. 声音按钮点击在 原声 / 静音 之间切，图标随之变化。
9. 画面比例跟随模板切换（T1 8:9、T2 32:27、T3/T4 32:9、T5 16:9）都正确。
10. 导出浮层只有转圈 + 文字，无成片时长。
11. 全页无 `#FF7A00` / `#0A59F7` / `#FF4444` 残留。

补充两条（本次预览改动的验收点）：

12. 把某段调成 `2.0X`，预览播放该段时画面确实变快（Task 10 的所见即所得）。
13. 把某段静音，预览播放该段时确实无声；离开该段后声音恢复。

## 四、导出排查指引（本次新增的打点）

**native 侧**（`export_engine.cpp` 的 `logPipeline`，本次起同时写 hilog）：

```
hdc shell hilog | grep export_engine
```

tag 固定 `export_engine`，domain `0x3200`。会打出的关键行：

- `[request]`：front/back/side 数量、template、expectedDurationSec、startMs/endMs、segments 数、output 路径。
- `[request.segment]`：逐段 startMs/endMs/speed/muted。
- `[probe]`：探测到的宽高、像素格式、帧率。
- `[template]`：归一化模板与目标分辨率。
- `[mux]`：选中的编码器、HEVC/H264/MPEG4 各自是否可用、是否发生回落。
- `[mux.encoder]`：分辨率、帧率、时基、码率、线程数。
- `[filter]`：最终交给 ffmpeg 的完整 filtergraph 字符串。
- `[track]`：三条轨道的实际路径与是否带前路音轨。
- `[complete]`：输出路径与字节数。
- 任一失败点会带 `av_strerror` 文本（如 `compose_open_output_failed:Permission denied (ret=-13):/data/...`）。

**ArkTS 侧**（`debugLog`，tag `导出`）：请求摘要、native 请求负载与逐段明细、native 返回 `code` / `message`、相册写入开始、失败时的 stack。

错误串解读：

| 现象 | 落点 |
| --- | --- |
| `pipeline_mux_compose_open_output_failed:*` | 输出文件打不开（路径 / 权限） |
| `pipeline_mux_compose_open_encoder_failed:*` | 编码器打不开（带编码器名） |
| `pipeline_mux_compose_graph_parse_failed:*` / `_config_failed:*` | filtergraph 非法，对照 `[filter]` 那行 |
| `pipeline_mux_compose_write_header_failed:*` / `_write_packet_failed:*` | 封装器拒收 |
| `pipeline_track_front_*` / `_back_` / `_side_` | `concatTrackToMp4` 阶段 |
| `保存到相册失败: ...` / `相册写入中断（已写入 X/Y 字节）` | 相册写入阶段 |
| 导出成功但相册不认 | 很可能是成片视频轨是 MPEG-4 Part 2（mp4v），见 `docs/superpowers/notes/2026-10-13-export-ffmpeg-note.md` |

## 五、未验证项（必须留给 DevEco / 真机）

- `entry/src/main/ets/pages/Editor.ets` 与 `components/` 下四个组件都是 ArkUI（`@Entry` / `@Component` / `struct` / `@Builder`），
  本沙箱的 tsc 解析不了装饰器，**零编译证据**。已做的替代验证：花括号平衡、无残留引用、无十六进制色值。
- `entry/src/main/cpp/` 的 `napi_init.cpp` / `export_engine.cpp` / `export_engine.h`：已改为用 OH SDK 自带的
  `clang++.exe` 做 `-fsyntax-only`（`tools/ffmpeg-oh/syntax-check-native.sh`），**0 error**；但链接与真机运行仍待 DevEco。
- `h264_oh` / `hevc_oh` 硬件编码器在真机上的实际行为（本沙箱无法运行 aarch64 二进制）。

## 六、ffmpeg 重建与多段导出（2026-10-13 晚追加）

### 为什么重建 ffmpeg

旧库的 configure 行是 `--disable-encoders --enable-encoder=mpeg4`，整个 libavcodec 只有 mpeg4 一个编码器
（`libx264` / `libx265` / `h264_mediacodec` 命中数均为 0），成片视频轨必然是 MPEG-4 Part 2；
而且没有 aac 编码器，音频只能包直通，**倍速与静音在导出里无从生效**。

新库用官方 ffmpeg 8.0 源码交叉编译（WSL + OH SDK 的 clang.exe），配置：

```
--enable-ohcodec --enable-encoder=h264_oh,hevc_oh,aac --disable-gpl --disable-nonfree
```

结果：`CONFIG_OHCODEC=1`、`H264_OH_ENCODER=1`、`HEVC_OH_ENCODER=1`、`AAC_ENCODER=1`，`CONFIG_GPL=0`、
`CONFIG_NONFREE=0`，License **LGPL 2.1+**。滤镜 438 个，`fps` / `setsar` / `setpts` / `asetpts` / `atempo` /
`atrim` / `volume` / `aresample` / `aformat` / `concat` / `movie` / `amovie` 全部可用。

编码器选择顺序：`h264_oh` → `hevc_oh` → 软件 `h264` → `mpeg4`。

### 多段导出怎么实现

- **视频**：每段 `trim=start:end` → `setpts=(PTS-STARTPTS)/<speed>`（压缩时间戳）→ `fps=<源帧率>`（重采样抽帧，
  倍速由此落到帧数上，同时把各段归一到同一时间基）→ 模板布局 → `format=yuv420p,setsar=1`；
  多段用 `concat=n=N:v=1:a=0` 拼接。
- **音频**：每段 `amovie` → `atrim` → `asetpts` → `atempo=<speed>` → `volume=<1|0>` → `aresample=48000` →
  `aformat=fltp/stereo`；多段用 `concat=n=N:v=0:a=1` 拼接。**静音段用 `volume=0` 而不是丢音频**，保证时长对齐。
- 音频从「包直通」改为「滤镜 + AAC 重编码」——`atempo`（保音调变速）和 `volume=0` 都必须解码到 PCM 才能做。
- 灰段（`enabled=false`）不进 `segments`，因此天然被导出跳过，与预览的「播放跳过灰段」一致。

### 本次拿到的离线验证（不需要真机）

| 验证 | 命令 | 结果 |
| --- | --- | --- |
| native 语法 | `bash tools/ffmpeg-oh/syntax-check-native.sh` | `export_engine.cpp` / `napi_init.cpp` 均 0 error |
| 滤镜图真跑 | `bash tools/ffmpeg-oh/validate-filter-graph.sh` | 单段 60.00s；两段 0-15(1.0x)+30-59(2.0x) → **29.50s**；三段 0.75x/静音/1.5x → **30.00s**；单段单路 10.00s，全部命中期望 |
| 静音是否真静 | 同上（`volumedetect`） | 静音段 mean_volume **-91.0 dB**，有声段 -24.1 dB |
| ArkTS 纯逻辑 | `node tools/offline-test.mjs` | 114/114 通过 |
| ArkTS 类型 | `node tools/typecheck-player.mjs player\|bridge\|export` | 9 / 15 / 12 文件，均 0 诊断 |

滤镜图验证的做法：在 WSL 里另编一份**原生 x86_64** ffmpeg（软件编码器替代 `h264_oh`，滤镜图完全一致），
跑与 C++ 生成串逐字对应的 `filter_complex`，比对时长与音量。

### 真机导出失败怎么分诊

`hdc shell hilog | grep export_engine`（tag `export_engine`，domain `0x3200`）。关键行：

- `[filter] ... desc=<完整滤镜串>` —— 滤镜图是否按预期生成
- `[filter.audio] ... desc=<完整音频滤镜串>`
- `[mux] selected encoder=<名字> ...` —— 是否真的选中了 `h264_oh`
- `[encode] begin/progress/loop end/finish` —— 编码是否推进、结束原因是 eof 还是 eagain
- `[complete] output=... bytes=...` —— 成片是否落地

## 七、已知残留（不影响本次验收）

- `muxVideoWithFrontAudio` 与 `concatTrackToMp4` 目前都没有调用者（旧路径遗留）。
- `.localappdata/` 与 `.pnpm-home/` 是沙箱产物，未跟踪也未进 `.gitignore`。
