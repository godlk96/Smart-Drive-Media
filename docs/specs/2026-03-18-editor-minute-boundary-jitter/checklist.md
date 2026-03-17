# 验收检查清单（Checklist）

## 体验
- [ ] 50~62 秒区间来回拖动无明显抖动
- [ ] 跨过 60 秒时进度条不来回横跳
- [ ] 时间文本不在 `00:59/01:00` 间闪烁

## 调度
- [ ] 拖拽 update 阶段无 seek commit
- [ ] 拖拽 end 仅一次有效 seek commit
- [ ] settling 仅接受最新 requestId 回调

## 日志
- [ ] 无高频 `拖动全局进度` 刷屏
- [ ] commit 日志可对应唯一 requestId
- [ ] seek 完成日志不再引发落点回弹

## 工程质量
- [ ] hvigor 构建通过
- [ ] ArkTS 无新增 ERROR
- [ ] 自动化测试通过

