# 任务分解（Tasks）

## 阶段 A：提交链路收敛
- [ ] A1 清除拖拽 update 的所有 seek 提交旁路
- [ ] A2 引入统一 commitGlobalSeekByMs 入口
- [ ] A3 增加 seekRequestId 与 source 透传

## 阶段 B：边界抗抖策略
- [ ] B1 增加 settling requestId 校验与目标锁定
- [ ] B2 对时间文本实现分钟边界 hysteresis
- [ ] B3 对进度条显示增加同源优先级控制

## 阶段 C：验证与回归
- [ ] C1 验证 50~62s 来回拖动无抖动
- [ ] C2 验证拖拽仅一次有效 commit 日志
- [ ] C3 执行构建与测试回归

