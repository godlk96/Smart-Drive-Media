# 剪辑预览实现技术说明（供评审）

## 1. 文档目的

这份文档用于给评审同学快速理解当前“剪辑预览”方案，重点解释：

- 主画面与非主画面分别是什么
- 用了哪些技术组件
- 播放时如何协同工作
- 为什么要使用双路无缝架构
- 当前已知边界与后续优化方向

---

## 2. 业务目标（先讲人话）

在剪辑页里，我们需要同时预览多个视角（例如前、左、右）并能跨多个 1 分钟片段连续播放。

用户体感目标：

1. 主画面跨片段时不要黑屏、不要卡顿、不要断音  
2. 其他小画面要跟主画面同步（同时间轴）  
3. 点击播放/暂停/拖动时，所有画面保持一致

---

## 3. 总体架构

当前预览是“1 主 + N 副”的协同架构。

### 3.1 主画面（Primary）

- 主画面是模板里第一个槽位（例如 T2 的 top）
- 采用双路无缝方案：
  - `SeamlessPreviewView`
  - `SeamlessPlayerManager`
  - 两个重叠 `XComponent`（A/B）
  - 两个 `AVPlayer` 交替预加载和切换

主画面的职责：保证跨片段连续播放体验（无缝优先）。

### 3.2 非主画面（Secondary）

- 非主画面是模板中除第一个槽位外的其他槽位（如 bottomLeft、bottomRight）
- 每个槽位用现有 `SeamlessVideoPlayer`（单实例）播放
- 通过统一 `start/pause/seek` 跟随主时间轴同步

副画面的职责：提供多视角同步参考（同步优先，复杂度低于主画面）。

---

## 4. 关键文件与职责

### 4.1 页面编排层

- `entry/src/main/ets/pages/Editor.ets`
  - 负责把 `previewSlots` 渲染成“1 主 + N 副”
  - 负责用户交互（播放、暂停、拖动、切模板）
  - 负责把窗口数据 `currentUri/nextUri` 下发给主画面控制器

### 4.2 主画面组件层

- `entry/src/main/ets/components/SeamlessPreviewView.ets`
  - 内部是 `Stack + 双 XComponent`
  - 采集 `surfaceIdA/B`
  - 和 `SeamlessPlayerManager` 绑定
  - 接收 manager 的 swap 回调并切换前后台层级

### 4.3 主画面调度层

- `entry/src/main/ets/components/SeamlessPlayerManager.ets`
  - 持有两个 `AVPlayer`（A/B）
  - 维护 active/standby
  - A 播放时预热 B，切点到达后立即切到 B
  - 切换后回收旧 active，准备下一轮

### 4.4 数据与模板层

- `entry/src/main/ets/bridge/CoreBridge.ets`
  - 生成 `EditorState`
  - 根据模板和时间锚点生成 `previewSlots`（含 `uri/nextUri`）
  - 管理当前片段索引和 `canPlayNext`
- `entry/src/main/ets/model/Models.ets`
  - 定义 T1~T5 模板槽位布局与轨道策略

### 4.5 副画面播放器

- `entry/src/main/ets/components/SeamlessVideoPlayer.ets`
  - 单 `AVPlayer` 播放器组件
  - 负责副槽位播放、seek、倍速、静音

---

## 5. 主画面无缝播放机制（Ping-Pong）

主画面是典型乒乓缓冲：

1. A 播放当前片段 N  
2. B 预加载下一片段 N+1，并进入 prepared  
3. 到切点后触发 B.play()  
4. UI 把 B 对应 `XComponent` 置顶  
5. A 回收并准备 N+2  
6. A/B 持续轮转

这套机制避免了“单实例 reset+setUrl+prepare”带来的黑屏与音频断裂。

---

## 6. 主副画面如何协同

### 6.1 播放/暂停

- 页面统一触发：
  - 主：`SeamlessPreviewController.start/pause`
  - 副：各 `SeamlessVideoController.start/pause`

### 6.2 拖动 seek

- 页面先更新全局时间轴，再下发“片内秒”：
  - 主画面：主控制器 seek
  - 副画面：副控制器 seek

### 6.3 跨片段切换

- 主画面切换成功后触发 `onSwap`
- 页面收到后调用 `bridge.playNextClip()`，刷新新的 `previewSlots`
- 副画面拿到新的槽位 URI 后，继续按新片段同步播放

---

## 7. 音频策略

当前策略是“单槽位出声”：

1. 优先选择 Front 且有有效 URI 的槽位
2. 否则使用主槽位（有 URI）
3. 再不行回退第一个可播槽位

其余槽位静音，避免多路叠音。

---

## 8. 这次修复了什么问题

### 8.1 首次进入“合并剪辑”时主副不同步

原因：首次进入时，副槽位可能先启动，主槽位尚未开始，导致“副画面在动、主画面不动”。

修复：

- 首次有封面时将 `previewPlaying` 初始化为 false
- 副槽位 prepared 回调增加条件：仅当 `previewPlaying && !showPreviewCover` 才自动 start

### 8.2 合并剪辑默认 T2 下前视角不动/无声

原因：

- 片段锚点相机和模板主槽位可能不一致
- 音频槽位曾存在“选中了无 URI 的前视槽位”的风险

修复：

- CoreBridge 新增“模板主槽位优先”的锚点相机选择
- 音频槽位选择增加“必须有可播 URI”的回退策略

---

## 9. 当前边界与已知取舍

1. 仅主画面做双路无缝，副画面保持单路  
   - 原因：成本、稳定性和设备资源平衡
2. 副画面仍可能在极端 I/O 抖动下出现轻微追帧
3. 当前是“单路音频”，不做多路混音

---

## 10. 建议评审关注点

建议评审同学重点看：

1. `CoreBridge` 里的锚点相机选择是否符合模板优先原则  
2. `Editor` 的主副协同是否有状态竞态  
3. `SeamlessPlayerManager` 的切换窗口与容错策略是否足够  
4. 音频槽位回退策略是否覆盖异常数据场景  
5. 是否需要补“合并剪辑首次进入”专门自动化用例

---

## 11. 关键代码入口（便于 reviewer 跳转）

- 主画面渲染入口：`Editor` 中 `SeamlessPreviewView`
- 主画面调度器：`SeamlessPlayerManager`
- 副画面播放器：`SeamlessVideoPlayer`
- 模板定义：`Models` 中 T1~T5
- 预览槽位生成：`CoreBridge.buildPreviewSlots`

---

## 12. 一句话总结

当前方案是：主画面用双路 AVPlayer 做无缝切段，副画面用单路播放器做同步跟随，页面层负责统一时间轴与状态编排，Bridge 负责模板与槽位映射。这个方案在复杂度、性能和体验之间做了工程化平衡。
