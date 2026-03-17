# 重构任务分解（tasks.md）

## 执行状态

- [x] 阶段 A：模型统一（Models.ets）
- [x] 阶段 B：编辑页状态流改造（EditorPage.ets）
- [x] 阶段 C：导出调度器隔离（ExportManager.ets）
- [x] 阶段 D：清理与替换
- [x] 阶段 E：验证与回归

## 阶段 A：模型统一（Models.ets）

- [x] Task1：新建 `Models.ets`，定义统一枚举与实体
  - [x] `CameraPosition`
  - [x] `TemplateId`
  - [x] `ClipSegment`
  - [x] `CameraTrack`
  - [x] `Trip`
  - [x] `Template`
  - [x] `EditorConfig`
  - [x] `EditorState`
  - [x] `ExportSnapshot`
- [x] Task2：创建并运行 `build_ffmpeg.sh`，按指定 NDK 与 configure 参数编译 FFmpeg8.0.1，输出 `.so` 到 `entry/src/main/cpp/libs`
- [x] Task3：修改 `CMakeLists.txt` 链接 FFmpeg `.so` 与 `native_media_venc/avmuxer`，新增 `export_engine.cpp` 实现 `avformat+avfilter -> OH_VideoEncoder+OH_AVMuxer` 管线并接入 NAPI
- [x] Task4：建立兼容适配层
  - [x] 将历史 `DvrMeta/TripSnapshot` 映射为新 `Trip`
  - [x] 保证旧扫描链路可向新模型供数
- [x] Task5：收敛模板定义
  - [x] 为 T1-T4 明确 `requiredCameras`、`slotBindings`、`ffmpegPolicy`

## 阶段 B：编辑页状态流改造（EditorPage.ets）

- [x] Task6：完成编辑页状态流改造（EditorPage.ets）
  - [x] 将页面业务状态收敛到单一 `@State editorState`
  - [x] 移除多源可写状态（playhead/range 等）并改为 selector 输出
  - [x] 引入 action/reducer：`SET_TEMPLATE`、`SET_RANGE`、`SET_PLAYHEAD`、`TOGGLE_PRIVACY`、`SET_SPEED`、`TOGGLE_MUTED`、`TOGGLE_WATERMARK`
  - [x] 修复 ArkTS 响应式：禁止深层字段直改，子组件使用 `@ObjectLink`/`@Observed` 传播

## 阶段 C：导出调度器隔离（ExportManager.ets）

- [x] Task7：完成导出调度器隔离（ExportManager.ets）
  - [x] 新建 `ExportManager.ets`
  - [x] 设计导出入口：`start(snapshot: ExportSnapshot): ExportJobId`、`cancel(jobId)`、`subscribe(jobId, listener)`
  - [x] 导出前快照化：`deepClone(editorState)` 生成不可变快照，并校验模板所需视角完整性
  - [x] 导出执行隔离：`ExportManager` 内部调用 FFmpeg 组装服务，禁止读取 EditorPage 或 CoreBridge 的可变字段

## 阶段 D：清理与替换

1. 收缩 `CoreBridge` 职责到数据访问与平台桥接。
2. 清理旧状态字段与冗余模型引用。
3. 替换页面导出调用到 `ExportManager`。

## 阶段 E：验证与回归

1. 用例：模板切换后预览与导出输入一致。
2. 用例：跨文件时间轴选择后导出边界正确。
3. 用例：导出执行时修改 UI，不影响本次任务参数。
4. 用例：离开页面后状态对象释放，不残留上次 session 污染。

## 阶段 F：无缝播放竞态修复（Editor.ets / SeamlessVideoPlayer.ets）

- [x] Task8：修复多段切换竞态与暂停反写
  - [x] 为切源流程增加版本门禁，忽略过期状态事件
  - [x] 为 seek 增加缓存与 prepared 后补偿，保证拖动衔接
  - [x] 对主画面 paused 回调增加抑制窗口，避免切段期反写 `previewPlaying`
- [x] Task9：补充关键日志并完成验证
  - [x] 增加切源版本、状态迁移、暂停抑制命中日志
  - [x] 执行可用验证并记录结果
