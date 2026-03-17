# 验收检查清单（Checklist）

## 交互问题修复
- [ ] 默认进入 T2 后首次点击播放不会秒停
- [ ] 同一模板中播放/暂停可反复切换且每次生效
- [ ] 切换模板后依然可以暂停
- [ ] 连续切换多个模板均能正确切换布局与轨道

## 状态机一致性
- [ ] Track 层回调无覆盖冲突（layer/progress/ended 分离）
- [ ] 单轨 completed 不会触发全局 ended
- [ ] 仅全轨结束时触发全局 ended 回调
- [ ] seek / play / template rebuild 后 ended 状态已重置

## 重建与性能
- [ ] 播放期间不会因 playhead 刷新触发 rebuild
- [ ] `rebuild done` 日志仅在模板或行程切换时出现
- [ ] 模板切换存在防重入保护

## 工程质量
- [ ] hvigor assembleHap 构建通过
- [ ] ArkTS 无新增 ERROR
- [ ] 自动化测试通过且无回归

