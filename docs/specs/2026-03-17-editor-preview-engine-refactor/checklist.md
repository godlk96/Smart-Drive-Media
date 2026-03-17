# 验收检查清单（Checklist）

## 架构约束
- [ ] UI 层未出现任何切片映射逻辑（仅渲染状态）
- [ ] 未使用 `Video` 组件，全部预览基于 `XComponent + AVPlayer`
- [ ] 全局仅一个时间主宰（GlobalTimelineManager）
- [ ] 所有轨道控制均通过统一调度入口触发

## 旧链路清理
- [ ] 已移除 `SeamlessPlayerManager` 相关引用与实现
- [ ] 已移除 `SeamlessVideoPlayer` 相关引用与实现
- [ ] `Editor.ets` 不再通过 `playNextClip` 派发切片联动
- [ ] 页面中不再存在多播放器分散 `play/pause/seek` 控制代码

## 核心能力
- [ ] `seek(globalMs)` 具备全轨暂停 -> 全轨 seek -> 屏障解除机制
- [ ] 任一轨 seek 失败时可回退到稳定 paused 状态
- [ ] 每轨均实现双 AVPlayer 乒乓切换
- [ ] 临界前 `<1000ms` 预热下一切片成功
- [ ] 到点交接可瞬时切层且无黑屏
- [ ] 非 AudioMaster 轨道全程静音

## 模板渲染
- [ ] T1：上下双轨，FRONT 为 AudioMaster
- [ ] T2：倒品字三轨，FRONT 为 AudioMaster
- [ ] T3：左右双轨，全员静音
- [ ] T4：水平三轨，中心 FRONT 为 AudioMaster，左右已裁切

## 生命周期与稳定性
- [ ] 模板切换会销毁全部旧轨道并重建，不残留旧实例
- [ ] 页面退出时 AVPlayer 已全部 release
- [ ] 连续切模板与频繁拖拽无崩溃
- [ ] 音画同步稳定，无明显错位或断层

