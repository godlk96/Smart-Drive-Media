# 任务分解（Tasks）

## 阶段 A：拖拽状态机改造
- [ ] A1 在 Editor 引入拖拽会话状态（start/update/end）
- [ ] A2 将拖拽 update 改为仅更新 UI 游标与时间文本
- [ ] A3 在拖拽 end 提交最终 seek，确保落点正确

## 阶段 B：seek 限流与合并
- [ ] B1 新增 commitGlobalSeek 与 previewPlayheadOnly 双通道
- [ ] B2 对拖拽 update 的 commit 增加节流（默认 120ms）
- [ ] B3 在 GlobalTimelineManager 增加 in-flight seek 合并机制

## 阶段 C：回归验证
- [ ] C1 验证拖拽日志不再出现请求风暴
- [ ] C2 验证松手后画面落点与时间文本一致
- [ ] C3 执行 hvigor 构建与测试回归

