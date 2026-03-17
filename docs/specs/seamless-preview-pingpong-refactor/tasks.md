# 无缝预览重构任务分解（tasks.md）

## 执行状态

- [ ] 阶段 A：播放器管理器落地
- [ ] 阶段 B：预览组件重构
- [ ] 阶段 C：编辑页接入与旧实现移除
- [ ] 阶段 D：稳定性验证

## 阶段 A：播放器管理器落地

- [ ] Task1：新建 `SeamlessPlayerManager.ets`
  - [ ] 建立双实例 `AVPlayer` 生命周期管理
  - [ ] 建立前台/后台槽位与轮转机制
  - [ ] 建立 `loadToken` 机制，屏蔽过期异步回调
- [ ] Task2：实现预加载与瞬时交替
  - [ ] A 播放 N 时，B 预热 N+1 至 prepared
  - [ ] 命中切点后立即触发后台 `play`
  - [ ] 通知 UI 执行层级切换
- [ ] Task3：实现循环回收
  - [ ] 旧前台 `stop/reset`
  - [ ] 立即装载 N+2 并 `prepare`
  - [ ] 保持双路乒乓持续可用

## 阶段 B：预览组件重构

- [ ] Task4：新建 `SeamlessPreviewView.ets`
  - [ ] `Stack` 内放置两个重叠 `XComponent`
  - [ ] 获取 `surfaceIdA/B` 并绑定 manager
  - [ ] 通过回调切换前后台层级
- [ ] Task5：设计组件控制器
  - [ ] 暴露 `start/pause/seek/reload/setMuted`
  - [ ] 将业务调用与内部状态解耦

## 阶段 C：编辑页接入与旧实现移除

- [ ] Task6：改造 `Editor.ets` 主预览链路
  - [ ] 用 `SeamlessPreviewView` 替代当前双 `SeamlessVideoPlayer` 直连
  - [ ] 删除主画面 A/B 手工切换状态变量
  - [ ] 保留业务时间轴控制并映射到组件控制器
- [ ] Task7：退役旧组件实现
  - [ ] 移除或重写 `SeamlessVideoPlayer.ets`
  - [ ] 清理旧回调与无效防抖逻辑

## 阶段 D：稳定性验证

- [ ] Task8：事件与状态机验证
  - [ ] 覆盖初始化、预热、切换、回收、释放
  - [ ] 校验异常路径（prepare 失败、回调超时、空片段）
- [ ] Task9：体验验证
  - [ ] 连续切段无黑屏、无明显卡顿
  - [ ] 音频在交界处主观连续
  - [ ] 高频 seek 后仍可恢复双路预热
