# 无缝预览重构评审清单（checklist.md）

## A. 架构确认

- [ ] 已确认采用双 `AVPlayer` 乒乓策略而非单实例切源
- [ ] 已确认 `SeamlessPlayerManager` 为唯一调度入口
- [ ] 已确认 UI 层仅负责渲染与层级切换，不承担播放器状态机

## B. 状态机确认

- [ ] 已定义 Manager 主状态（IDLE/BOOTSTRAPPING/PLAYING/SWAPPING/SEEKING/RELEASED）
- [ ] 已定义单播放器子状态并约束非法跃迁
- [ ] 已定义切段超时和降级策略
- [ ] 已定义异步回调 token 校验规则

## C. UI 组件确认

- [ ] `SeamlessPreviewView` 使用 `Stack + 双 XComponent` 完全重叠
- [ ] 已正确获取并绑定 `surfaceIdA/surfaceIdB`
- [ ] 切段通过 `zIndex/visibility` 瞬时置顶，不重建节点

## D. 生命周期与资源确认

- [ ] 页面出现时创建并绑定双播放器
- [ ] 页面消失时释放双播放器并解除监听
- [ ] 旧前台切换后可立即回收并预热后续片段
- [ ] 多次进出页面无泄漏、无崩溃

## E. 集成改造确认

- [ ] `Editor.ets` 不再维护主画面 A/B 手工状态
- [ ] 片段列表由业务层输入，预览组件仅消费 `ClipItem[]`
- [ ] 旧 `SeamlessVideoPlayer` 逻辑已退役或被新架构替换

## F. 体验与稳定性确认

- [ ] 连续跨片段切换无黑屏
- [ ] 连续跨片段切换无可感知卡顿
- [ ] 音频在交界处连续，无明显断层
- [ ] 高频拖动 seek 后仍能恢复无缝切段
- [ ] 异常场景可降级并输出可定位日志
