# 任务分解（Tasks）

## 阶段 A：清理旧链路
- [ ] A1 移除 `SeamlessPlayerManager` 与 `SeamlessVideoPlayer` 的页面引用与导入
- [ ] A2 删除 `Editor.ets` 中 `bridge.playNextClip` 驱动的切片联动逻辑
- [ ] A3 统一收敛 `play/pause/seek` 到单一调度入口，移除分散控制代码
- [ ] A4 清理旧组件源码与无效类型/回调定义

## 阶段 B：核心引擎实现
- [ ] B1 新建 `GlobalTimelineManager.ets`，实现轨道注册、状态维护、生命周期管理
- [ ] B2 实现 `GlobalTimelineManager.seek()` 的 Promise.all 屏障与异常回退
- [ ] B3 新建 `PingPongTrackController.ets`，实现双 AVPlayer 初始化与 surface 绑定
- [ ] B4 实现轨道级全局毫秒映射与 `seekTo(globalMs)` 异步接口
- [ ] B5 实现 `<1000ms` 预热、到点交接、旧实例 reset 的乒乓流程
- [ ] B6 实现 `isAudioMaster` 策略与激活层音量归属
- [ ] B7 完成 controller 的幂等 `release()` 与竞态保护

## 阶段 C：ArkUI 表现层重构
- [ ] C1 新建 `PingPongTrackView.ets`，以双 `XComponent` + `Stack` 实现轨道渲染
- [ ] C2 新建 `EditorPreviewArea.ets`，基于 `EditorState.selectedTemplateId` 动态布局轨道
- [ ] C3 按 T1/T2/T3/T4 映射轨道、AudioMaster 与布局比例
- [ ] C4 在 T4 增加左右视角 UI 裁切能力并保证与导出策略一致
- [ ] C5 模板切换时实现旧 controller 全量销毁与新实例重建

## 阶段 D：Editor 接入与联调
- [ ] D1 将 Editor 预览区域替换为 `EditorPreviewArea`
- [ ] D2 将播放控制、拖拽 Seek 接入 `GlobalTimelineManager`
- [ ] D3 验证播放/暂停/拖拽/切模板行为一致性

## 阶段 E：验证与回归
- [ ] E1 执行静态检查，修复新增类型与语法问题
- [ ] E2 完成核心场景人工验证：跨切片、连续拖拽、模板切换、页面退出
- [ ] E3 补充必要测试或可重复验证脚本，输出验收结论

