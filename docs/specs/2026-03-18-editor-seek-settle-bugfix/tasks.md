# 任务分解（Tasks）

## 阶段 A：拖拽提交策略修正
- [ ] A1 移除拖拽 update 的节流 seek 提交，仅保留 UI 预览更新
- [ ] A2 在拖拽 end 执行单次最终 seek commit
- [ ] A3 统一拖拽路径毫秒精度，避免秒级量化回弹

## 阶段 B：落点稳定屏障
- [ ] B1 增加 dragging 后 settling 状态与目标毫秒记录
- [ ] B2 在 settling 窗口内过滤偏移 playhead 回调
- [ ] B3 以 seekDone 或超时结束 settling，恢复正常回调

## 阶段 C：调度防抖与回归
- [ ] C1 在 manager 增加最新 seek 回调有效性保护
- [ ] C2 验证“拖拽后不横跳”核心场景
- [ ] C3 执行 hvigor 构建与测试回归

