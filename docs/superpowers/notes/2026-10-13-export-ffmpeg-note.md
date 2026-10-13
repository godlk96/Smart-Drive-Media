# 导出链路与 ffmpeg 交互备注

日期：2026-10-13 · 分支 `feat/editor-multisegment-ui` · 关联计划 `docs/superpowers/plans/2026-10-13-editor-multisegment-ui.md`（Task 11/12）

## 为什么停在这里

计划 Task 12（native 逐段渲染）开工前必须先查清「导不出」的根因。本沙箱无 NDK、无 DevEco，
C++ 只有括号平衡与人工 diff 复核，**没有编译与运行证据**。在一条已知坏掉的链路上盲写约 480 行
编解码改动，只会把「已知坏」变成「未知坏」，正是用户约束④禁止的堆屎山。

## 已核实的静态事实（每条都有出处）

1. **ffmpeg 只编了 mpeg4 一个编码器**。`build_ffmpeg.sh:113-114`：
   `--disable-encoders` + `--enable-encoder=mpeg4`。没有 libx264 / libx265
   （`.ffmpeg-install/arm64-v8a/lib` 下只有 6 个 `libav*` / `libsw*` so）。
2. **编码器选择必然落到 mpeg4**。`entry/src/main/cpp/export_engine.cpp:253-266` 是
   HEVC → H264 → MPEG4 逐级回落，前两个在本次构建里都返回 nullptr。
   因此成片视频轨是 **MPEG-4 Part 2（mp4v）**，不是 H.264/HEVC。
3. **音频不走编码器**，全部是 stream copy（`avcodec_parameters_copy`，见
   `export_engine.cpp:363`、`:797`、`:993`），所以 `--disable-encoders` 不影响音频轨。
4. **唯一会编码的地方**是 `composeTemplateToMp4` 的视频轨
   （`entry/src/main/cpp/export_engine.cpp:240-724`）。
5. **native 层没有任何 hilog**。在 `entry/src/main/cpp/` 下 grep `hilog|OH_LOG` 零命中；
   `logPipeline`（`export_engine.cpp:1102-1105`）只做 `fprintf(stderr, ...)`。
   HarmonyOS 上应用进程的 stderr 不进 hilog，所以那 20 处 pipeline 诊断
   （含 `pipeline_track_front_*`、`pipeline_mux_*` 的细节）**在设备上看不见**。
6. **唯一能到达用户的信息是错误串**：`export_engine.cpp` 返回
   `__ERROR__:pipeline_<stage>_<detail>` → `napi_init.cpp:383` 包成
   `EXPORT_ERR_NATIVE_FAILED(2002)` → `entry/src/main/ets/service/ExportNativeService.ets:315-318`
   抛出 `导出失败[2002]：__ERROR__:pipeline_mux_<detail>`，并经
   `entry/src/main/ets/service/ExportManager.ets:195` 的 `debugLog('导出', ...)` 落到 hilog 与日志文件。
7. **缺库不是原因**。`.ffmpeg-install/arm64-v8a/lib` 下 6 个 so 齐全
   （libavcodec.so.62.11.100 / libavfilter.so.11.4.100 / libavformat.so.62.3.100 /
   libavutil.so.60.8.100 / libswresample.so.6.1.100 / libswscale.so.9.1.100）。
8. `entry/src/main/cpp/CMakeLists.txt` 无 `-Werror`，未使用的形参不会导致构建失败。
9. **不是近期回归**。`--disable-encoders` 的构建配置自 `7b9adfb` 起就在；
   `aba7df8` 只是删掉 `entry/src/main/cpp/libs/` 下的重复 so 并把 CMakeLists 指向 `.ffmpeg-install`。

## 需要用户提供的一件事（根因门槛）

在设备上复现一次导出，把 UI 上「导出失败[…]」整行文字，或 hilog 里 `导出` tag 的那几行贴出来。
按错误串可以立刻分诊：

| 现象 | 落点 |
| --- | --- |
| `pipeline_mux_*` | `composeTemplateToMp4` 的编码 / 封装段（`export_engine.cpp:240-724`） |
| `pipeline_track_front_*` / `_back_` / `_side_` | `concatTrackToMp4`（`export_engine.cpp:724-940`） |
| `ERR_NATIVE_EMPTY`，或没报错但相册里没文件 | 写文件 / 存相册（`ExportManager.ets:230-296`） |
| 导出成功但相册不认、或播放器打不开 | 很可能就是 mp4v 不被媒体库索引，需要把 ffmpeg 重建为带 H.264 编码器 |

## 与 Task 12 的关系

Task 12 的逐段渲染落在 `buildTemplateFilterDesc`
（`entry/src/main/cpp/export_engine.cpp:189-238`）：现在整条链路共用一对
`startSec` / `endSec`（由 `:1530-1533` 从 `startMs` / `endMs` 推出），
改成逐段后每段都要自己的 `movie=` + `trim` + `setpts`，倍速还要叠加 `atempo` / `asetpts`。
这一段是纯 filtergraph 字符串拼接，逻辑独立、可以先把字符串拼好再接入，
但接入后的正确性只能靠设备验证。
