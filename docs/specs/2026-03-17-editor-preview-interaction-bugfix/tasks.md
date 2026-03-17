# 任务分解（Tasks）

## 阶段 A：回调与状态机修复
- [ ] A1 拆分 TrackController 回调注册接口，避免 UI/Manager 回调覆盖
- [ ] A2 在 GlobalTimelineManager 增加全轨 ended 屏障聚合判定
- [ ] A3 在 seek/play/rebuild 时重置 ended 状态，保证播放生命周期一致

## 阶段 B：重建时序与模板切换修复
- [ ] B1 将 EditorPreviewArea rebuild 触发条件收敛为 trip/template 关键键变更
- [ ] B2 将 play/pause/seek/speed/muted 改为纯调度命令，不触发重建
- [ ] B3 实现模板切换事务化流程（pause -> switch -> rebuild -> seek -> resume）
- [ ] B4 增加模板切换防重入状态，避免连续点击状态污染

## 阶段 C：联调与回归
- [ ] C1 回归三个用户问题场景并记录验证结果
- [ ] C2 执行 hvigor 构建验证无新增错误
- [ ] C3 执行现有测试集确保无回归

