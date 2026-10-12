# Smart-Drive-Media 现代化演进与系统极简化实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 Smart-Drive-Media 升级至 HarmonyOS SDK API 23-26，清除 /src 废弃代码与 25MB 重复二进制，使用系统工具包（Preferences, AVImageGenerator, ArkUI V2）替代脆弱胶水，彻底修复裁剪失效、导出挂死、FD 泄漏、音视频时序倒挂四大致命死穴，大幅简化系统代码。

**Architecture:** 前端以单一 `@ObservedV2` 领域模型（`AppState.ets`）驱动 UI，消除 4 个胶水转换层；首页采用系统缩略图工具包消除 Video 实例并发风暴；Native 侧保留 FFmpeg FilterGraph 多机位拼接与隐私打码，去除中间 `.concat.mp4` 磁盘落盘与 movie 滤镜二次重读，改为 FilterGraph 内联 `trim` 毫秒级裁剪与音视频微交织写入。

**Tech Stack:** HarmonyOS Stage Model (API 23~26), ArkTS, ArkUI V2 (@ObservedV2/@Trace), C++ 17, Node-API (NAPI), FFmpeg 8.0.1 (libavfilter, libavformat, libavcodec, libswscale), @ohos.data.preferences.

**Spec:** `docs/superpowers/specs/2026-10-12-modernization-and-simplification-design.md`

## Global Constraints
- SDK 版本：`compatibleSdkVersion` 设为 `"23"`，`targetSdkVersion` 设为 `"26"`（在 `build-profile.json5` 中配置）。
- 架构约束：单一领域模型，禁止引入任何中间转换胶水类；禁止重新手写大型 OpenGL 混流渲染管线。
- 资源与安全约束：`PingPongTrackController` 每次加载/切换切片必须在 `try...finally` 中闭环 `fs.closeSync(fd)`；严禁伪造进度定时器。
- 代码约束：物理删除 `/src` 历史目录及 37 个旧测试，删除 `entry/src/main/ets/pages/Export.ets` 死页面。

## Review Focus
- 选区裁剪边界用例：用户在时间轴选取非 0 起点的子区间（如 15.5s ~ 35.2s），导出 MP4 的实际内容与时长必须与选区毫秒级对应，不得从 0 秒截取。
- 空素材导出用例：相册无可用素材或轨道为空时触发导出，界面必须在 500ms 内得到明确结构化失败提示并重置遮罩，绝不卡死。
- 长时播放 FD 句柄用例：用户反复拖动时间轴进行 50+ 次 Seek 和切片切换，进程打开的 FD 句柄保持平稳，不触发 `EMFILE`。
- 首页缩略图用例：相册存在 20+ 个行程时进入首页，卡片渲染为静态 Image，活跃 Video 解码器实例数恒定为 0。
- 音视频同步用例：导出的多切片合并视频在外部播放器播放，音频与视频时间戳平滑交织，无声画脱节与尾部爆音。

---

### Task 1: 环境底座升级至 API 23–26 与代码库瘦身

**Files:**
- Modify: `build-profile.json5:7-8`
- Delete: `src/` (全部 33 个文件)
- Delete: `test/` (全部 37 个针对 src 的旧测试和字符串匹配测试)
- Delete: `entry/src/main/js/harmonyBridge.mjs`
- Delete: `entry/src/main/ets/pages/Export.ets`
- Modify: `entry/src/main/resources/base/profile/main_pages.json`
- Modify: `entry/src/main/ets/constants/AppConstants.ets`
- Delete: `entry/src/main/cpp/libs/` (删除与 `.ffmpeg-install` 重复的 25MB `.so` 文件)
- Modify: `entry/src/main/cpp/CMakeLists.txt` (确保头文件与链接库统一指向 `.ffmpeg-install`)
- Modify: `.gitignore` (忽略 `logs/` 与 `*.txt`)
- Delete: `logs/debug.txt`

**Interfaces:**
- Consumes: 无（基础环境配置）
- Produces: API 23~26 构建配置与整洁的单项目代码库。

- [ ] **Step 1: 升级 build-profile.json5 中的 SDK 版本**
  修改 `build-profile.json5`：
  ```json5
  "compatibleSdkVersion": "23",
  "targetSdkVersion": "26",
  ```
- [ ] **Step 2: 物理删除废弃代码与冗余二进制**
  - 删除 `/src` 目录与全部旧测试文件；
  - 删除 `entry/src/main/js/harmonyBridge.mjs`；
  - 删除 `entry/src/main/ets/pages/Export.ets`；
  - 从 `main_pages.json` 中移除 `"pages/Export"`；
  - 删除 `entry/src/main/cpp/libs/` 中重复的 6 个动态库文件；
  - 调整 `entry/src/main/cpp/CMakeLists.txt`，将 `target_link_directories` 直接指向 `.ffmpeg-install/arm64-v8a/lib`；
  - 删除 `logs/debug.txt`，更新 `.gitignore` 包含 `logs/` 与 `*.txt`。
- [ ] **Step 3: 运行命令验证目录结构与环境整洁性**
  运行：`powershell -Command "Test-Path src; Test-Path entry/src/main/ets/pages/Export.ets; Test-Path entry/src/main/cpp/libs"`
  预期：全部返回 `False`。
- [ ] **Step 4: Commit 变更**
  ```bash
  git add -A
  git commit -m "chore: upgrade SDK to API 23-26, prune src legacy code and duplicate ffmpeg binaries"
  ```

---

### Task 2: 核心功能与资源漏洞修复（裁剪透传、导出竞态挂死、FD 闭环）

**Files:**
- Modify: `entry/src/main/ets/service/ExportNativeService.ets`
- Modify: `entry/src/main/ets/service/ExportManager.ets`
- Modify: `entry/src/main/ets/media/PingPongTrackController.ets`
- Modify: `entry/src/main/ets/pages/Editor.ets`
- Create: `test/exportAndResource.test.js`

**Interfaces:**
- Consumes: Task 1 基础工程
- Produces: 
  - `ExportNativeRequest` 包含 `startMs: number`, `endMs: number`。
  - `ExportManager` 提供带超时的强类型导出状态订阅与 settle 保障。
  - `PingPongTrackController.loadSlot` 与 `releaseSlot` 具备严格的 `closeSync(fd)` 闭环。

- [ ] **Step 1: 编写 ExportManager 状态机与超时处理的失败测试**
  在 `test/exportAndResource.test.js` 中编写单元测试，验证空素材导出能立即返回明确失败状态，且订阅者即使在任务启动后注册也能收到终态快照。
- [ ] **Step 2: 运行测试验证失败**
  运行：`node test/exportAndResource.test.js`
  预期：FAIL（文件不存在或模块未重构）
- [ ] **Step 3: 重构 ExportManager 与 ExportNativeService 消除竞态挂死并透传裁剪参数**
  - 在 `ExportNativeService.ets` 的 `ExportNativeRequest` 接口中增加 `startMs: number` 与 `endMs: number`；
  - 重构 `ExportManager.ets`：
    - 定义强类型枚举 `ExportStatus { PENDING, PROCESSING, COMPLETED, FAILED }`；
    - 修改 `start(snapshot, context)`：在触发异步 `run()` 之前先在 `jobs` 注册好初始记录；当异步发生空素材等异常时，将终态保留在 Map 中供迟到订阅者直接派发，同时增加 180 秒全局定时器兜底；
    - 废除基于中文 `startsWith('导出失败：')` 的通信协议，改用状态码或枚举判断。
- [ ] **Step 4: 修复 PingPongTrackController 的文件描述符 (FD) 泄漏**
  - 在 `PingPongTrackController.ets` 中，为每个 Slot 维护其持有的打开文件引用 `slot.currentFile`；
  - 在 `loadSlot()` 前、`player.reset()` 前、`releaseSlot()` 以及组件卸载时，严格执行：
    ```typescript
    if (slot.currentFile) {
      try {
        fs.closeSync(slot.currentFile.fd);
      } catch (_e) {}
      slot.currentFile = undefined;
    }
    ```
- [ ] **Step 5: 运行测试验证通过**
  运行：`node test/exportAndResource.test.js`
  预期：PASS
- [ ] **Step 6: Commit 变更**
  ```bash
  git add entry/src/main/ets/service/ExportManager.ets entry/src/main/ets/service/ExportNativeService.ets entry/src/main/ets/media/PingPongTrackController.ets test/exportAndResource.test.js
  git commit -m "fix: resolve export hang on empty clips, pass trim range and close player FDs"
  ```

---

### Task 3: FFmpeg Native 管线重构（FilterGraph 裁剪、音视频微交织、弃用 API 替换）

**Files:**
- Modify: `entry/src/main/cpp/export_engine.cpp`
- Modify: `entry/src/main/cpp/napi_init.cpp`

**Interfaces:**
- Consumes: Task 2 传递的 `startMs` / `endMs` 参数
- Produces: 
  - `runExportEnginePipeline` 接收裁剪起止时间并执行毫秒级截取；
  - `composeTemplateToMp4` 内消除 `.concat.mp4` 落盘，音视频包在同一循环中按 DTS 顺序微交织写入；
  - 全工程消除弃用的 `av_init_packet`。

- [ ] **Step 1: 检查 C++ 签名与参数透传**
  在 `napi_init.cpp` 中将 JS 传入的 `startMs` 与 `endMs` 提取并传入 `runExportEnginePipeline`。
- [ ] **Step 2: 改造 export_engine.cpp 的音视频交织与裁剪实现**
  - **去除中间落盘与滤镜重构**：在构建 FilterGraph 时，直接使用 `movie='uri':seek_point=startSec` 或内置 `trim=start=S:end=E`，消除提前向磁盘写出 `front.concat.mp4` / `back.concat.mp4` 的两阶段中间文件；
  - **音视频微交织写入**：重构编码输出写入循环，不再在所有视频包写完后才读音频包，而是根据输入包的 PTS 比例，音视频交替调用 `av_interleaved_write_frame`；
  - **弃用 API 替换**：将所有的 `AVPacket packet; av_init_packet(&packet);` 彻底替换为 `AVPacket *packet = av_packet_alloc();` 并在使用后配合 `av_packet_free(&packet);`。
- [ ] **Step 3: 语法与符号检查**
  确保 `export_engine.cpp` 和 `napi_init.cpp` 中的所有宏定义、时间基换算（`av_rescale_q`）和内存释放无语法错误。
- [ ] **Step 4: Commit 变更**
  ```bash
  git add entry/src/main/cpp/export_engine.cpp entry/src/main/cpp/napi_init.cpp
  git commit -m "refactor(native): enable trim in filtergraph, interleaved audio muxing and replace av_init_packet"
  ```

---

### Task 4: 官方系统工具包接入（首页静态缩略图与 Preferences 轻量持久化）

**Files:**
- Create: `entry/src/main/ets/service/PreferencesService.ets`
- Modify: `entry/src/main/ets/service/ExportNativeService.ets`
- Modify: `entry/src/main/ets/pages/Index.ets`
- Modify: `entry/src/main/ets/bridge/CoreBridge.ets`
- Create: `test/preferencesAndThumbnail.test.js`

**Interfaces:**
- Consumes: HarmonyOS `@ohos.data.preferences` 与媒体服务
- Produces:
  - `PreferencesService` 提供用户设置、最近行程、隐私开关本地持久化读写。
  - `extractFirstFrameByService` 真实输出静态图片缓存 URI。
  - `Index.ets` 卡片统一渲染静态 `<Image>`，消除并发 `<Video>` 自动播放。

- [ ] **Step 1: 编写 Preferences 数据持久化与缩略图逻辑的失败测试**
  在 `test/preferencesAndThumbnail.test.js` 中编写验证键值读写与默认回退的单元测试。
- [ ] **Step 2: 运行测试验证失败**
  运行：`node test/preferencesAndThumbnail.test.js`
  预期：FAIL
- [x] **Step 3: 实现 PreferencesService 封装**
  创建 `entry/src/main/ets/service/PreferencesService.ets`：
  - 基于 `@ohos.data.preferences` 实现 `saveLastTripId()`, `getLastTripId()`, `saveTemplatePreference()`, `getTemplatePreference()`, `savePrivacySettings()`, `getPrivacySettings()`；
  - 在 `CoreBridge.ets` 初始化与状态变更时调用，实现冷启动状态恢复。
- [x] **Step 4: 替换首页封面提取桩实现与 Index.ets 卡片改造**
  - 在 `ExportNativeService.ets` 的 `extractFirstFrameByService` 中，利用系统媒体元数据或图片生成能力，将首帧存为本地 `.jpg`/`.png` 缩略图；
  - 改造 `Index.ets`：卡片预览区域直接渲染 `<Image(item.previewFrameUri)>`，删除原先导致自动并发解码的 `<Video>` 组件分支。
- [x] **Step 5: 运行测试验证通过**
  运行：`node test/preferencesAndThumbnail.test.js`
  预期：PASS
- [x] **Step 6: Commit 变更**
  ```bash
  git add entry/src/main/ets/service/PreferencesService.ets entry/src/main/ets/service/ExportNativeService.ets entry/src/main/ets/pages/Index.ets entry/src/main/ets/bridge/CoreBridge.ets test/preferencesAndThumbnail.test.js
  git commit -m "feat: add PreferencesService for settings persistence and render static cover images on Index"
  ```

---

### Task 5: 领域状态模型大一统与胶水层彻底清除

**Files:**
- Modify: `entry/src/main/ets/model/AppState.ets`
- Delete: `entry/src/main/ets/service/EditorTranslationEngine.ets`
- Delete: `entry/src/main/ets/service/ExportPayloadTranslator.ets`
- Modify: `entry/src/main/ets/pages/Editor.ets`
- Modify: `entry/src/main/ets/viewmodel/EditorViewModel.ets`
- Modify: `entry/src/main/ets/components/EditorPreviewArea.ets`
- Create: `test/unifiedAppState.test.js`

**Interfaces:**
- Consumes: 统一的 `EditorStateModel`
- Produces: 
  - 全工程直接使用 `EditorStateModel` 作为单一真理源；
  - 消除 3 重同构状态模型与数据搬运胶水类；
  - UI 隐私打码 Toggle 真实双向绑定至 `EditorStateModel`。

- [x] **Step 1: 编写领域状态模型唯一真理源变更测试**
  在 `test/unifiedAppState.test.js` 中测试直接对 `EditorStateModel` 触发修改（选区、机位、打码）能完整且一致地保留数据，无需经过任何翻译器转换。
- [x] **Step 2: 运行测试验证失败**
  运行：`node test/unifiedAppState.test.js`
  预期：FAIL
- [x] **Step 3: 扩充 AppState.ets 并删除胶水转换器**
  - 在 `model/AppState.ets` 中扩充 `EditorStateModel`，直接容纳轨道列表、切片元数据及导出配置；
  - 物理删除 `entry/src/main/ets/service/EditorTranslationEngine.ets` 与 `ExportPayloadTranslator.ets`；
  - 改造 `EditorViewModel.ets`、`Editor.ets` 和 `EditorPreviewArea.ets`，直接读写 `EditorStateModel`，并在 UI Toggle 的 `onChange` 中真实触发状态更新；
  - 修复 `maskTime` 与 `maskGps` 强耦合，使其具备独立控制来源。
- [x] **Step 4: 运行测试验证通过**
  运行：`node test/unifiedAppState.test.js`
  预期：PASS
- [x] **Step 5: Commit 变更**
  ```bash
  git add entry/src/main/ets/model/AppState.ets entry/src/main/ets/pages/Editor.ets entry/src/main/ets/viewmodel/EditorViewModel.ets entry/src/main/ets/components/EditorPreviewArea.ets test/unifiedAppState.test.js
  git rm entry/src/main/ets/service/EditorTranslationEngine.ets entry/src/main/ets/service/ExportPayloadTranslator.ets
  git commit -m "refactor: unify domain model to AppState @ObservedV2 and remove translator glue layers"
  ```

---

### Task 6: 纯逻辑自动化测试建设与端到端全链路验收

**Files:**
- Create: `test/timelineAndState.test.js`
- Create: `test/exportPipelineContract.test.js`
- Modify: `package.json`
- Verification: 全量运行测试套件，核验工程无编译/引用遗漏。

**Interfaces:**
- Consumes: Task 1–5 全部交付物
- Produces: 绿灯且真实覆盖业务逻辑的自动化回归套件与验收报告。

- [x] **Step 1: 编写时间轴切片换算与选区算法测试**
  在 `test/timelineAndState.test.js` 中覆盖时间轴微调、片段对齐、选区起止换算等核心纯算法。
- [x] **Step 2: 编写导出参数装配契约测试**
  在 `test/exportPipelineContract.test.js` 中覆盖空素材校验、选区起止时间传递、模板参数合法性校验等关键契约。
- [x] **Step 3: 更新 package.json 测试脚本**
  更新 `package.json` 中的 `"scripts"`，配置 `"test": "node --test test/*.test.js"`，使其成为真实可执行的回归门禁。
- [x] **Step 4: 运行全量测试套件**
  运行：`node --test test/*.test.js`
  预期：全部测试用例 PASS（非源码字符串 includes 匹配，均为真实输入输出断言）。
- [x] **Step 5: 最终清理与工程审查**
  检查 `git status` 确认无遗留孤立未引用文件，确认 `PROJECT_INVESTIGATION_REPORT.md` 与实际代码保持同步。
- [x] **Step 6: Commit 变更**
  ```bash
  git add package.json test/
  git commit -m "test: implement real unit tests for timeline, state transitions and export contracts"
  ```
