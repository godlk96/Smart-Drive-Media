# Export performance and progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 减少重复复制和无用解码，以真实工作量提供细腻的导出进度。

**Architecture:** 保持 ArkTS → NAPI → FFmpeg 结构。共享可取消的文件复制实现；原生保留精确裁剪并提前定位，复用 T5 输入，细化阶段进度。UI 以小数百分比和平滑环展示。

**Tech Stack:** HarmonyOS API 22，ArkTS/ArkUI，C++17，FFmpeg 8.0。

**Spec:** `docs/superpowers/notes/2026-10-18-export-performance-research.md`，用户已确认首批范围并授权择优采纳外部 Review。

## Global Constraints

- 保持画质、分辨率、倍速和静音语义；不引入运行时依赖。
- 进度按真实字节/帧推进，显示到 0.1%，成功保存后才显示 100%。
- 每次任务只物化一个 URI 一次，但保留轨道中合法的重复引用。
- 保留复制中取消、覆盖截断、错误提示及临时文件清理。
- 本轮不重建 FFmpeg 库，不以符号缺失推断 SIMD 被禁用。

## Review Focus

- 非整帧边界和音频预滚：定位后仍与原裁剪内容、时长一致。
- 多路准备中的取消/单路失败：等待其他复制结束再清理，不遗留素材。
- 短写、读错误和源文件截短：不能误报保存成功或补进度至 99%。
- 连续取消/重新导出：禁止同时占用全局原生任务状态。
- native 阶段间的原子快照：进度不倒退，未知总量不伪造推进。

### Task 1: Review 核验和验证用例

**Files:** `tools/export-test.mjs`；上述调研记录。
**Interfaces:** 测试加载真实 ETS 模块，以内存 fs 和原生导出桩替代平台接口。

- [x] 核实实际 FFmpeg configure、NEON 配置、默认线程及系统 copyFile 的取消/进度能力。
- [x] 为文件复制短写/取消/失败、进度计算和输入去重建立回归用例，先观察新增行为失败。

### Task 2: 可取消复制与输入复用

**Files:** 新建 `entry/src/main/ets/service/ExportFileCopy.ets`；修改 `ExportNativeService.ets`、`ExportManager.ets`。
**Interfaces:** `copyExportFileData(sourceFd: number, targetFd: number, totalBytes: number, onProgress: (copied: number, total: number) => void, isCancelled: () => boolean): Promise<number>`。

- [x] 复用 1 MiB 缓冲区，正常写入使用 length，短写补全，取消和 EOF 长度校验。
- [x] 同一 URI 共享复制 Promise，任务失败时等待所有物化工作退出后统一清理。
- [x] 两处复制共用实现；保存阶段保留覆盖截断和已写字节错误说明。
- [x] 运行 `node tools/export-test.mjs`，文件复制相关用例全部通过。

### Task 3: 原生解码与阶段进度

**Files:** `entry/src/main/cpp/export_engine.cpp`、`export_engine.h`、`napi_init.cpp`。
**Interfaces:** 原进度字段不变，增加 `completedUnits`、`totalUnits`；stage 1 校验、2 编码、3 封装、4 拼接。

- [x] 视频提前定位并保留 trim；AAC 对照发现噪声还原状态改变，音频保持从头解码及 atrim，倍率仍由 setpts/atempo 处理。
- [x] 显式限制滤镜/解码线程预算，移除不参与正式管线的 8 帧预热调用；不替换缩放算法。
- [x] T5 不探测/拼接无用 back 轨；复用 front 路径。
- [x] 校验和拼接上报真实工作量，拼接每包检查取消；封装成功后上报完成阶段。
- [x] 运行原生语法检查及 FFmpeg 8.0 对照滤镜验证，检查帧哈希、音频和时长。

### Task 4: 进度集成与验收

**Files:** 新建 `entry/src/main/ets/model/ExportProgress.ets`；修改 `ExportNativeService.ets`、`ExportManager.ets`、`pages/Editor.ets`、`tools/typecheck-player.mjs`。
**Interfaces:** `ExportProgressUpdate` 包含 percent、stage、detail；现有 ExportJobEvent 的 progress/status 契约保持。

- [x] 按字节/帧计算阶段进度，最多每 120 ms 发一次非终态事件，保留阶段即时切换。
- [x] Manager 保留小数且单调，区分准备/检查/拼接/编码/封装/等待保存位置/写入相册/完成。
- [x] UI 展示 0.1%，启用 enableSmoothEffect；仅在成功终态到达 100%。
- [x] 运行导出回归、209 项离线用例、各组类型检查、NDK 语法检查、HAP 构建并检查输出。
- [x] 独立审查最终差异，处理影响正确性的问题，更新调研记录与实际验证证据。

实施方式：当前会话直接实施，已创建 `perf/export-progress` 分支，保留现有 SDK 和样本环境；不提交或推送。
