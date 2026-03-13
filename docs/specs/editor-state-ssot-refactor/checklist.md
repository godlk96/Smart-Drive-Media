# 评审检查清单（checklist.md）

## A. 诊断确认

- [x] 已确认所有视角绑定逻辑不再依赖数组下标语义
- [x] 已确认 ArkTS 页面不存在多源可写业务状态
- [x] 已确认导出入口不直接读取可变 UI 状态

## B. 模型设计确认

- [x] `Trip` 明确包含 `CameraPosition` 枚举轨道
- [x] `Template` 明确 required/optional cameras 与 slotBindings
- [x] `EditorState` 为唯一可写业务状态源
- [x] `ExportSnapshot` 为深拷贝不可变对象

## C. 代码改造确认

- [x] `Models.ets` 已替换旧分散模型并通过类型检查
- [x] `EditorPage.ets` 已改为 action/reducer 单向更新
- [x] `ExportManager.ets` 已落地并隔离导出副作用
- [x] `CoreBridge.ets` 仅保留数据与平台桥接职责

## D. 生命周期确认

- [x] aboutToAppear 已完成状态注入
- [x] aboutToDisappear 已完成资源与状态销毁
- [x] 页面返回再进入不会复用脏状态

## E. 一致性与回归

- [x] 预览布局与导出模板一致
- [x] 跨文件区间导出结果连续无错轨
- [x] 导出期间 UI 变更不会污染当前任务
- [x] 历史功能（权限、扫描、导出落相册）行为不退化
